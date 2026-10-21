#!/bin/sh
# Build and run all tests in an Alpine minirootfs (musl, busybox), the target
# userland for the LXC deployment. Rootless: uses unshare user namespaces + chroot,
# so it needs no Docker and no root.
#
#   tests/alpine-rootless.sh [rootfs-dir]   (default build/alpine-root)
#
# Phase 1 (host network): apk deps, build receiver and vcam.
# Phase 2 (private network namespace): hook test with busybox tools, e2e test.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RFS=${1:-$ROOT/build/alpine-root}
MIRROR=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64

if [ "${1:-}" = --inside ]; then
	# Runs as (namespaced) root inside the new mount/pid namespaces
	RFS=$2 PHASE=$3
	mount --rbind /dev "$RFS/dev"
	if [ "$PHASE" = 1 ]; then
		cp /etc/resolv.conf "$RFS/etc/resolv.conf"
		exec chroot "$RFS" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/sh -euc '
			apk add -q build-base cmake samurai pkgconf libusb-dev git libexif-dev linux-headers iproute2 python3
			echo "alpine $(cat /etc/alpine-release)"
			cd /work && rm -rf build
			cmake -G Ninja -B build >/dev/null
			cmake --build build 2>&1 | grep -E "warning|error" | grep -v third_party || true
			ldd build/fuji-autosave-receiver
			tests/e2e-vcam.sh --prepare
		'
	fi
	exec chroot "$RFS" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/sh -euc '
		cd /work
		sh -n packaging/fuji-autosave.initd
		echo "flock is $(readlink -f "$(command -v flock)")"
		tests/test-hook.sh
		E2E_NO_UNSHARE=1 tests/test-register.sh
		E2E_NO_UNSHARE=1 tests/e2e-vcam.sh
	'
fi

if [ ! -x "$RFS/bin/busybox" ]; then
	mkdir -p "$RFS"
	file=$(curl -fsSL "$MIRROR/latest-releases.yaml" | awk '/flavor: alpine-minirootfs/{f=1} f&&/file:/{print $2; exit}')
	sum=$(curl -fsSL "$MIRROR/latest-releases.yaml" | awk '/flavor: alpine-minirootfs/{f=1} f&&/sha256:/{print $2; exit}')
	curl -fsSL -o "$RFS.tar.gz" "$MIRROR/$file"
	echo "$sum  $RFS.tar.gz" | sha256sum -c -
	tar xzf "$RFS.tar.gz" -C "$RFS"
	rm -f "$RFS.tar.gz"
fi

# Fresh copy of the source tree (without build output) at /work
rm -rf "$RFS/work"
mkdir -p "$RFS/work"
tar -C "$ROOT" --exclude=./build --exclude=./.git -cf - . | tar -C "$RFS/work" -xf -

unshare -rmpf --mount-proc="$RFS/proc" "$0" --inside "$RFS" 1
unshare -rmpfn --mount-proc="$RFS/proc" "$0" --inside "$RFS" 2
echo "alpine: all checks passed"
