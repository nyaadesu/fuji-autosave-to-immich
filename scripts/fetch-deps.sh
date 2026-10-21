#!/bin/sh
# Fetch libfuji and its libpict submodule. libfuji's .gitmodules points at an
# SSH URL, so rewrite GitHub SSH URLs to HTTPS for machines without a key.
set -eu
cd "$(dirname "$0")/.."
git -c url."https://github.com/".insteadOf="git@github.com:" \
	submodule update --init --recursive
