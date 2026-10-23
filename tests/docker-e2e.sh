#!/bin/sh
# The Docker image end to end: an emulated camera (vcam), the receiver
# container and a fake Immich on a private Docker network (192.168.1.0/24,
# where vcam broadcasts). Checks the image's defaults, `check`, a full
# AutoSave session into the bind-mounted library after the receiver's address
# changed, the hook's work in Immich, the --sync timer, and a quick stop.
#
#   tests/docker-e2e.sh            needs docker access (docker group or sudo)
#   IMAGE=name SKIP_BUILD=1 ...    test an image that is already built
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${IMAGE:-fuji-autosave:test}
VCAM_IMAGE=fuji-vcam:test
NET=fuji-e2e-$$
LIB_ID=11111111-1111-4111-8111-111111111111
T=$(mktemp -d)

cleanup() {
	docker rm -f "$NET-recv" "$NET-recv2" "$NET-vcam" "$NET-immich" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	# The containers wrote as uid 1000, which may not be us: remove as root in a container
	docker run --rm --user 0 -v "$T:/t" --entrypoint rm "$IMAGE" -rf /t/lib /t/state /t/srv >/dev/null 2>&1 || true
	rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT
fail() {
	echo "FAIL: $*" >&2
	for c in recv recv2 vcam immich; do
		echo "--- $c" >&2
		docker logs "$NET-$c" 2>&1 | grep -v -E 'ptp_send_packet|Sending 101b' | tail -25 >&2 || true
	done
	exit 1
}

if [ "${SKIP_BUILD:-0}" != 1 ]; then
	[ -f "$ROOT/third_party/libpict/CMakeLists.txt" ] || "$ROOT/scripts/fetch-deps.sh"
	docker build -q -t "$IMAGE" "$ROOT" >/dev/null
fi
docker build -q -t "$VCAM_IMAGE" -f "$ROOT/tests/docker/vcam.Dockerfile" "$ROOT/tests/docker" >/dev/null

# Image defaults: non-root, receiver and hook installed
[ "$(docker run --rm "$IMAGE" id -u)" = 1000 ] || fail "image does not run as uid 1000"
docker run --rm "$IMAGE" test -x /usr/local/bin/fuji-autosave-receiver -a -x /usr/local/lib/fuji-autosave/immich-hook \
	|| fail "receiver or hook missing from the image"

# Library, state and the camera's card; the containers run as uid 1000
mkdir -p "$T/lib" "$T/state" "$T/srv" "$T/sd/DCIM/100_FUJI"
chmod 777 "$T/lib" "$T/state" "$T/srv"
head -c 3145728 /dev/urandom > "$T/sd/DCIM/100_FUJI/DSCF0001.RAF"
head -c 2097152 /dev/urandom > "$T/sd/DCIM/100_FUJI/DSCF0002.RAF"
head -c 65536 /dev/urandom > "$T/sd/DCIM/100_FUJI/DSCF0002.JPG"  # vcam never offers its last file

docker network create --subnet 192.168.1.0/24 "$NET" >/dev/null

# Fake Immich (python3 from the image), reading the library read-only like immich-server
docker run -d --name "$NET-immich" --network "$NET" --ip 192.168.1.30 \
	-v "$ROOT/tests:/tests:ro" -v "$T/lib:/library:ro" -v "$T/srv:/srv" \
	-e FAKE_LISTEN=0.0.0.0:2283 --entrypoint python3 \
	"$IMAGE" /tests/fake-immich.py /srv /library /mnt/fuji >/dev/null
i=0
while [ ! -e "$T/srv/port" ]; do
	i=$((i + 1)); [ $i -lt 100 ] || fail "fake Immich did not start"; sleep 0.1
done

run_env="-e IMMICH_URL=http://192.168.1.30:2283 -e IMMICH_API_KEY=test-key -e LIBRARY_ID=$LIB_ID"

# `check` against the fake Immich
# shellcheck disable=SC2086
docker run --rm --network "$NET" $run_env -v "$T/lib:/fuji" "$IMAGE" check > "$T/check.log" 2>&1 \
	|| { cat "$T/check.log" >&2; fail "check failed"; }
grep -q 'immich-hook: ok:' "$T/check.log" || fail "check did not report ok"

# Wait until container NAME logged PATTERN: wait_log NAME PATTERN
wait_log() {
	i=0
	until docker logs "$NET-$1" 2>&1 | grep -q "$2"; do
		i=$((i + 1)); [ $i -lt 30 ] || fail "$1 never logged: $2"; sleep 1
	done
}

# One AutoSave session: receiver waits, vcam pushes, receiver exits (--once)
# after its hook finished
# shellcheck disable=SC2086
docker run -d --name "$NET-recv" --network "$NET" --ip 192.168.1.10 $run_env \
	-e FUJI_EXTRA_ARGS="--once --verbose" -v "$T/lib:/fuji" \
	"$IMAGE" >/dev/null
# A new address while it waits (a new DHCP lease): discovery was bound to the
# old one, so the receiver has to restart it for the camera to get through
wait_log recv 'Binding to 51541'
sleep 2
docker network disconnect "$NET" "$NET-recv"
docker network connect --ip 192.168.1.11 "$NET" "$NET-recv"
wait_log recv 'local address changed from 192.168.1.10 to 192.168.1.11'
docker run -d --name "$NET-vcam" --network "$NET" --ip 192.168.1.20 -v "$T/sd:/sd:ro" \
	"$VCAM_IMAGE" fuji_x_t4 tcp --discovery --fs /sd >/dev/null
i=0
while [ "$(docker inspect -f '{{.State.Running}}' "$NET-recv")" = true ]; do
	i=$((i + 1)); [ $i -lt 120 ] || fail "receiver did not finish the session"; sleep 1
done
[ "$(docker inspect -f '{{.State.ExitCode}}' "$NET-recv")" = 0 ] || fail "receiver exited non-zero"
docker logs "$NET-recv" > "$T/recv.log" 2>&1

grep -q 'session done: 2 new, 0 already seen' "$T/recv.log" || fail "unexpected session summary"
# vcam offers its files in directory order, which depends on the filesystem,
# and never the last one: check the two the receiver saved
saved=$(sed -n 's|^saved /fuji/\([^ ]*\) .*|\1|p' "$T/recv.log")
[ "$(echo "$saved" | wc -l)" -eq 2 ] || fail "expected 2 saved files, got: $saved"
raws=0
for rel in $saved; do
	echo "$rel" | grep -q -E '^[0-9]{4}/[0-9]{4}-[0-9]{2}-[0-9]{2}/DSCF[0-9]{4}\.(JPG|RAF)$' \
		|| fail "$rel not in a YYYY/YYYY-MM-DD folder"
	cmp -s "$T/lib/$rel" "$T/sd/DCIM/100_FUJI/${rel##*/}" || fail "$rel corrupt"
	[ "$(stat -c %u "$T/lib/$rel")" = 1000 ] || fail "$rel not owned by uid 1000"
	case $rel in *.RAF) raws=$((raws + 1)) ;; esac
done
grep -q 'immich-hook: done: 2 new file(s) found, 0 still missing' "$T/recv.log" || fail "hook did not finish the batch"

state() {
	docker exec "$NET-immich" python3 -c '
import json, sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:2283/api/_state", headers={"x-api-key": "test-key"})
s = json.load(urllib.request.urlopen(req))
print(eval(sys.argv[1]))' "$1"
}
[ "$(state 'len(s["tags"].get("Camera/X-T4", []))')" = 2 ] || fail "files not tagged Camera/X-T4: $(state 's["tags"]')"
[ "$(state 'len(s["albums"].get("Fuji RAW", []))')" = "$raws" ] || fail "RAFs not in the RAW album: $(state 's["albums"]')"
[ -f "$T/lib/.fuji-autosave/library.json" ] && [ -f "$T/lib/.fuji-autosave/seen.tsv" ] || fail "state not written to the library's .fuji-autosave"

# The --sync timer calls Immich between batches (no scan), and a stop doesn't
# wait for it: the receiver waits for its children on exit, so the timer must
# not be one
lines=$(wc -l < "$T/srv/calls.log")
# shellcheck disable=SC2086
docker run -d --name "$NET-recv2" --network "$NET" --ip 192.168.1.12 $run_env \
	-e SYNC_INTERVAL=2 -v "$T/lib:/fuji" "$IMAGE" >/dev/null
wait_log recv2 'listening for PC AutoSave'
sleep 6
calls=$(tail -n +$((lines + 1)) "$T/srv/calls.log")
echo "$calls" | grep -q '^POST /api/search/metadata' || fail "the --sync timer made no Immich calls"
! echo "$calls" | grep -q '^POST /api/libraries/.*/scan' || fail "the --sync timer started a scan"
start=$(date +%s)
docker stop "$NET-recv2" >/dev/null
took=$(($(date +%s) - start))
[ "$took" -lt 8 ] || fail "docker stop took ${took}s: the receiver waited for the --sync timer"
docker logs "$NET-recv2" 2>&1 | grep -q '^stopped$' || fail "receiver did not stop cleanly"

echo "docker: all checks passed"
