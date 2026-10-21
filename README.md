# fuji-autosave-receiver

A headless FUJIFILM **PC AutoSave** target for Linux, built on
[libfuji](https://github.com/petabyt/libfuji). The camera joins your Wi-Fi,
finds this daemon instead of Fuji's Windows/macOS app, and pushes its new
pictures. Each file lands in `<inbox>/YYYY-MM-DD/`, and a hook uploads the
batch to Immich. You don't need a PC, a phone or a cable.

It was written for an X-T30 II feeding a home-server Immich, but nothing here is
specific to that body.

## Status

| What | State |
| --- | --- |
| Discovery, register and connect handshakes | Tested against [vcam](https://github.com/petabyt/vcam) (emulated X-T4) |
| PTP/IP session, RAF/JPG download, skip repeats, hook | Tested against vcam (`tests/e2e-vcam.sh`) |
| Immich upload hook | Tested with a stub CLI (`tests/test-hook.sh`) |
| Alpine 3.24 (musl, busybox) | All of the above pass (`tests/alpine-rootless.sh`) |
| A real X-T30 II | **Not tested yet.** Do Phase 0 below first. |

## How it works

1. The daemon listens on UDP 51541/51542 for the camera's `DISCOVER` broadcast.
2. **Register** (once, from the camera's PC AUTO SAVE SETTING menu): the daemon
   answers, and the camera stores it as a PC. The log line reads
   `registered with ...`.
3. **Connect** (each time PC AutoSave runs): the daemon answers the invite, then
   opens a PTP/IP session to the camera on TCP 55740.
4. The camera offers objects 1..N. For each one the daemon reads its object
   info and skips it if `filename|date|size` is already in `seen.tsv`.
   Otherwise it downloads to `.incoming/NAME.part`, fsyncs, and renames into
   `YYYY-MM-DD/` (the date the camera recorded the shot).
5. After the session it starts the hook with a list of the new files.
   `scripts/immich-hook` runs `immich upload` and moves the uploaded files to
   an archive folder. A failed upload stays queued and retries with the next
   batch.

If a download fails partway through, the daemon drops the session. A half-read
object leaves Fuji cameras unresponsive (see libfuji `lib/jank.c`). Files that
already finished are kept, and the next AutoSave picks up the rest.

## Build

```sh
git clone <this repo> && cd fuji-autosave-receiver
scripts/fetch-deps.sh               # libfuji + libpict (rewrites their SSH URL to HTTPS)
cmake -G Ninja -B build && cmake --build build
sudo cmake --install build --prefix /usr/local
```

Dependencies: a C compiler, CMake ≥ 3.15, and libusb-1.0 headers (libpict
links them even though only Wi-Fi is used). On Alpine that's
`apk add build-base cmake samurai pkgconf libusb-dev git`. It builds on glibc
and musl alike.

## Run

```sh
fuji-autosave-receiver --inbox /srv/fuji-inbox --state-dir /var/lib/fuji-autosave \
    --name fuji-inbox --hook /usr/local/lib/fuji-autosave/immich-hook
```

| Option | Meaning |
| --- | --- |
| `-i, --inbox DIR` | where files land (default `/srv/fuji-inbox`) |
| `-s, --state-dir DIR` | `seen.tsv` and pending batch lists (default `/var/lib/fuji-autosave`) |
| `-n, --name NAME` | name the camera shows for this "PC", 1–24 chars |
| `-x, --hook PATH` | run `PATH <batch-list>` after each batch with new files |
| `-l, --list-only` | log every object the camera offers (name, format, size), download nothing |
| `-1, --once` | exit after the first AutoSave session |
| `-v, --verbose` | protocol-level logging |

The hook gets these variables: `FUJI_BATCH_LIST`, `FUJI_BATCH_COUNT`,
`FUJI_INBOX`, `FUJI_STATE_DIR`, `FUJI_CAMERA_NAME` and `FUJI_CAMERA_MODEL`
(the model is only known when registering). Batch lists hold absolute paths,
one per line. `immich-hook`'s own settings are listed at the top of the script
and in `packaging/fuji-autosave.env.example`.

For the OpenRC service in an Alpine LXC, see [docs/deploy-lxc.md](docs/deploy-lxc.md).

## Phase 0: does the X-T30 II send RAF?

`--list-only` answers this without the Windows PC. Run it on any Linux machine
on the same LAN as the camera, with the RAW+JPEG test frames on the card:

```sh
build/fuji-autosave-receiver -i /tmp/fuji-test -s /tmp/fuji-test-state -v   # 1. register
# Camera: PC AUTO SAVE SETTING → register; the log prints "registered with ..."
build/fuji-autosave-receiver -i /tmp/fuji-test -s /tmp/fuji-test-state --list-only --once -v
# Camera: start PC AUTO SAVE
```

Every offered object is logged with its PTP format:
`format=0xb103` is RAF and `0x3801` is JPEG. If RAF objects show up, the
X-T30 II sends RAW over AutoSave and the whole plan holds. Drop `--list-only` to
download for real. Save the `-v` log either way, since it shows how the camera
identifies the PC. If only JPEGs show up, the fallback would be a libfuji pull
client in "wireless communication" mode (not implemented here).

## Tests

```sh
tests/test-hook.sh        # immich-hook with a stub Immich CLI
tests/e2e-vcam.sh         # receiver vs. emulated camera, in a private network namespace
tests/alpine-rootless.sh  # all of the above, built and run on Alpine (musl, busybox)
```

`e2e-vcam.sh` builds a pinned vcam into `build/vcam` (it needs libexif
headers too). It runs under `unshare -rn`, so it needs no root and leaves the
host network alone. `alpine-rootless.sh` downloads the latest Alpine
minirootfs (checksum-verified) into `build/alpine-root` and runs everything in
a rootless chroot, so it needs no Docker.

## Caveats

- **Only one PC AutoSave target should be running.** libfuji answers every
  AutoSave broadcast, so if Fuji's own PC AutoSave app is also running on the
  LAN, the two race for the camera.
- **Port collisions.** Fuji's ports (51540–51562, 55740) fall inside Linux's
  ephemeral port range. Install `packaging/90-fuji-autosave.conf` to reserve
  them. Without it, an unrelated outgoing connection can occasionally hold one,
  and discovery then logs `Binding failed 98` and retries every 5 s.
- **Same broadcast domain.** The camera finds the receiver by UDP broadcast, so
  they must share a LAN segment with no NAT in between.
- libfuji has no tagged release. This repo pins commit `abe5531` as a
  submodule.
