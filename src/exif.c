// Minimal EXIF reader: just enough to find the capture date of a camera JPEG
// or of the JPEG preview inside a Fujifilm RAF.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "exif.h"

// The EXIF block (APP1, at most 64 KiB) sits at the start of the JPEG
#define READ_LEN (128 * 1024)
#define RAF_MAGIC "FUJIFILMCCD-RAW"
#define RAF_HEADER_LEN 92

#define TAG_DATETIME 0x0132
#define TAG_EXIF_IFD 0x8769
#define TAG_DATETIME_ORIGINAL 0x9003
#define TYPE_ASCII 2

struct Tiff {
	const uint8_t *p;
	size_t len;
	int big_endian;
};

static uint32_t be32(const uint8_t *p) {
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int tiff_u16(const struct Tiff *t, size_t off, uint16_t *out) {
	if (off > t->len || t->len - off < 2) return -1;
	const uint8_t *p = t->p + off;
	*out = t->big_endian ? (uint16_t)(p[0] << 8 | p[1]) : (uint16_t)(p[1] << 8 | p[0]);
	return 0;
}

static int tiff_u32(const struct Tiff *t, size_t off, uint32_t *out) {
	if (off > t->len || t->len - off < 4) return -1;
	const uint8_t *p = t->p + off;
	*out = t->big_endian ? be32(p)
		: (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
	return 0;
}

// Offset of the 12-byte entry for `tag` in the IFD at `ifd`, or 0 if absent
static size_t ifd_find(const struct Tiff *t, uint32_t ifd, uint16_t tag) {
	uint16_t n, entry_tag;
	if (tiff_u16(t, ifd, &n)) return 0;
	for (uint32_t i = 0; i < n; i++) {
		size_t entry = (size_t)ifd + 2 + (size_t)i * 12;
		if (tiff_u16(t, entry, &entry_tag) || t->len - entry < 12) return 0;
		if (entry_tag == tag) return entry;
	}
	return 0;
}

// "YYYY:MM:DD HH:MM:SS" ASCII value of the entry -> "YYYY-MM-DD"
static int entry_date(const struct Tiff *t, size_t entry, char out[EXIF_DATE_LEN]) {
	uint16_t type;
	uint32_t count, off;
	if (entry == 0 || tiff_u16(t, entry + 2, &type) || tiff_u32(t, entry + 4, &count)) return -1;
	// At least "YYYY:MM:DD" + NUL, so the value is stored at an offset, not inline
	if (type != TYPE_ASCII || count < 11) return -1;
	if (tiff_u32(t, entry + 8, &off) || off > t->len || t->len - off < 10) return -1;
	const char *s = (const char *)t->p + off;
	static const char pattern[] = "dddd:dd:dd";
	for (int i = 0; i < 10; i++) {
		if (pattern[i] == 'd' ? (s[i] < '0' || s[i] > '9') : s[i] != ':') return -1;
	}
	// "0000:00:00" is what cameras write when the clock was never set
	if (!memcmp(s, "0000", 4) || !memcmp(s + 5, "00", 2) || !memcmp(s + 8, "00", 2)) return -1;
	snprintf(out, EXIF_DATE_LEN, "%.4s-%.2s-%.2s", s, s + 5, s + 8);
	return 0;
}

static int tiff_date(const uint8_t *p, size_t len, char out[EXIF_DATE_LEN]) {
	struct Tiff t = {p, len, 0};
	if (len < 8) return -1;
	if (!memcmp(p, "MM\0*", 4)) t.big_endian = 1;
	else if (memcmp(p, "II*\0", 4)) return -1;
	uint32_t ifd0, exif_ifd;
	if (tiff_u32(&t, 4, &ifd0)) return -1;
	size_t entry = ifd_find(&t, ifd0, TAG_EXIF_IFD);
	if (entry && !tiff_u32(&t, entry + 8, &exif_ifd)
			&& !entry_date(&t, ifd_find(&t, exif_ifd, TAG_DATETIME_ORIGINAL), out)) return 0;
	return entry_date(&t, ifd_find(&t, ifd0, TAG_DATETIME), out);
}

static int jpeg_date(const uint8_t *p, size_t len, char out[EXIF_DATE_LEN]) {
	if (len < 4 || p[0] != 0xFF || p[1] != 0xD8) return -1;
	size_t pos = 2;
	while (len - pos >= 4 && p[pos] == 0xFF) {
		uint8_t marker = p[pos + 1];
		if (marker == 0xDA || marker == 0xD9) break;  // image data starts / end
		size_t seg_len = (size_t)p[pos + 2] << 8 | p[pos + 3];
		if (seg_len < 2 || seg_len > len - pos - 2) break;
		const uint8_t *seg = p + pos + 4;
		size_t body = seg_len - 2;
		if (marker == 0xE1 && body > 6 && !memcmp(seg, "Exif\0\0", 6)) {
			return tiff_date(seg + 6, body - 6, out);
		}
		pos += 2 + seg_len;
	}
	return -1;
}

static ssize_t read_at(int fd, uint8_t *buf, size_t len, off_t off) {
	size_t got = 0;
	while (got < len) {
		ssize_t n = pread(fd, buf + got, len - got, off + (off_t)got);
		if (n < 0) return -1;
		if (n == 0) break;
		got += (size_t)n;
	}
	return (ssize_t)got;
}

int exif_capture_date(const char *path, char out[EXIF_DATE_LEN]) {
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	uint8_t *buf = malloc(READ_LEN);
	int rc = -1;
	if (buf == NULL) goto out;

	ssize_t n = read_at(fd, buf, READ_LEN, 0);
	if (n >= RAF_HEADER_LEN && !memcmp(buf, RAF_MAGIC, strlen(RAF_MAGIC))) {
		// RAF: big-endian offset of the embedded JPEG at byte 84
		uint32_t jpeg_off = be32(buf + 84);
		n = read_at(fd, buf, READ_LEN, (off_t)jpeg_off);
	}
	if (n > 0) rc = jpeg_date(buf, (size_t)n, out);

	out:;
	free(buf);
	close(fd);
	return rc;
}
