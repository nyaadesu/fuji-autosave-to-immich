#!/bin/sh
# End-to-end test against petabyt/vcam's emulated Fuji camera in PC AutoSave mode.
#
# Runs the receiver and vcam inside a private user+network namespace with a
# dummy 192.168.1.0/24 interface (vcam broadcasts to 192.168.1.255), so it needs
# no root and does not touch the host network. Requires: unshare, ip, cmake,
# ninja, libusb-1.0 and libexif headers.
#
# Checks: a batch is downloaded byte-identical into YYYY/YYYY-MM-DD, the hook gets the batch list,
# and a second session skips everything already received.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VCAM_REV=c25376ed6f7b19a2dd430897f8008837f5e1962c
WORK=$ROOT/build/e2e
RECV=${RECV:-$ROOT/build/fuji-autosave-receiver}

if [ "${1:-}" != --in-netns ]; then
	[ -x "$RECV" ] || { echo "build the receiver first (cmake --build build)" >&2; exit 1; }
	if [ ! -x "$ROOT/build/vcam/build/vcam" ]; then
		rm -rf "$ROOT/build/vcam"
		git clone -q https://github.com/petabyt/vcam "$ROOT/build/vcam"
		git -C "$ROOT/build/vcam" checkout -q "$VCAM_REV"
		cmake -S "$ROOT/build/vcam" -B "$ROOT/build/vcam/build" -G Ninja >/dev/null
		cmake --build "$ROOT/build/vcam/build" >/dev/null
	fi
	# --prepare: only fetch and build vcam (while network is available)
	[ "${1:-}" = --prepare ] && exit 0

	rm -rf "$WORK"
	mkdir -p "$WORK/sd/DCIM/100_FUJI"
	head -c 3145728 /dev/urandom > "$WORK/sd/DCIM/100_FUJI/DSCF0001.RAF"
	head -c 2097152 /dev/urandom > "$WORK/sd/DCIM/100_FUJI/DSCF0002.RAF"
	head -c 65536 /dev/urandom > "$WORK/sd/DCIM/100_FUJI/DSCF0002.JPG"
	cat > "$WORK/hook.sh" <<'EOF'
#!/bin/sh
cp "$1" "$FUJI_STATE_DIR/hook-saw.list"
echo "$FUJI_CAMERA_MODEL" > "$FUJI_STATE_DIR/hook-saw.model"
echo "$1" > "$FUJI_STATE_DIR/hook-saw.arg"
# A long-running hook must not hold the receiver's sockets
ls -l /proc/$$/fd > "$FUJI_STATE_DIR/hook-saw.fds"
EOF
	chmod +x "$WORK/hook.sh"

	# Already in a throwaway network namespace (e.g. a container with NET_ADMIN)
	[ "${E2E_NO_UNSHARE:-0}" = 1 ] && exec "$0" --in-netns
	exec unshare -rn "$0" --in-netns
fi

ip link set lo up
if ! ip link show d0 >/dev/null 2>&1; then
	ip link add d0 type dummy
	ip addr add 192.168.1.10/24 dev d0
	ip link set d0 up
	ip route add default dev d0
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

# One AutoSave session: receiver waits, vcam pushes, receiver exits (--once)
session() {
	"$RECV" -i "$WORK/inbox" -s "$WORK/state" -x "$WORK/hook.sh" --once -v > "$WORK/recv-$1.log" 2>&1 &
	rp=$!
	sleep 1
	( cd "$ROOT/build/vcam" && exec build/vcam fuji_x_t4 tcp --discovery --fs "$WORK/sd" ) > "$WORK/vcam-$1.log" 2>&1 &
	vp=$!
	i=0
	while kill -0 $rp 2>/dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
	kill $rp 2>/dev/null && fail "receiver did not finish session $1"
	wait $rp || fail "receiver exited non-zero in session $1 (see $WORK/recv-$1.log)"
	kill $vp 2>/dev/null || true
	wait $vp 2>/dev/null || true
	sleep 1 # let the hook finish
}

# A batch list a crashed receiver left unfinished is queued at startup
mkdir -p "$WORK/state/batches"
echo /nonexistent > "$WORK/state/batches/crashed.list.part"
session 1
[ -f "$WORK/state/batches/crashed.list" ] || fail "unfinished batch list not recovered"
rm -f "$WORK/state/batches/crashed.list"
# vcam counts its DCIM folders as objects but reports one fewer than it has,
# so the last file in its tree is never offered; expect the first two files.
year=$(ls "$WORK/inbox" | grep -E '^[0-9]{4}$')
[ -n "$year" ] || fail "no year folder in inbox"
day=$year/$(ls "$WORK/inbox/$year" | grep -E "^$year-[0-9]{2}-[0-9]{2}\$")
[ -d "$WORK/inbox/$day" ] || fail "no YYYY/YYYY-MM-DD folder in inbox"
for f in DSCF0001.RAF DSCF0002.RAF; do
	cmp -s "$WORK/sd/DCIM/100_FUJI/$f" "$WORK/inbox/$day/$f" || fail "$f missing or corrupt"
done
[ "$(wc -l < "$WORK/state/hook-saw.list")" -eq 2 ] || fail "hook did not get both files"
[ "$(cat "$WORK/state/hook-saw.model")" = X-T4 ] || fail "hook did not get the camera model"
grep -q 'session done: 2 new, 0 already seen' "$WORK/recv-1.log" || fail "unexpected first session summary"
[ -z "$(ls -A "$WORK/inbox/.incoming")" ] || fail "partial files left behind"
case $(cat "$WORK/state/hook-saw.arg") in *.list) ;; *) fail "hook got $(cat "$WORK/state/hook-saw.arg"), not a .list";; esac
[ -z "$(ls "$WORK/state/batches" | grep '\.part$')" ] || fail "batch list left as .part"
! grep -q 'socket:' "$WORK/state/hook-saw.fds" || fail "hook inherited sockets: $(grep socket: "$WORK/state/hook-saw.fds")"
# mtime is the capture instant the camera reported, in UTC like the real
# X-T30 II (seen.tsv keeps it)
for f in DSCF0001.RAF DSCF0002.RAF; do
	want=$(grep "^$f|" "$WORK/state/seen.tsv" | cut -d'|' -f2)
	got=$(date -u -r "$WORK/inbox/$day/$f" +%Y%m%dT%H%M%S)
	[ "$got" = "$want" ] || fail "$f mtime $got, capture time $want"
done

rm -f "$WORK/state/hook-saw.list"
session 2
grep -q 'session done: 0 new, 2 already seen' "$WORK/recv-2.log" || fail "second session re-downloaded files"
[ ! -e "$WORK/state/hook-saw.list" ] || fail "hook ran for an empty batch"

# Lost seen list: files already in the inbox are recognised, not downloaded again
rm -f "$WORK/state/seen.tsv"
session 3
grep -q 'session done: 0 new, 0 already seen, 2 already in the inbox' "$WORK/recv-3.log" || fail "lost seen list caused re-downloads"
[ "$(ls "$WORK/inbox/$day" | wc -l)" -eq 2 ] || fail "duplicate files after lost seen list"
[ ! -e "$WORK/state/hook-saw.list" ] || fail "hook ran for files already in the inbox"

echo "e2e: all checks passed"
