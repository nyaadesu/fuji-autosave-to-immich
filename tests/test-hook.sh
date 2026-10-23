#!/bin/sh
# Exercise scripts/immich-hook against tests/fake-immich.py: scan and wait, tag,
# stack JPEG+RAF pairs with the JPEG on top, RAW album, idempotent re-runs, a
# scan timeout that keeps the batch queued, Immich being down, RAW_MODE=archive,
# deletions, and the --sync pass that keeps a pair's rating and favorite equal.
set -eu
[ "${TEST_TRACE:-0}" = 1 ] && set -x
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
SERVER=
cleanup() {
	[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
	rm -rf "$T"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fresh library root, state dir and fake Immich for one scenario
setup() {
	if [ -n "$SERVER" ]; then
		kill "$SERVER" 2>/dev/null || true
		wait "$SERVER" 2>/dev/null || true
	fi
	rm -rf "$T/lib" "$T/state" "$T/srv"
	mkdir -p "$T/lib/2026/2026-10-21" "$T/lib/2026/2026-10-22" "$T/state/batches" "$T/srv"
	python3 "$HERE/tests/fake-immich.py" "$T/srv" "$T/lib" /mnt/fuji &
	SERVER=$!
	i=0
	while [ ! -e "$T/srv/port" ]; do
		i=$((i + 1)); [ $i -lt 50 ] || fail "fake Immich did not start"; sleep 0.1
	done
	export IMMICH_URL="http://127.0.0.1:$(cat "$T/srv/port")/api"
}

# Write files and a batch list naming them
batch() {
	name=$1; shift
	: > "$T/state/batches/$name.list"
	for f in "$@"; do
		echo "$f" > "$T/lib/$f"
		echo "$T/lib/$f" >> "$T/state/batches/$name.list"
	done
}

# Query the fake server's state: state 'python expression on s'
state() {
	python3 -c '
import json, sys, urllib.request
req = urllib.request.Request(sys.argv[1] + "/_state", headers={"x-api-key": "test-key"})
s = json.load(urllib.request.urlopen(req))
print(eval(sys.argv[2]))' "$IMMICH_URL" "$1"
}

hook() { "$HERE/scripts/immich-hook" "$@" 2>> "$T/hook.log"; }

# Act like a user in Immich's web UI: user OP [container path [JSON value]]
user() {
	python3 -c '
import json, sys, urllib.request
body = {"op": sys.argv[2]}
if len(sys.argv) > 3:
    body["path"] = sys.argv[3]
if len(sys.argv) > 4:
    body["value"] = json.loads(sys.argv[4])
req = urllib.request.Request(sys.argv[1] + "/_user", data=json.dumps(body).encode(), method="POST",
                             headers={"x-api-key": "test-key", "Content-Type": "application/json"})
urllib.request.urlopen(req)' "$IMMICH_URL" "$@"
}

# As the receiver sets them; the model is what the camera reported this session
export FUJI_STATE_DIR="$T/state" FUJI_INBOX="$T/lib" FUJI_CAMERA_NAME=VCAM FUJI_CAMERA_MODEL="X-T30 II"
export IMMICH_API_KEY=test-key LIBRARY_ID=11111111-1111-4111-8111-111111111111
export PHOTO_ROOT_CONTAINER=/mnt/fuji SCAN_TIMEOUT=20
# Tiny pages, so every scenario walks search cursors
export FAKE_PAGE_MAX=2
# Settings file: its values apply unless the environment already sets them
cat > "$T/env" <<'EOF'
RAW_ALBUM_NAME="Fuji RAW"
CAMERA_TAG_PREFIX='Camera/'
RAW_MODE=stack # or archive; an unquoted " #" starts a comment, as in sh
LIBRARY_ID=from-env-file-must-not-win
EOF
export FUJI_ENV_FILE="$T/env"

D1=2026/2026-10-21 D2=2026/2026-10-22
M=/mnt/fuji

# 1. A pair, an unpaired RAF and an unpaired JPEG
setup
batch b1 $D1/DSCF0001.JPG $D1/DSCF0001.RAF $D1/DSCF0002.RAF $D1/DSCF0003.JPG
hook --check || fail "--check failed"
# As the receiver runs it: with this session's batch list
hook "$T/state/batches/b1.list" || fail "first run failed"
[ ! -e "$T/state/batches/b1.list" ] || fail "batch list not removed"
[ "$(state 'len(s["tags"]["Camera/X-T30 II"])')" = 4 ] || fail "not every file tagged"
[ "$(state 's["stacks"]')" = "[['$M/$D1/DSCF0001.JPG', '$M/$D1/DSCF0001.RAF']]" ] || fail "pair not stacked JPEG-first: $(state 's["stacks"]')"
[ "$(state 's["albums"]["Fuji RAW"]')" = "['$M/$D1/DSCF0001.RAF', '$M/$D1/DSCF0002.RAF']" ] || fail "RAW album wrong: $(state 's["albums"]')"
grep -q "unpaired: $M/$D1/DSCF0002.RAF" "$T/hook.log" || fail "unpaired RAF not logged"
grep -q "unpaired: $M/$D1/DSCF0003.JPG" "$T/hook.log" || fail "unpaired JPEG not logged"
grep -q '1 pair(s) stacked' "$T/hook.log" || fail "summary missing"
grep -q "^POST /api/libraries/$LIBRARY_ID/scan" "$T/srv/calls.log" || fail "no scan"

# 2. Re-run on the same files: nothing new, no restacking, no second album
: > "$T/srv/calls.log"
batch b2 $D1/DSCF0001.JPG $D1/DSCF0001.RAF
hook || fail "re-run failed"
! grep -q '^POST /api/stacks' "$T/srv/calls.log" || fail "re-run restacked"
! grep -q '^POST /api/albums' "$T/srv/calls.log" || fail "re-run created another album"
[ "$(state 'len(s["stacks"])')" = 1 ] || fail "stack count changed"

# 3. Scan timeout: a file Immich never indexes keeps its batch queued, the
#    rest is still processed
export FAKE_HIDE=DSCF0011
setup
unset FAKE_HIDE
batch b3 $D2/DSCF0010.JPG $D2/DSCF0010.RAF $D2/DSCF0011.JPG
if SCAN_TIMEOUT=3 hook; then fail "hook should fail when a file never shows up"; fi
[ -f "$T/state/batches/b3.list" ] || fail "timed-out batch was not kept"
grep -q "not in Immich yet: $M/$D2/DSCF0011.JPG" "$T/hook.log" || fail "missing file not logged"
[ "$(state 'len(s["stacks"])')" = 1 ] || fail "found pair not stacked after timeout"

# 4. Immich down: batch stays queued
batch b4 $D2/DSCF0012.JPG
if IMMICH_URL=http://127.0.0.1:9/api hook; then fail "hook should fail when Immich is down"; fi
[ -f "$T/state/batches/b4.list" ] || fail "batch dropped while Immich was down"

# 5. RAW_MODE=archive: paired RAF archived, not stacked; unpaired RAF stays visible
setup
batch b5 $D1/DSCF0020.JPG $D1/DSCF0020.RAF $D1/DSCF0021.RAF
RAW_MODE=archive hook || fail "archive run failed"
[ "$(state 's["assets"]["'$M/$D1/DSCF0020.RAF'"]["visibility"]')" = archive ] || fail "paired RAF not archived"
[ "$(state 's["assets"]["'$M/$D1/DSCF0021.RAF'"]["visibility"]')" = timeline ] || fail "unpaired RAF archived"
[ "$(state 's["assets"]["'$M/$D1/DSCF0020.JPG'"]["visibility"]')" = timeline ] || fail "JPEG archived"
[ "$(state 'len(s["stacks"])')" = 0 ] || fail "archive mode stacked"
[ "$(state 'len(s["albums"]["Fuji RAW"])')" = 2 ] || fail "archive mode RAW album wrong"

# 6. Camera tag from EXIF: a run without a session model (by hand) tags files
#    by their EXIF Model; one without EXIF yet waits for a later run, which
#    uses the session's model if the file is in its batch
export FAKE_EXIF='DSCF0030:X-H2'
setup
unset FAKE_EXIF
batch b6 $D1/DSCF0030.JPG $D1/DSCF0031.JPG
FUJI_CAMERA_MODEL= hook || fail "run without a session model failed"
[ "$(state 's["tags"]["Camera/X-H2"]')" = "['$M/$D1/DSCF0030.JPG']" ] || fail "EXIF model not used: $(state 's["tags"]')"
[ "$(state 'sum(len(v) for v in s["tags"].values())')" = 1 ] || fail "file without a model got tagged"
grep -q '1 asset(s) not tagged yet' "$T/hook.log" || fail "untagged file not reported"
batch b7 $D1/DSCF0031.JPG
hook "$T/state/batches/b7.list" || fail "run with a session model failed"
[ "$(state 's["tags"]["Camera/X-T30 II"]')" = "['$M/$D1/DSCF0031.JPG']" ] || fail "session model not used: $(state 's["tags"]')"
[ "$(state 'len(s["tags"]["Camera/X-H2"])')" = 1 ] || fail "EXIF-tagged file retagged"

# 7. A fixed CAMERA_TAG overrides the per-camera tags
CAMERA_TAG=Fuji hook || fail "fixed tag run failed"
[ "$(state 'len(s["tags"]["Fuji"])')" = 2 ] || fail "fixed CAMERA_TAG not applied"

# 8. A reused file name is not a pair: the receiver stamps the capture time as
#    mtime, and a JPEG and RAF minutes apart are different shots. The session
#    model is not applied to files outside this session's batch list.
setup
batch b8 $D2/DSCF0040.JPG $D2/DSCF0040.RAF
python3 -c 'import os, sys; os.utime(sys.argv[1], (1e9, 1e9))' "$T/lib/$D2/DSCF0040.RAF"
batch b9 $D2/DSCF0041.JPG
hook "$T/state/batches/b9.list" || fail "mismatched pair run failed"
[ "$(state 'len(s["stacks"])')" = 0 ] || fail "different shots stacked"
grep -q "not pairing $M/$D2/DSCF0040.JPG" "$T/hook.log" || fail "refused pair not logged"
[ "$(state 's["tags"]["Camera/X-T30 II"]')" = "['$M/$D2/DSCF0041.JPG']" ] || fail "session model applied outside its batch: $(state 's["tags"]')"

# 9. Trashed assets are left alone (the structured search would return them)
export FAKE_TRASH=DSCF0051
setup
unset FAKE_TRASH
batch b10 $D1/DSCF0050.RAF $D1/DSCF0051.RAF $D1/DSCF0052.JPG $D1/DSCF0053.JPG
hook "$T/state/batches/b10.list" || fail "a trashed file kept the batch waiting"
[ ! -e "$T/state/batches/b10.list" ] || fail "batch with a trashed file not retired"
[ "$(state 's["albums"]["Fuji RAW"]')" = "['$M/$D1/DSCF0050.RAF']" ] || fail "trashed asset added to album: $(state 's["albums"]')"
[ "$(state 'len(s["tags"]["Camera/X-T30 II"])')" = 3 ] || fail "live assets not all tagged: $(state 's["tags"]')"
[ "$(state '"'$M/$D1/DSCF0051.RAF'" in s["tags"]["Camera/X-T30 II"]')" = False ] || fail "trashed asset tagged"
grep -q '"cursor": ' "$T/srv/calls.log" || fail "search cursors never followed"
# The fake refuses the deprecated flat search fields (as v4 will), so every
# scenario above passing means the hook never sends them; check the refusal
[ "$(python3 -c '
import json, sys, urllib.request, urllib.error
req = urllib.request.Request(sys.argv[1] + "/search/metadata", data=json.dumps({"libraryId": sys.argv[2]}).encode(),
                             headers={"x-api-key": "test-key", "Content-Type": "application/json"}, method="POST")
try:
    urllib.request.urlopen(req); print(200)
except urllib.error.HTTPError as e:
    print(e.code)' "$IMMICH_URL" "$LIBRARY_ID")" = 400 ] || fail "fake Immich accepts flat search fields"

# 10. Immich older than 3.2 (no structured search) is refused up front
export FAKE_VERSION=3.1.4
setup
unset FAKE_VERSION
batch b11 $D1/DSCF0060.JPG
if hook --check; then fail "--check accepted Immich 3.1"; fi
if hook "$T/state/batches/b11.list"; then fail "hook ran against Immich 3.1"; fi
grep -q 'Immich 3.1.4 is too old; this hook needs 3.2 or newer' "$T/hook.log" || fail "version error not logged"
[ -f "$T/state/batches/b11.list" ] || fail "batch dropped on version error"
! grep -q '^POST /api/libraries' "$T/srv/calls.log" || fail "scanned despite the version error"

# 11. What the user changes in Immich sticks: unstack, remove from the album,
#     untag. A trashed photo is left alone; a permanently deleted one has its
#     file (and darktable sidecar) deleted before the scan would import it again.
setup
batch b12 $D1/DSCF0070.JPG $D1/DSCF0070.RAF $D1/DSCF0071.JPG $D1/DSCF0071.RAF $D1/DSCF0072.JPG $D1/DSCF0072.RAF
echo xmp > "$T/lib/$D1/DSCF0072.RAF.xmp"
hook "$T/state/batches/b12.list" || fail "run before user changes failed"
[ "$(state 'len(s["stacks"])')" = 3 ] || fail "pairs not stacked"
user unstack $M/$D1/DSCF0070.JPG
user album_remove $M/$D1/DSCF0071.RAF
user untag $M/$D1/DSCF0071.JPG
user trash $M/$D1/DSCF0072.JPG
user delete $M/$D1/DSCF0072.RAF
: > "$T/srv/calls.log"
hook || fail "run after user changes failed"
[ "$(state 'len(s["stacks"])')" = 1 ] || fail "unstacked pair stacked again: $(state 's["stacks"]')"
[ "$(state '"'$M/$D1/DSCF0071.RAF'" in s["albums"]["Fuji RAW"]')" = False ] || fail "RAF put back into the album"
[ "$(state '"'$M/$D1/DSCF0071.JPG'" in s["tags"]["Camera/X-T30 II"]')" = False ] || fail "untagged file tagged again"
[ -f "$T/lib/$D1/DSCF0072.JPG" ] || fail "trashed photo's file deleted"
[ ! -e "$T/lib/$D1/DSCF0072.RAF" ] || fail "deleted photo's file kept"
[ ! -e "$T/lib/$D1/DSCF0072.RAF.xmp" ] || fail "deleted photo's sidecar kept"
[ "$(state '"'$M/$D1/DSCF0072.RAF'" in s["assets"]')" = False ] || fail "deleted photo imported again"
grep -q "deleted $T/lib/$D1/DSCF0072.RAF (deleted in Immich)" "$T/hook.log" || fail "deletion not logged"
! grep -q -E '^(POST /api/stacks|PUT /api/albums|PUT /api/tags/)' "$T/srv/calls.log" || fail "re-run changed Immich: $(grep -E '^(POST /api/stacks|PUT /api/albums|PUT /api/tags/)' "$T/srv/calls.log")"

# 12. Changing a setting applies once to everything: a renamed RAW album gets
#     the RAFs (except the deleted one), a fixed CAMERA_TAG all live assets
#     (not the trashed DSCF0072.JPG)
RAW_ALBUM_NAME="RAW 2" CAMERA_TAG=Fuji hook || fail "run with new settings failed"
[ "$(state 'len(s["albums"]["RAW 2"])')" = 2 ] || fail "renamed album not filled: $(state 's["albums"]')"
[ "$(state 'len(s["tags"]["Fuji"])')" = 4 ] || fail "new fixed tag not applied: $(state 's["tags"]')"

# 13. DELETE_REMOVED=0 leaves files alone; they come back with the scan
user delete $M/$D1/DSCF0071.JPG
DELETE_REMOVED=0 hook || fail "run with DELETE_REMOVED=0 failed"
[ -f "$T/lib/$D1/DSCF0071.JPG" ] || fail "file deleted despite DELETE_REMOVED=0"
[ "$(state '"'$M/$D1/DSCF0071.JPG'" in s["assets"]')" = True ] || fail "file not imported again"

# 14. Safety stops: too many deletions at once, or Immich listing nothing at
#     all, delete nothing and fail loudly
user delete $M/$D1/DSCF0070.JPG
user delete $M/$D1/DSCF0070.RAF
if DELETE_LIMIT=1 hook; then fail "hook deleted more than DELETE_LIMIT"; fi
[ -f "$T/lib/$D1/DSCF0070.JPG" ] && [ -f "$T/lib/$D1/DSCF0070.RAF" ] || fail "files deleted over the limit"
grep -q "2 of 5 recorded file(s) are no longer in Immich" "$T/hook.log" || fail "limit error not logged"
user wipe
if hook; then fail "hook ran against an empty Immich"; fi
grep -q "Immich lists no assets in the library, but 5 are recorded" "$T/hook.log" || fail "empty-Immich error not logged"
[ "$(find "$T/lib" -type f | wc -l)" = 5 ] || fail "files deleted although Immich listed nothing"

# 15. --sync (the container's timer): no scan, queued batches stay queued,
#     silent when nothing changed. A rating or favorite set on either file of a
#     pair is copied to the other; the JPEG (stack cover) wins if both changed.
#     A photo deleted in Immich loses its file. It skips while a run holds the lock.
export FAKE_EXIF='DSCF008:X-T30 II'
setup
unset FAKE_EXIF
batch b15 $D1/DSCF0080.JPG $D1/DSCF0080.RAF $D1/DSCF0081.JPG $D1/DSCF0081.RAF
user_rated() { state 's["ratings"]["'"$M/$D1/$1"'"]'; }
hook "$T/state/batches/b15.list" || fail "run before sync failed"
batch b16 $D2/DSCF0089.JPG
: > "$T/srv/calls.log"
: > "$T/hook.log"
hook --sync || fail "sync with nothing to do failed"
[ ! -s "$T/hook.log" ] || fail "sync logged without changes: $(cat "$T/hook.log")"
! grep -q '^POST /api/libraries' "$T/srv/calls.log" || fail "sync started a scan"
[ -f "$T/state/batches/b16.list" ] || fail "sync consumed a queued batch"
user rate $M/$D1/DSCF0080.JPG 4
user favorite $M/$D1/DSCF0081.RAF true
hook --sync || fail "sync after rating failed"
[ "$(user_rated DSCF0080.RAF)" = "[4, False]" ] || fail "cover rating not copied to the RAF: $(user_rated DSCF0080.RAF)"
[ "$(user_rated DSCF0081.JPG)" = "[None, True]" ] || fail "RAF favorite not copied to the JPEG: $(user_rated DSCF0081.JPG)"
grep -q 'sync: 2 pair rating/favorite(s) copied' "$T/hook.log" || fail "sync not logged: $(cat "$T/hook.log")"
user rate $M/$D1/DSCF0080.RAF 2
hook --sync || fail "sync after RAF rating failed"
[ "$(user_rated DSCF0080.JPG)" = "[2, False]" ] || fail "RAF rating not copied to the JPEG: $(user_rated DSCF0080.JPG)"
user rate $M/$D1/DSCF0080.JPG 5
user rate $M/$D1/DSCF0080.RAF 1
user rate $M/$D1/DSCF0081.RAF -1
hook --sync || fail "sync after both changed failed"
[ "$(user_rated DSCF0080.RAF)" = "[5, False]" ] || fail "JPEG did not win: $(user_rated DSCF0080.RAF)"
[ "$(user_rated DSCF0081.JPG)" = "[-1, True]" ] || fail "rejection not copied: $(user_rated DSCF0081.JPG)"
user rate $M/$D1/DSCF0080.JPG null
hook --sync || fail "sync after unrating failed"
[ "$(user_rated DSCF0080.RAF)" = "[None, False]" ] || fail "unrating not copied: $(user_rated DSCF0080.RAF)"
user delete $M/$D1/DSCF0081.RAF
python3 -c '
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)' "$T/state/hook.lock" "$T/locked" &
LOCKER=$!
i=0
while [ ! -e "$T/locked" ]; do
	i=$((i + 1)); [ $i -lt 50 ] || fail "lock holder did not start"; sleep 0.1
done
hook --sync || fail "sync failed while locked"
[ -f "$T/lib/$D1/DSCF0081.RAF" ] || fail "sync ran despite the lock"
kill $LOCKER; wait $LOCKER 2>/dev/null || true
hook --sync || fail "sync after delete failed"
[ ! -e "$T/lib/$D1/DSCF0081.RAF" ] || fail "sync kept a deleted photo's file"
grep -q "deleted $T/lib/$D1/DSCF0081.RAF (deleted in Immich)" "$T/hook.log" || fail "sync deletion not logged"
grep -q '^PUT /api/assets .*"rating": null' "$T/srv/calls.log" || fail "unrated sent as something other than null"

echo "immich-hook: all checks passed"
