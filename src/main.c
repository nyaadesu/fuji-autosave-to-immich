// fuji-autosave-receiver: a headless FUJIFILM PC AutoSave target built on libfuji.
// Waits for the camera's AutoSave broadcast, pulls every new object over PTP/IP
// into <inbox>/YYYY/YYYY-MM-DD/, and runs a hook once per batch.
#include <dirent.h>
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
#include "exif.h"
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
	char part_path[PATH_MAX];
	int count;
};

static struct Config cfg = {
	.inbox = "/fuji",
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
		if (mkdir(tmp, 0775) && errno != EEXIST) return -1;
		*p = '/';
	}
	if (mkdir(tmp, 0775) && errno != EEXIST) return -1;
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

// Capture instant from a PTP date "YYYYMMDDThhmmss". The X-T30 II reports
// UTC here (its EXIF holds local time plus offset); 0 if malformed.
static int capture_time(const char *date, time_t *out) {
	struct tm tm = {0};
	if (strlen(date) < 15 || date[8] != 'T'
			|| sscanf(date, "%4d%2d%2dT%2d%2d%2d", &tm.tm_year, &tm.tm_mon, &tm.tm_mday,
				&tm.tm_hour, &tm.tm_min, &tm.tm_sec) != 6) return 0;
	tm.tm_year -= 1900;
	tm.tm_mon -= 1;
	*out = timegm(&tm);
	return *out != (time_t)-1;
}

#define DAY_DIR_LEN 16

static void day_dir_from_tm(const struct tm *tm, char out[DAY_DIR_LEN]) {
	strftime(out, DAY_DIR_LEN, "%Y/%Y-%m-%d", tm);
}

// "YYYY/YYYY-MM-DD" for a downloaded file: the local date in its EXIF (what
// the camera's clock said, wherever it was), else the PTP capture instant in
// this machine's time zone, else today
static void day_dir_for_file(const char *path, const char *ptp_date, char out[DAY_DIR_LEN]) {
	char date[EXIF_DATE_LEN];
	if (exif_capture_date(path, date) == 0) {
		snprintf(out, DAY_DIR_LEN, "%.4s/%s", date, date);
		return;
	}
	time_t t;
	if (!capture_time(ptp_date, &t)) t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);
	day_dir_from_tm(&tm, out);
}

// 1 if the inbox already holds this shot (e.g. the seen list was lost): same
// name, size and mtime (the capture instant we stamp). Size alone is not
// enough: uncompressed RAFs are all the same size, and DSCF0001 repeats after
// a counter reset or rollover. The day folder comes from EXIF, which is only
// known after downloading, so check the days around the UTC capture date
// (local time is within -12..+14 h of it).
static int already_in_inbox(const struct PtpObjectInfo *oi, const char *name) {
	time_t t;
	if (!capture_time(oi->date_created, &t)) return 0;
	for (int k = -1; k <= 1; k++) {
		time_t day_t = t + k * 86400;
		struct tm tm;
		gmtime_r(&day_t, &tm);
		char day[DAY_DIR_LEN], path[PATH_MAX];
		day_dir_from_tm(&tm, day);
		if (snprintf(path, sizeof(path), "%s/%s/%s", cfg.inbox, day, name) >= (int)sizeof(path)) continue;
		struct stat st;
		if (stat(path, &st) == 0 && S_ISREG(st.st_mode)
				&& st.st_size == (off_t)oi->compressed_size && st.st_mtime == t) return 1;
	}
	return 0;
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

// ptp_close() frees the runtime and everything libpict allocated for it, but
// not the Fuji priv struct, which belongs to libfuji
static void free_runtime(struct PtpRuntime *r) {
	free(r->priv);
	r->priv = NULL;
	ptp_close(r);
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
	// Written as .list.part and renamed when the session ends, so a hook that
	// is already running never picks up (and retires) a half-written list
	if (snprintf(b->part_path, sizeof(b->part_path), "%s.part", b->list_path) >= (int)sizeof(b->part_path)) return -1;
	b->list = fopen(b->part_path, "w");
	b->count = 0;
	return b->list == NULL ? -1 : 0;
}

// Lists left as .list.part by a crash: their files were saved, so queue them
static void recover_batches(void) {
	char dir[PATH_MAX];
	if (snprintf(dir, sizeof(dir), "%s/batches", cfg.state_dir) >= (int)sizeof(dir)) return;
	DIR *d = opendir(dir);
	if (d == NULL) return;
	struct dirent *e;
	while ((e = readdir(d)) != NULL) {
		size_t len = strlen(e->d_name);
		if (len <= 10 || strcmp(e->d_name + len - 10, ".list.part") != 0) continue;
		char from[PATH_MAX], to[PATH_MAX];
		if (snprintf(from, sizeof(from), "%s/%s", dir, e->d_name) >= (int)sizeof(from)) continue;
		snprintf(to, sizeof(to), "%.*s", (int)strlen(from) - 5, from);
		if (rename(from, to) == 0) log_info("queued unfinished batch list %s", to);
	}
	closedir(d);
}

static void run_hook(struct Batch *b, const struct DiscoverInfo *info) {
	if (b->list == NULL) return;
	fclose(b->list);
	b->list = NULL;

	if (b->count == 0 || cfg.hook == NULL) {
		// Nothing consumes batch lists without a hook
		unlink(b->part_path);
		return;
	}
	if (rename(b->part_path, b->list_path)) {
		log_err("rename %s: %s", b->part_path, strerror(errno));
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
	// 0664 here and 0775 in mkdir_p: the umask decides (002 for a shared edit group)
	sink.fd = open(part, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0664);
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
	// mtime = capture time: lets already_in_inbox() and the hook's pairing
	// tell shots with the same file name apart
	time_t shot;
	if (rc == 0 && capture_time(oi->date_created, &shot)) {
		struct timespec ts[2] = {{0, UTIME_OMIT}, {shot, 0}};
		if (futimens(sink.fd, ts)) log_err("%s: cannot set mtime: %s", name, strerror(errno));
	}
	if (rc == 0 && fsync(sink.fd)) rc = -1;
	if (close(sink.fd)) rc = -1;
	if (rc) {
		unlink(part);
		log_err("download of %s failed (%d)", name, rc);
		return rc;
	}

	char day[DAY_DIR_LEN], dir[PATH_MAX], final[PATH_MAX];
	day_dir_for_file(part, oi->date_created, day);
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
	int n_new = 0, n_skipped = 0, n_present = 0;

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
		char name[128];
		sanitize_name(oi.filename, name, sizeof(name));
		if (already_in_inbox(&oi, name)) {
			log_info("object %d: %s is already in the inbox, skipping", handle, name);
			if (seen_add(seen, key, name)) {
				log_err("could not record %s in the seen list: %s", name, strerror(errno));
			}
			n_present++;
			continue;
		}

		rc = download_one(r, handle, &oi, key, seen, &batch);
		// A half-read object leaves the camera unresponsive; drop the session
		if (rc) goto out;
		n_new++;
	}

	out:;
	if (!cfg.list_only) {
		if (n_present > 0) {
			log_info("session done: %d new, %d already seen, %d already in the inbox", n_new, n_skipped, n_present);
		} else {
			log_info("session done: %d new, %d already seen", n_new, n_skipped);
		}
	}
	if (connected) {
		// Close session, send Fuji's goodbye packet, close sockets
		ptp_report_error(r, NULL, 0);
	}
	run_hook(&batch, info);
	free_runtime(r);
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
	if (!cfg.list_only) recover_batches();

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
		free_runtime(dr);

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

	// Let a running hook finish (it may be waiting on an Immich scan) before we exit
	while (waitpid(-1, NULL, 0) > 0 || errno == EINTR) {}
	seen_close(&seen);
	log_info("stopped");
	return exit_code;
}
