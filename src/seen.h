// Persistent set of files already received from the camera
#ifndef FUJI_SEEN_H
#define FUJI_SEEN_H

#include <stddef.h>

struct SeenStore {
	char *path;
	char **slots;
	size_t cap;
	size_t len;
};

/// @brief Load (or create) the append-only store at path
int seen_open(struct SeenStore *s, const char *path);

/// @brief Returns 1 if key has been recorded before
int seen_has(const struct SeenStore *s, const char *key);

/// @brief Record key, appending "key\tnote" to the store file and fsyncing it
int seen_add(struct SeenStore *s, const char *key, const char *note);

void seen_close(struct SeenStore *s);

#endif
