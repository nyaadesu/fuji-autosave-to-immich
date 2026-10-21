// fuji-autosave-receiver: a headless FUJIFILM PC AutoSave target built on libfuji.
// Waits for the camera's AutoSave broadcast, pulls every new object over PTP/IP
// into <inbox>/YYYY-MM-DD/, and runs a hook once per batch.
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <libpict.h>
#include <fuji.h>
#include <app.h>
#include "seen.h"

#define RETRY_DELAY_SEC 5
// The init packet carries the name as UTF-16 in 54 bytes
#define MAX_CLIENT_NAME 24

struct Config {
	const char *inbox;
	const char *state_dir;
	const char *client_name;
	const char *hook;
	int verbose;
	int list_only;
	int once;
};

struct Batch {
	FILE *list;
	char list_path[PATH_MAX];
	int count;
};

static struct Config cfg = {
	.inbox = "/srv/fuji-inbox",
	.state_dir = "/var/lib/fuji-autosave",
	.client_name = "fuji-inbox",
};

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) {
	(void)sig;
	g_stop = 1;
}

static void vlog(const char *level, const char *fmt, va_list args) {
	char buf[1024];
	vsnprintf(buf, sizeof(buf), fmt, args);
	size_t len = strlen(buf);
	while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = '\0';
	if (len == 0) return;
	fprintf(stderr, "%s%s\n", level, buf);
}

__attribute__((format(printf, 1, 2)))
static void log_info(const char *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	vlog("", fmt, args);
	va_end(args);
}

__attribute__((format(printf, 1, 2)))
static void log_err(const char *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	vlog("error: ", fmt, args);
	va_end(args);
}

// Hooks libpict and libfuji expect the frontend to provide

void ptp_verbose_log(struct PtpRuntime *r, char *fmt, ...) {
	(void)r;
	if (!cfg.verbose) return;
	va_list args;
	va_start(args, fmt);
	vlog("ptp: ", fmt, args);
	va_end(args);
}

void ptp_error_log(struct PtpRuntime *r, char *fmt, ...) {
	(void)r;
	va_list args;
	va_start(args, fmt);
	vlog("ptp error: ", fmt, args);
	va_end(args);
}

void ptp_panic(char *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	vlog("ptp panic: ", fmt, args);
	va_end(args);
	abort();
}

void plat_dbg(char *fmt, ...) {
	if (!cfg.verbose) return;
	va_list args;
	va_start(args, fmt);
	vlog("dbg: ", fmt, args);
	va_end(args);
}

void app_print(struct PtpRuntime *r, char *fmt, ...) {
	(void)r;
	if (!cfg.verbose) return;
	va_list args;
	va_start(args, fmt);
	vlog("fuji: ", fmt, args);
	va_end(args);
}

void tester_log(struct PtpRuntime *r, char *fmt, ...) { (void)r; (void)fmt; }
void tester_fail(struct PtpRuntime *r, char *fmt, ...) { (void)r; (void)fmt; }
// Model name from the PTP/IP init response, e.g. "X-T30 II"
static char g_session_model[64];

void app_send_cam_name(struct PtpRuntime *r, const char *name) {
	(void)r;
	snprintf(g_session_model, sizeof(g_session_model), "%s", name);
	log_info("camera identifies as '%s'", name);
}
void app_update_storage_info(struct PtpRuntime *r) { (void)r; }
void app_report_download_speed(struct PtpRuntime *r, long time, size_t size) { (void)r; (void)time; (void)size; }
int app_check_thread_cancel(struct PtpRuntime *r) { (void)r; return g_stop; }
int fuji_discovery_check_cancel(struct PtpRuntime *r) { (void)r; return g_stop; }
int plat_update_object_info(struct PtpRuntime *r, int handle, const struct PtpObjectInfo *oi) {
	(void)r; (void)handle; (void)oi;
	return 0;
}
int app_ptp_download_file(struct PtpRuntime *r, struct PtpObjectInfo *oi, int object_id, unsigned int max_chunk_size, int index) {
	(void)r; (void)oi; (void)object_id; (void)max_chunk_size; (void)index;
	return 0;
}
// Only reached in the camera's "multiple transfer" (phone) mode, which AutoSave never enters
int app_queue_file_for_download(struct PtpRuntime *r, int object_id) { (void)r; (void)object_id; return 0; }

// Files

static int mkdir_p(const char *path) {
	char tmp[PATH_MAX];
	if (snprintf(tmp, sizeof(tmp), "%s", path) >= (int)sizeof(tmp)) return -1;
	for (char *p = tmp + 1; *p; p++) {
		if (*p != '/') continue;
		*p = '\0';
		if (mkdir(tmp, 0755) && errno != EEXIST) return -1;
		*p = '/';
	}
	if (mkdir(tmp, 0755) && errno != EEXIST) return -1;
	return 0;
}

static int fsync_dir(const char *path) {
	int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) return -1;
	int rc = fsync(fd);
	close(fd);
	return rc;
}

// Camera-supplied names must not escape the inbox
static void sanitize_name(const char *in, char *out, size_t size) {
	size_t j = 0;
	for (size_t i = 0; in[i] != '\0' && j + 1 < size; i++) {
		char c = in[i];
		if (c == '/' || c == '\\' || (unsigned char)c < 0x20) c = '_';
		out[j++] = c;
	}
	out[j] = '\0';
	if (out[0] == '\0') snprintf(out, size, "unnamed");
	else if (out[0] == '.') out[0] = '_';
}

// PTP dates look like "20261021T153012"; fall back to today's local date
static void day_from_ptp_date(const char *date, char out[11]) {
	int ok = strlen(date) >= 8;
	for (int i = 0; ok && i < 8; i++) {
		if (date[i] < '0' || date[i] > '9') ok = 0;
	}
	if (ok) {
		snprintf(out, 11, "%.4s-%.2s-%.2s", date, date + 4, date + 6);
		return;
	}
	time_t now = time(NULL);
	struct tm tm;
	localtime_r(&now, &tm);
	strftime(out, 11, "%Y-%m-%d", &tm);
}

// Pick <dir>/<name>, or <dir>/<stem>-N<ext> if that is taken
static int unique_path(const char *dir, const char *name, char *out, size_t size) {
	if (snprintf(out, size, "%s/%s", dir, name) >= (int)size) return -1;
	if (access(out, F_OK) != 0) return 0;

	const char *dot = strrchr(name, '.');
	int stem_len = dot ? (int)(dot - name) : (int)strlen(name);
	const char *ext = dot ? dot : "";
	for (int i = 1; i < 1000; i++) {
		if (snprintf(out, size, "%s/%.*s-%d%s", dir, stem_len, name, i, ext) >= (int)size) return -1;
		if (access(out, F_OK) != 0) return 0;
	}
	return -1;
}

struct Sink {
	int fd;
	unsigned int written;
};

static int sink_add(void *arg, void *buf, unsigned int len, unsigned int offset, unsigned int total_size) {
	(void)total_size;
	struct Sink *sink = arg;
	const char *p = buf;
	unsigned int left = len;
	off_t at = offset;
	while (left > 0) {
		ssize_t n = pwrite(sink->fd, p, left, at);
		if (n < 0) {
			if (errno == EINTR) continue;
			return -1;
		}
		p += n; at += n; left -= (unsigned int)n;
	}
	sink->written += len;
	return 0;
}

// Session

static int batch_open(struct Batch *b) {
	char dir[PATH_MAX];
	snprintf(dir, sizeof(dir), "%s/batches", cfg.state_dir);
	if (mkdir_p(dir)) return -1;
	time_t now = time(NULL);
	struct tm tm;
	localtime_r(&now, &tm);
	char stamp[32];
	strftime(stamp, sizeof(stamp), "%Y%m%dT%H%M%S", &tm);
	if (snprintf(b->list_path, sizeof(b->list_path), "%s/%s-%d.list", dir, stamp, (int)getpid()) >= (int)sizeof(b->list_path)) return -1;
	b->list = fopen(b->list_path, "w");
	b->count = 0;
	return b->list == NULL ? -1 : 0;
}

static void run_hook(struct Batch *b, const struct DiscoverInfo *info) {
	if (b->list == NULL) return;
	fclose(b->list);
	b->list = NULL;

	if (b->count == 0) {
		unlink(b->list_path);
		return;
	}
	if (cfg.hook == NULL) {
		// Nothing consumes batch lists without a hook
		unlink(b->list_path);
		return;
	}

	pid_t pid = fork();
	if (pid < 0) {
		log_err("fork for hook failed: %s", strerror(errno));
		return;
	}
	if (pid == 0) {
		char count[16];
		snprintf(count, sizeof(count), "%d", b->count);
		setenv("FUJI_BATCH_LIST", b->list_path, 1);
		setenv("FUJI_BATCH_COUNT", count, 1);
		setenv("FUJI_INBOX", cfg.inbox, 1);
		setenv("FUJI_STATE_DIR", cfg.state_dir, 1);
		setenv("FUJI_CAMERA_NAME", info->camera_name, 1);
		// The connect handshake carries no model; the session's init response does
		setenv("FUJI_CAMERA_MODEL", info->camera_model[0] ? info->camera_model : g_session_model, 1);
		signal(SIGPIPE, SIG_DFL);
		execl(cfg.hook, cfg.hook, b->list_path, (char *)NULL);
		fprintf(stderr, "error: exec %s: %s\n", cfg.hook, strerror(errno));
		_exit(127);
	}
	log_info("started hook (pid %d) for %d file(s)", (int)pid, b->count);
}

static void reap_hooks(void) {
	int status;
	pid_t pid;
	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
			log_info("hook %d finished", (int)pid);
		} else if (WIFEXITED(status)) {
			log_err("hook %d exited with %d", (int)pid, WEXITSTATUS(status));
		} else {
			log_err("hook %d killed by signal %d", (int)pid, WTERMSIG(status));
		}
	}
}

static int download_one(struct PtpRuntime *r, int handle, const struct PtpObjectInfo *oi,
		const char *key, struct SeenStore *seen, struct Batch *batch) {
	char name[128];
	sanitize_name(oi->filename, name, sizeof(name));

	char incoming[PATH_MAX], part[PATH_MAX];
	snprintf(incoming, sizeof(incoming), "%s/.incoming", cfg.inbox);
	if (mkdir_p(incoming)) {
		log_err("cannot create %s: %s", incoming, strerror(errno));
		return -1;
	}
	if (snprintf(part, sizeof(part), "%s/%s.part", incoming, name) >= (int)sizeof(part)) return -1;

	struct Sink sink = {0};
	sink.fd = open(part, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (sink.fd < 0) {
		log_err("open %s: %s", part, strerror(errno));
		return -1;
	}

	time_t started = time(NULL);
	int rc = fuji_download_file(r, handle, sink_add, &sink);
	if (rc == 0 && sink.written != oi->compressed_size) {
		log_err("%s: got %u of %u bytes", name, sink.written, oi->compressed_size);
		rc = PTP_RUNTIME_ERR;
	}
	if (rc == 0 && fsync(sink.fd)) rc = -1;
	if (close(sink.fd)) rc = -1;
	if (rc) {
		unlink(part);
		log_err("download of %s failed (%d)", name, rc);
		return rc;
	}

	char day[11], dir[PATH_MAX], final[PATH_MAX];
	day_from_ptp_date(oi->date_created, day);
	snprintf(dir, sizeof(dir), "%s/%s", cfg.inbox, day);
	if (mkdir_p(dir) || unique_path(dir, name, final, sizeof(final))) {
		log_err("cannot place %s in %s", name, dir);
		unlink(part);
		return -1;
	}
	if (rename(part, final)) {
		log_err("rename %s -> %s: %s", part, final, strerror(errno));
		unlink(part);
		return -1;
	}
	fsync_dir(dir);

	if (seen_add(seen, key, final)) {
		log_err("could not record %s in the seen list: %s", name, strerror(errno));
	}
	if (batch->list != NULL) {
		fprintf(batch->list, "%s\n", final);
		fflush(batch->list);
	}
	batch->count++;

	long secs = (long)(time(NULL) - started);
	log_info("saved %s (%u bytes, %lds)", final, oi->compressed_size, secs);
	return 0;
}

static int run_session(struct DiscoverInfo *info, struct SeenStore *seen) {
	g_session_model[0] = '\0';
	struct PtpRuntime *r = fuji_ptp_new(PTP_IP_USB);
	fujipriv_t *fuji = fuji_get(r);
	fuji->transport = info->transport;
	snprintf(fuji->ip_address, sizeof(fuji->ip_address), "%s", info->camera_ip);

	struct Batch batch = {0};
	int rc = 0, connected = 0;
	int n_new = 0, n_skipped = 0;

	// The camera needs a moment after the invite before it accepts PTP/IP
	usleep(1000 * 1000);
	log_info("connecting to %s:%d", info->camera_ip, info->camera_port);
	rc = ptpip_connect(r, info->camera_ip, info->camera_port, 3);
	if (rc) {
		log_err("PTP/IP connect to %s:%d failed (%d)", info->camera_ip, info->camera_port, rc);
		goto out;
	}
	connected = 1;

	rc = fuji_setup(r, cfg.client_name);
	if (rc) {
		log_err("session setup failed (%d)", rc);
		goto out;
	}

	if (fuji->camera_state != FUJI_PC_AUTO_SAVE) {
		log_err("camera is in state %d, not PC AutoSave (%d); ignoring", fuji->camera_state, FUJI_PC_AUTO_SAVE);
		rc = -1;
		goto out;
	}

	int total = fuji->num_objects;
	log_info("camera offers %d object(s)", total);
	if (total <= 0) goto out;

	if (!cfg.list_only && batch_open(&batch)) {
		log_err("cannot create batch list in %s/batches: %s", cfg.state_dir, strerror(errno));
	}

	for (int handle = 1; handle <= total && !g_stop; handle++) {
		struct PtpObjectInfo oi;
		rc = ptp_get_object_info(r, handle, &oi);
		if (rc == PTP_CHECK_CODE) {
			log_err("object %d: camera refused object info (0x%04x), skipping", handle, ptp_get_return_code(r));
			rc = 0;
			continue;
		} else if (rc) {
			log_err("object %d: object info failed (%d)", handle, rc);
			goto out;
		}
		if (oi.obj_format == PTP_OF_Association) continue;

		char key[160];
		snprintf(key, sizeof(key), "%s|%s|%u", oi.filename, oi.date_created, oi.compressed_size);

		if (cfg.list_only) {
			log_info("object %d: %s format=0x%04x size=%u date=%s%s", handle, oi.filename,
				oi.obj_format, oi.compressed_size, oi.date_created,
				seen_has(seen, key) ? " (seen)" : "");
			continue;
		}
		if (seen_has(seen, key)) {
			n_skipped++;
			continue;
		}

		rc = download_one(r, handle, &oi, key, seen, &batch);
		// A half-read object leaves the camera unresponsive; drop the session
		if (rc) goto out;
		n_new++;
	}

	out:;
	if (!cfg.list_only) {
		log_info("session done: %d new, %d already seen", n_new, n_skipped);
	}
	if (connected) {
		// Close session, send Fuji's goodbye packet, close sockets
		ptp_report_error(r, NULL, 0);
	}
	run_hook(&batch, info);
	free(r->priv);
	r->priv = NULL;
	ptp_close(r);
	return rc;
}

static void usage(const char *argv0) {
	fprintf(stderr,
		"usage: %s [options]\n"
		"  -i, --inbox DIR        where files land (default %s)\n"
		"  -s, --state-dir DIR    seen list and batch lists (default %s)\n"
		"  -n, --name NAME        client name shown on the camera (default %s)\n"
		"  -x, --hook PATH        run PATH <batch-list> after each batch with new files\n"
		"  -l, --list-only        log what the camera offers, download nothing\n"
		"  -1, --once             exit after the first AutoSave session\n"
		"  -v, --verbose          log protocol details\n",
		argv0, cfg.inbox, cfg.state_dir, cfg.client_name);
}

int main(int argc, char **argv) {
	static const struct option opts[] = {
		{"inbox", required_argument, NULL, 'i'},
		{"state-dir", required_argument, NULL, 's'},
		{"name", required_argument, NULL, 'n'},
		{"hook", required_argument, NULL, 'x'},
		{"list-only", no_argument, NULL, 'l'},
		{"once", no_argument, NULL, '1'},
		{"verbose", no_argument, NULL, 'v'},
		{"help", no_argument, NULL, 'h'},
		{0},
	};
	int c;
	while ((c = getopt_long(argc, argv, "i:s:n:x:l1vh", opts, NULL)) != -1) {
		switch (c) {
		case 'i': cfg.inbox = optarg; break;
		case 's': cfg.state_dir = optarg; break;
		case 'n': cfg.client_name = optarg; break;
		case 'x': cfg.hook = optarg; break;
		case 'l': cfg.list_only = 1; break;
		case '1': cfg.once = 1; break;
		case 'v': cfg.verbose = 1; break;
		case 'h': usage(argv[0]); return 0;
		default: usage(argv[0]); return 2;
		}
	}
	if (strlen(cfg.client_name) == 0 || strlen(cfg.client_name) > MAX_CLIENT_NAME) {
		fprintf(stderr, "error: --name must be 1-%d characters\n", MAX_CLIENT_NAME);
		return 2;
	}
	if (cfg.hook != NULL && access(cfg.hook, X_OK) != 0) {
		fprintf(stderr, "error: hook %s is not executable\n", cfg.hook);
		return 2;
	}

	setvbuf(stderr, NULL, _IOLBF, 0);
	struct sigaction sa = {0};
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	if (mkdir_p(cfg.inbox) || mkdir_p(cfg.state_dir)) {
		log_err("cannot create %s or %s: %s", cfg.inbox, cfg.state_dir, strerror(errno));
		return 1;
	}
	// Hooks get absolute paths in batch lists
	static char inbox_abs[PATH_MAX], state_abs[PATH_MAX];
	if (realpath(cfg.inbox, inbox_abs) == NULL || realpath(cfg.state_dir, state_abs) == NULL) {
		log_err("cannot resolve %s or %s: %s", cfg.inbox, cfg.state_dir, strerror(errno));
		return 1;
	}
	cfg.inbox = inbox_abs;
	cfg.state_dir = state_abs;

	char seen_path[PATH_MAX];
	struct SeenStore seen;
	if (snprintf(seen_path, sizeof(seen_path), "%s/seen.tsv", cfg.state_dir) >= (int)sizeof(seen_path)
			|| seen_open(&seen, seen_path)) {
		log_err("cannot load %s: %s", seen_path, strerror(errno));
		return 1;
	}
	log_info("listening for PC AutoSave as '%s'; %zu file(s) already seen; inbox %s",
		cfg.client_name, seen.len, cfg.inbox);

	int exit_code = 0;
	while (!g_stop) {
		reap_hooks();

		struct PtpRuntime *dr = fuji_ptp_new(PTP_IP_USB);
		struct DiscoverInfo info;
		int rc = fuji_discover_thread(dr, &info, cfg.client_name);
		free(dr->priv);
		dr->priv = NULL;
		ptp_close(dr);

		if (rc == FUJI_D_CANCELED || g_stop) break;
		if (rc == FUJI_D_REGISTERED) {
			log_info("registered with %s (%s); select this PC on the camera to start transfers",
				info.camera_name, info.camera_model);
			continue;
		}
		if (rc == FUJI_D_GO_PTP) {
			if (info.transport != FUJI_FEATURE_AUTOSAVE) {
				log_info("ignoring non-AutoSave connection from %s", info.camera_ip);
				continue;
			}
			log_info("AutoSave request from %s at %s", info.camera_name, info.camera_ip);
			int srv = run_session(&info, &seen);
			if (cfg.once) {
				exit_code = srv ? 1 : 0;
				break;
			}
			continue;
		}

		log_err("discovery failed (%d); retrying in %ds", rc, RETRY_DELAY_SEC);
		for (int i = 0; i < RETRY_DELAY_SEC && !g_stop; i++) sleep(1);
	}

	// Let a running hook finish its upload before we exit
	while (waitpid(-1, NULL, 0) > 0 || errno == EINTR) {}
	seen_close(&seen);
	log_info("stopped");
	return exit_code;
}
