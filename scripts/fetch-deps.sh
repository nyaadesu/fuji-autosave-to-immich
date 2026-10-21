#!/bin/sh
# Fetch libfuji and its libpict submodule, then apply our patches to libfuji.
# libfuji's .gitmodules points at an SSH URL, so rewrite GitHub SSH URLs to
# HTTPS for machines without a key. Safe to run again: applied patches are skipped.
set -eu
cd "$(dirname "$0")/.."
git -c url."https://github.com/".insteadOf="git@github.com:" \
	submodule update --init --recursive

for p in patches/libfuji-*.patch; do
	[ -e "$p" ] || continue
	if git -C third_party/libfuji apply --check "../../$p" 2>/dev/null; then
		git -C third_party/libfuji apply "../../$p"
		echo "applied $p"
	elif git -C third_party/libfuji apply --reverse --check "../../$p" 2>/dev/null; then
		echo "already applied $p"
	else
		echo "error: $p does not apply to third_party/libfuji" >&2
		exit 1
	fi
done
