#!/bin/sh
# PC AutoSave registration against a scripted fake camera that sends its model
# quoted and with a space, like a real X-T30 II (DSCMODEL:"X-T30 II").
# Runs in a private user+network namespace; needs unshare, ip and python3.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECV=$ROOT/build/fuji-autosave-receiver
WORK=$ROOT/build/register-test

if [ "${1:-}" != --in-netns ]; then
	[ -x "$RECV" ] || { echo "build the receiver first (cmake --build build)" >&2; exit 1; }
	rm -rf "$WORK"
	mkdir -p "$WORK"
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
# then REGISTER at the client's invite server.
import socket, sys, time
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
print("notify:", conn.recv(1024).decode().splitlines()[0])
conn.sendall(b"HTTP/1.1 200 OK\r\n")
conn.close()
time.sleep(0.5)
inv = socket.create_connection((client_ip, 51542), timeout=5)
inv.sendall(('REGISTER * HTTP/1.1\r\nHOST:%s:51542\r\n'
             'DSCNAME:FUJIFILM-TEST-1234\r\nDSCMODEL:"X-T30 II"\r\n' % client_ip).encode())
reply = inv.recv(1024).decode()
print("reply:", reply.replace("\r\n", " | "))
sys.exit(0 if "FOLDER: guest" in reply else 1)
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }

"$RECV" -i "$WORK/inbox" -s "$WORK/state" > "$WORK/recv.log" 2>&1 &
rp=$!
sleep 1
python3 -I "$WORK/camera.py" > "$WORK/camera.log" 2>&1 || { cat "$WORK/camera.log" >&2; fail "fake camera failed"; }
i=0
while ! grep -q 'registered with' "$WORK/recv.log" && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
kill $rp 2>/dev/null || true
wait $rp 2>/dev/null || true

grep -q 'registered with FUJIFILM-TEST-1234 (X-T30 II)' "$WORK/recv.log" \
	|| { cat "$WORK/recv.log" >&2; fail "model not parsed as 'X-T30 II'"; }
echo "register: all checks passed"
