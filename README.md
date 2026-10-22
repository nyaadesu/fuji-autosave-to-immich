# fuji-autosave-to-immich

Wireless RAW from a Fujifilm camera into Immich. The daemon,
`fuji-autosave-receiver`, is a headless FUJIFILM **PC AutoSave** target for
Linux, built on [libfuji](https://github.com/petabyt/libfuji). The camera joins your Wi-Fi,
finds this daemon instead of Fuji's Windows/macOS app, and pushes its new
pictures. Each file lands in `<inbox>/YYYY/YYYY-MM-DD/` under its camera
name. The inbox is an Immich external library, and after each batch a hook
has Immich scan it, tags the new files, stacks each RAF under its JPEG and
collects the RAFs in an album. The RAFs stay plain files that darktable or
Lightroom can edit in place over SMB. You don't need a PC, a phone or a cable.
The design is in [docs/immich-import-plan.md](docs/immich-import-plan.md).

It was written for an X-T30 II feeding a home-server Immich, but nothing here is
specific to that body.

## Status

| What | State |
| --- | --- |
| Discovery, register and connect handshakes | Tested against [vcam](https://github.com/petabyt/vcam) (emulated X-T4) |
| PTP/IP session, RAF/JPG download, skip repeats, hook | Tested against vcam (`tests/e2e-vcam.sh`) |
| Immich external-library hook | Tested against a fake Immich API modelled on v3.3.5 (`tests/test-hook.sh`); not yet run against a real Immich |
| Alpine 3.24 (musl, busybox) | All of the above pass (`tests/alpine-rootless.sh`) |
| A real X-T30 II (firmware 2.06) | Works: registered, then a 38-file RAW+JPEG batch (991 MB) arrived intact at ~1.9 MB/s |

On the X-T30 II, the camera offers the images it considers not yet AutoSaved,
and the transfer leaves the originals on the card. The camera does not mark
images as saved after a transfer to this receiver (Fuji's own software likely
does this via property 0xD228, whose format is unknown), so the same images are
offered again each time; `seen.tsv` skips them without downloading. Starting a transfer is a manual
step (Playback menu → PC AUTO SAVE); the camera's automatic power-off transfer
only goes to the smartphone app.

## How it works

1. The daemon listens on UDP 51541/51542 for the camera's `DISCOVER` broadcast.
2. **Register** (once, from the camera's PC AUTO SAVE SETTING menu): the daemon
   answers, and the camera stores it as a PC. The log line reads
   `registered with ...`.
3. **Connect** (each time PC AutoSave runs): the daemon answers the invite, then
   opens a PTP/IP session to the camera on TCP 55740.
4. The camera offers objects 1..N. For each one the daemon reads its object
   info and skips it if `filename|date|size` is already in `seen.tsv`, or if
   a file of that name and size is already at its destination.
   Otherwise it downloads to `.incoming/NAME.part`, fsyncs, and renames into
   `YYYY/YYYY-MM-DD/` (the date the camera recorded the shot). Files are never
   moved or changed after that, since Immich would treat a moved file as a new asset.
5. After the session it starts the hook with a list of the new files.
   `scripts/immich-hook` asks Immich to scan the library and waits until every
   new file has an asset. It then tags all assets with `CAMERA_TAG`, stacks each
   `DSCFnnnn.JPG` + `DSCFnnnn.RAF` pair (JPEG on top; or archives the RAF with
   `RAW_MODE=archive`) and adds every RAF to the `RAW_ALBUM_NAME` album. Steps
   that already happened are skipped, and the hook works over the whole library, so a
   batch that timed out or hit an Immich outage stays queued and is caught up
   by the next run.

If a download fails partway through, the daemon drops the session. A half-read
object leaves Fuji cameras unresponsive (see libfuji `lib/jank.c`). Files that
already finished are kept, and the next AutoSave picks up the rest.

## Build

```sh
git clone https://github.com/nyaadesu/fuji-autosave-to-immich && cd fuji-autosave-to-immich
scripts/fetch-deps.sh               # libfuji + libpict submodules (see Caveats)
cmake -G Ninja -B build && cmake --build build
sudo cmake --install build --prefix /usr/local
```

Dependencies: a C compiler, CMake ≥ 3.15, and libusb-1.0 headers (libpict
links them even though only Wi-Fi is used). On Alpine that's
`apk add build-base cmake samurai pkgconf libusb-dev git`. It builds on glibc
and musl alike.

## Run

```sh
fuji-autosave-receiver --inbox /data2/fuji --state-dir /var/lib/fuji-autosave \
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
one per line. `immich-hook` needs Python 3 (standard library only). Its own
settings are listed at the top of the script and in
`packaging/fuji-autosave.env.example`. `immich-hook --check` tests them and the
API key without changing anything.

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
tests/test-hook.sh        # immich-hook against a fake Immich API (tests/fake-immich.py)
tests/test-register.sh    # registration against a scripted camera (quoted model name)
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
- **Dependencies are forks with fixes.** libfuji and libpict have no tagged
  releases, and several bugs this project hit are fixed but not yet merged
  upstream. The submodules therefore track forks:

  | Submodule | Fork branch | Upstream PRs |
  | --- | --- | --- |
  | `third_party/libfuji` | [nyaadesu/libfuji `discovery-and-reset-fixes`](https://github.com/nyaadesu/libfuji/tree/discovery-and-reset-fixes) | [#8](https://github.com/petabyt/libfuji/pull/8) (quoted model names), [#9](https://github.com/petabyt/libfuji/pull/9) (reset leak, socket leaks, `strncpy`) |
  | `third_party/libpict` | [nyaadesu/libpict `fix-close-leaks-avail-no-usb`](https://github.com/nyaadesu/libpict/tree/fix-close-leaks-avail-no-usb) | [#21](https://github.com/petabyt/libpict/pull/21) (heap overflow, `ptp_close` leaks, `PTP_NO_USB`) |

  The libfuji branch also has fixes not yet sent upstream: two out-of-bounds
  writes in discovery, line-based parsing of the tether and DISCOVER headers,
  and an HTTPS URL for its own libpict submodule. CMake builds
  `third_party/libpict` and libfuji uses it instead of its bundled copy. Once
  everything is merged, point both submodules back at petabyt's repos.
  `src/main.c`'s `free_runtime()` relies on the fixed `ptp_close()` freeing
  libpict's state; with an unfixed libpict it leaks about 100 bytes per session.

## Ideas

### Tell the camera which images are done

The camera keeps re-offering every image it thinks hasn't been AutoSaved
(see Status), because this receiver never tells it a transfer finished. Fuji's
own PC AutoSave app presumably does. Capturing that "done" signal and sending
it ourselves would make each session list only new images.

How to find it:

1. Run Fuji's official PC AutoSave on a Windows PC and register the camera there.
2. Capture one transfer of 2–3 images with Wireshark on that PC (or on a mirror
   port). libfuji ships a dissector for Fuji's PTP/IP in
   `third_party/libfuji/docs/wireshark_dissector.lua`.
3. Look for `SetDevicePropValue` calls during and after the downloads. The
   prime suspect is `0xD228`, which libfuji names `AutoSaveDatabaseStatus`
   (`lib/fujiptp.h`, with a partial `struct FujiD228`; `_fuji_d228()` in
   `lib/jank.c` holds a guessed payload). Also watch `AutoSaveVersion`
   (`0xDF23`). Note whether they are sent per image or once at the end.
4. Run AutoSave again with the official app and check that the camera now
   offers 0 images. That confirms the signal is the right one.

Then send the same property from `run_session()` in `src/main.c`, after each
file is safely renamed into the inbox (or once at the end, matching what the
official app does). The `seen.tsv` skip should stay either way, as a safety net.
