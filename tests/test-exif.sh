#!/bin/sh
# src/exif.c (via build/exif-date): capture dates from JPEG and RAF, both byte
# orders, the IFD0 fallback, unset clocks, and malformed or fuzzed files from
# the camera that must be rejected without crashing.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=${EXIF_DATE:-$HERE/build/exif-date}
[ -x "$BIN" ] || { echo "build first (cmake --build build)" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

python3 - "$T" <<'EOF'
import os, random, struct, sys
out = sys.argv[1]

def tiff(bo, ifd0_date=None, exif_date=None, count=None):
    """TIFF with IFD0 (optional DateTime, ExifIFD pointer) and an Exif IFD."""
    e = "<" if bo == "II" else ">"
    data = bytearray(b"II*\0" if bo == "II" else b"MM\0*")
    data += struct.pack(e + "I", 8)
    def ascii_entry(tag, s, at):
        b = s.encode() + b"\0"
        return struct.pack(e + "HHII", tag, 2, count or len(b), at), b
    # IFD0 at 8: up to 2 entries + next-IFD pointer
    n0 = (ifd0_date is not None) + (exif_date is not None)
    ifd0_end = 8 + 2 + 12 * n0 + 4
    exif_ifd = ifd0_end
    exif_end = exif_ifd + 2 + 12 + 4
    blobs, entries0, pos = [], [], exif_end
    if ifd0_date is not None:
        ent, b = ascii_entry(0x0132, ifd0_date, pos); entries0.append(ent); blobs.append(b); pos += len(b)
    if exif_date is not None:
        entries0.append(struct.pack(e + "HHII", 0x8769, 4, 1, exif_ifd))
    data += struct.pack(e + "H", len(entries0)) + b"".join(entries0) + struct.pack(e + "I", 0)
    if exif_date is not None:
        ent, b = ascii_entry(0x9003, exif_date, pos)
        data += struct.pack(e + "H", 1) + ent + struct.pack(e + "I", 0)
        blobs.append(b)
    else:
        data += b"\0" * (exif_end - exif_ifd)
    return bytes(data + b"".join(blobs))

def jpeg(t):
    app1 = b"Exif\0\0" + t
    return b"\xff\xd8" + b"\xff\xe0\x00\x10JFIF\0\x01\x01\0\0\x01\0\x01\0\0" \
        + b"\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1 + b"\xff\xda\x00\x02" + os.urandom(64) + b"\xff\xd9"

def raf(j):
    header = bytearray(b"FUJIFILMCCD-RAW 0201FF383501X-T30 II".ljust(84, b"\0"))
    header += struct.pack(">II", 160, len(j))
    return bytes(header.ljust(160, b"\0")) + j

def w(name, b):
    open(os.path.join(out, name), "wb").write(b)

# Just after midnight local: the PTP (UTC) date would be the day before
good = jpeg(tiff("II", ifd0_date="2026:10:22 23:59:00", exif_date="2026:10:23 00:30:00"))
w("le.jpg", good)
w("be.jpg", jpeg(tiff("MM", exif_date="2026:10:23 00:30:00")))
w("ifd0-only.jpg", jpeg(tiff("II", ifd0_date="2026:06:28 09:33:57")))
w("both.raf", raf(good))
w("unset-clock.jpg", jpeg(tiff("II", exif_date="0000:00:00 00:00:00")))
w("garbage-date.jpg", jpeg(tiff("II", exif_date="2026-10-23 00:30:00")))
w("huge-count.jpg", jpeg(tiff("II", exif_date="2026:10:23 00:30:00", count=0x7fffffff)))
w("truncated.jpg", good[:40])
w("no-exif.jpg", b"\xff\xd8\xff\xda\x00\x02" + os.urandom(256))
w("random.bin", os.urandom(4096))
w("raf-bad-offset.raf", raf(good)[:84] + struct.pack(">II", 0xfffffff0, 10) + b"\0" * 64)
w("empty.jpg", b"")

# Fuzz: flip, cut and overwrite bytes of valid files
rnd = random.Random(1)
for i in range(400):
    b = bytearray(rnd.choice([good, raf(good)]))
    for _ in range(rnd.randint(1, 8)):
        op = rnd.random()
        p = rnd.randrange(len(b))
        if op < 0.6:
            b[p] = rnd.randrange(256)
        elif op < 0.8:
            b[p:p + 4] = rnd.choice([b"\xff\xff\xff\xff", b"\0\0\0\0", b"\x7f\xff\xff\xff"])
        else:
            del b[p:]
            if not b:
                b = bytearray(b"\xff")
    w(f"fuzz-{i:03}.jpg", bytes(b))
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() {
	got=$("$BIN" "$T/$1" || true)
	[ "$got" = "$2" ] || fail "$1: got '$got', want '$2'"
}

expect le.jpg 2026-10-23              # DateTimeOriginal beats IFD0 DateTime
expect be.jpg 2026-10-23
expect ifd0-only.jpg 2026-06-28
expect both.raf 2026-10-23            # through the RAF's embedded JPEG
expect unset-clock.jpg none
expect garbage-date.jpg none
expect huge-count.jpg 2026-10-23     # count is not trusted for reading
expect truncated.jpg none
expect no-exif.jpg none
expect random.bin none
expect raf-bad-offset.raf none
expect empty.jpg none
expect missing.jpg none

# Fuzzed files: any answer is fine, crashing is not (exit 0 = date, 1 = none)
set +e
"$BIN" "$T"/fuzz-*.jpg > "$T/fuzz.out"
rc=$?
set -e
[ $rc -le 1 ] || fail "exif-date crashed on fuzzed input (exit $rc)"
[ "$(wc -l < "$T/fuzz.out")" -eq 400 ] || fail "fuzz run stopped early"
grep -v -E '^(none|[0-9]{4}-[0-9]{2}-[0-9]{2})$' "$T/fuzz.out" && fail "unexpected fuzz output"

echo "exif: all checks passed"
