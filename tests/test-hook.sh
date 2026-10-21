#!/bin/sh
# Exercise scripts/immich-hook with a stub Immich CLI: a failed upload must leave
# the batch queued, a retry must upload and archive the files.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/inbox/2026-10-21" "$T/state/batches"
echo raf > "$T/inbox/2026-10-21/DSCF0001.RAF"
echo jpg > "$T/inbox/2026-10-21/DSCF0001.JPG"
printf '%s\n' "$T/inbox/2026-10-21/DSCF0001.RAF" "$T/inbox/2026-10-21/DSCF0001.JPG" > "$T/state/batches/b1.list"

cat > "$T/immich" <<EOF
#!/bin/sh
echo "\$*" >> "$T/immich.calls"
exit \${STUB_RC:-0}
EOF
chmod +x "$T/immich"

export FUJI_STATE_DIR="$T/state" FUJI_INBOX="$T/inbox" FUJI_CAMERA_NAME=VCAM
export IMMICH_INSTANCE_URL=http://immich.invalid IMMICH_API_KEY=x IMMICH_BIN="$T/immich"
export FUJI_IMMICH_ALBUM="Fuji X-T30 II"

# Settings file: its values apply unless the environment already sets them
cat > "$T/env" <<'EOF'
FUJI_IMMICH_ALBUM=from-env-file
FUJI_KEEP_FILES=0
EOF
export FUJI_ENV_FILE="$T/env"

fail() { echo "FAIL: $*" >&2; exit 1; }

if STUB_RC=1 "$HERE/scripts/immich-hook"; then fail "hook should fail when upload fails"; fi
[ -f "$T/state/batches/b1.list" ] || fail "failed batch was not kept"
[ -f "$T/inbox/2026-10-21/DSCF0001.RAF" ] || fail "file moved after failed upload"

"$HERE/scripts/immich-hook" || fail "retry failed"
[ ! -e "$T/state/batches/b1.list" ] || fail "batch list not removed after upload"
[ -f "$T/inbox/archive/2026-10-21/DSCF0001.RAF" ] || fail "RAF not archived"
[ -f "$T/inbox/archive/2026-10-21/DSCF0001.JPG" ] || fail "JPG not archived"
grep -q -- '--album-name Fuji X-T30 II' "$T/immich.calls" || fail "album not passed"

echo "immich-hook: all checks passed"
