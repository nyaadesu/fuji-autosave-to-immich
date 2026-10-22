#!/bin/sh
# Fetch libfuji and libpict (forks with fixes pending upstream; see README).
# libfuji's own libpict submodule is not needed: CMake builds third_party/libpict.
set -eu
cd "$(dirname "$0")/.."
git submodule update --init third_party/libfuji third_party/libpict
