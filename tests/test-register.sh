#!/bin/sh
# PC AutoSave registration against a scripted fake camera, over a table of
# REGISTER header variants: a real X-T30 II sends its model quoted and with a
# space (DSCMODEL:"X-T30 II"), and the parser must not regress on the plainer
# forms. Runs in a private user+network namespace; needs unshare, ip, python3.
#
#   RECV=path/to/receiver tests/test-register.sh   (default build/fuji-autosave-receiver)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECV=${RECV:-$ROOT/build/fuji-autosave-receiver}
WORK=$ROOT/build/register-test

if [ "${1:-}" != --in-netns ]; then
	[ -x "$RECV" ] || { echo "build the receiver first (cmake --build build)" >&2; exit 1; }
	rm -rf "$WORK"
	mkdir -p "$WORK"
	export RECV
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

cat > "$WORK/camera.py" <<'EOF'
# Camera side of PC AUTO SAVE SETTING: broadcast DISCOVER, accept NOTIFY,
# then REGISTER at the client's invite server with the given header lines.
#   camera.py <eol: crlf|lf> <header line>...
import socket, sys, time
eol = "\r\n" if sys.argv[1] == "crlf" else "\n"
headers = sys.argv[2:]
me = "192.168.1.10"
notify = socket.socket()
notify.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
notify.bind(("0.0.0.0", 51540))
notify.listen(1)
notify.settimeout(2)
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
hello = ("DISCOVER * HTTP/1.1\r\nMX:3\r\nHOST:192.168.1.255:|\r\n"
         "DSCADDR:%s\r\nSERVICE:PCAUTOSAVE/1.0\r\n" % me).encode()
for _ in range(10):
    udp.sendto(hello, ("192.168.1.255", 51542))
    try:
        conn, (client_ip, _) = notify.accept()
        break
    except socket.timeout:
        pass
else:
    sys.exit("no client answered DISCOVER")
conn.recv(1024)
conn.sendall(b"HTTP/1.1 200 OK\r\n")
conn.close()
time.sleep(0.5)
inv = socket.create_connection((client_ip, 51542), timeout=5)
msg = eol.join(["REGISTER * HTTP/1.1", "HOST:%s:51542" % client_ip] + headers) + eol
inv.sendall(msg.encode())
reply = inv.recv(1024).decode()
sys.exit(0 if "FOLDER: guest" in reply else 1)
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }

# check <case name> <expected log text> <eol> <header line>...
check() {
	name=$1 expect=$2
	shift 2
	log=$WORK/recv-$(echo "$name" | tr ' ' _).log
	"$RECV" -i "$WORK/inbox" -s "$WORK/state" > "$log" 2>&1 &
	rp=$!
	sleep 1
	python3 -I "$WORK/camera.py" "$@" > "$WORK/camera.log" 2>&1 \
		|| { cat "$WORK/camera.log" >&2; kill $rp; fail "$name: fake camera failed"; }
	i=0
	while ! grep -q 'registered with' "$log" && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
	kill $rp 2>/dev/null || true
	wait $rp 2>/dev/null || true
	if ! grep -qF "registered with $expect;" "$log"; then
		got=$(grep -o 'registered with [^;]*' "$log" || echo "no registration")
		# COMPARE=1: report differences instead of stopping (to diff parser versions)
		[ "${COMPARE:-0}" = 1 ] && { echo "differs: $name: got '$got'"; return 0; }
		fail "$name: expected 'registered with $expect', got '$got'"
	fi
	# Sanitizer builds report memory errors on stderr
	! grep -qE 'ERROR: [A-Za-z]*Sanitizer|runtime error:' "$log" || { cat "$log" >&2; fail "$name: sanitizer error"; }
	echo "ok: $name"
}

N='DSCNAME:FUJIFILM-TEST-1234'
check "quoted with space"   'FUJIFILM-TEST-1234 (X-T30 II)' crlf "$N" 'DSCMODEL:"X-T30 II"'
check "unquoted"            'FUJIFILM-TEST-1234 (X-H1)'     crlf "$N" 'DSCMODEL:X-H1'
check "space after colon"   'FUJIFILM-TEST-1234 (X-T30 II)' crlf "$N" 'DSCMODEL: "X-T30 II"'
check "LF line endings"     'FUJIFILM-TEST-1234 (X-T30 II)' lf   "$N" 'DSCMODEL:"X-T30 II"'
check "spaces around key"   'FUJIFILM-TEST-1234 (X-S10)'    crlf 'DSCNAME : FUJIFILM-TEST-1234' 'DSCMODEL : X-S10'
check "leading space"       'FUJIFILM-TEST-1234 (X-E4)'     crlf "$N" ' DSCMODEL:X-E4'
check "trailing spaces"     'FUJIFILM-TEST-1234 (X-T5)'     crlf "$N" 'DSCMODEL:X-T5  '
check "reordered + extra"   'FUJIFILM-TEST-1234 (X-H2S)'    crlf 'X-EXTRA:a:b' 'DSCMODEL:X-H2S' "$N"
check "colon in value"      'FUJI:1 (X-T4)'                 crlf 'DSCNAME:FUJI:1' 'DSCMODEL:X-T4'
check "empty model"         'FUJIFILM-TEST-1234 ()'         crlf "$N" 'DSCMODEL:'
check "no model header"     'FUJIFILM-TEST-1234 ()'         crlf "$N"

echo "register: all checks passed"
