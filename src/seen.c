// Append-only text store: one "key\tnote" line per received file.
// Keys are held in an open-addressing hash set; the file is the source of truth.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "seen.h"

static uint64_t hash_str(const char *str) {
	// FNV-1a
	uint64_t h = 0xcbf29ce484222325ULL;
	for (; *str; str++) {
		h ^= (unsigned char)*str;
		h *= 0x100000001b3ULL;
	}
	return h;
}

static int insert_slot(char **slots, size_t cap, char *key) {
	size_t i = hash_str(key) & (cap - 1);
	while (slots[i] != NULL) {
		if (!strcmp(slots[i], key)) return 0;
		i = (i + 1) & (cap - 1);
	}
	slots[i] = key;
	return 1;
}

static int grow(struct SeenStore *s) {
	size_t cap = s->cap ? s->cap * 2 : 1024;
	char **slots = calloc(cap, sizeof(char *));
	if (slots == NULL) return -1;
	for (size_t i = 0; i < s->cap; i++) {
		if (s->slots[i] != NULL) insert_slot(slots, cap, s->slots[i]);
	}
	free(s->slots);
	s->slots = slots;
	s->cap = cap;
	return 0;
}

static int insert(struct SeenStore *s, const char *key) {
	if ((s->len + 1) * 2 > s->cap) {
		if (grow(s)) return -1;
	}
	char *copy = strdup(key);
	if (copy == NULL) return -1;
	if (insert_slot(s->slots, s->cap, copy)) {
		s->len++;
	} else {
		free(copy);
	}
	return 0;
}

int seen_open(struct SeenStore *s, const char *path) {
	memset(s, 0, sizeof(*s));
	s->path = strdup(path);
	if (s->path == NULL || grow(s)) return -1;

	FILE *f = fopen(path, "r");
	if (f == NULL) {
		if (errno == ENOENT) return 0;
		return -1;
	}

	char *line = NULL;
	size_t n = 0;
	while (getline(&line, &n, f) > 0) {
		line[strcspn(line, "\t\r\n")] = '\0';
		if (line[0] == '\0' || line[0] == '#') continue;
		if (insert(s, line)) {
			free(line);
			fclose(f);
			return -1;
		}
	}
	free(line);
	fclose(f);
	return 0;
}

int seen_has(const struct SeenStore *s, const char *key) {
	size_t i = hash_str(key) & (s->cap - 1);
	while (s->slots[i] != NULL) {
		if (!strcmp(s->slots[i], key)) return 1;
		i = (i + 1) & (s->cap - 1);
	}
	return 0;
}

int seen_add(struct SeenStore *s, const char *key, const char *note) {
	int fd = open(s->path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
	if (fd < 0) return -1;
	FILE *f = fdopen(fd, "a");
	if (f == NULL) {
		close(fd);
		return -1;
	}
	int rc = fprintf(f, "%s\t%s\n", key, note ? note : "") < 0;
	rc |= fflush(f) != 0;
	rc |= fsync(fd) != 0;
	rc |= fclose(f) != 0;
	if (rc) return -1;
	return insert(s, key);
}

void seen_close(struct SeenStore *s) {
	for (size_t i = 0; i < s->cap; i++) free(s->slots[i]);
	free(s->slots);
	free(s->path);
	memset(s, 0, sizeof(*s));
}
