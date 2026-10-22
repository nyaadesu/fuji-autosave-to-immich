# Deploying in an Alpine LXC

The setup: an unprivileged **Alpine** LXC bridged onto the LAN runs the
receiver as an OpenRC service. The ZFS dataset `data2/fuji` is bind-mounted
into it, and the receiver writes the camera's files straight into it. Immich
reads the same dataset read-only as an
[external library](https://docs.immich.app/features/libraries), and the hook
scans, tags, stacks and files them into the RAW album. Nothing is uploaded or
copied twice. The full build and test suite passes on Alpine 3.24 (musl,
busybox) via `tests/alpine-rootless.sh`.

The host commands below **assume a Proxmox VE host** (`pct`, ZFS). On plain
LXC/Incus the steps are the same, but the commands differ. Replace CT ID `140`
and bridge `vmbr0` with yours. See [immich-import-plan.md](immich-import-plan.md)
for the design.

```
host /data2/fuji ──bind──> receiver LXC /fuji         (read-write, --inbox)
                 ──bind──> immich-server  /mnt/fuji    (read-only, library import path)
                 ──SMB───> darktable / Lightroom       (edit in place, .RAF.xmp sidecars)
```

## 1. Network: the container must be on the camera's LAN

The camera finds the receiver by UDP broadcast. Give the container a NIC on the
same bridge as the LAN (`vmbr0`). Don't put it behind a NAT bridge, because
broadcasts don't cross NAT.

## 2. Dataset and container (on the host)

```sh
zfs create -o recordsize=1M -o compression=lz4 data2/fuji     # mounts at /data2/fuji

pveam update && pveam available | grep alpine     # download the current one with pveam
# The template file name below is an example; use the one pveam downloaded
pct create 140 local:vztmpl/alpine-3.24-default_20260601_amd64.tar.xz \
    --hostname fuji-autosave --unprivileged 1 --cores 1 --memory 512 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --rootfs local-zfs:4 --onboot 1
pct set 140 -mp0 /data2/fuji,mp=/fuji    # the container only ever sees /fuji
pct start 140

# Reserve Fuji's ports from the ephemeral range (see packaging/90-fuji-autosave.conf).
# This is a per-network-namespace sysctl; set it here if the container can't.
pct exec 140 -- sysctl -w net.ipv4.ip_local_reserved_ports=51540-51562,55740-55742
```

Ownership: the container's `fuji` user (created below) maps to host UID
`100000 + <its uid>`. Give that UID the dataset, for example
`chown 100100:100101 /data2/fuji` if `id fuji` prints `uid=100 gid=101`.
For editing over SMB, the SMB user must be able to create `.RAF.xmp` files in
the day folders. Either make the SMB share write as that UID (`force user`), or
give the dataset a shared group: set the setgid bit
(`chmod 2775 /data2/fuji`) and `FUJI_UMASK=002` in `/etc/conf.d/fuji-autosave`,
so new folders and files are group-writable.

Use a DHCP reservation so the container keeps a stable address. It isn't
required, but it makes debugging easier.

## 3. Immich (one time)

The hook needs **Immich 3.2 or newer** (structured search API). `immich-hook
--check` prints the server version and refuses older ones.

Mount the dataset into `immich-server` **read-only**. darktable owns the
`.RAF.xmp` sidecars, and Immich must not write to them:

```yaml
immich-server:
  volumes:
    - /data2/fuji:/mnt/fuji:ro
```

If Immich itself runs in an LXC, bind-mount `/data2/fuji` into that container
first (`pct set <id> -mpX /data2/fuji,mp=/data2/fuji`), then use the line above
inside it. The dataset must not be inside Immich's upload location
(`/data2/immich`), because Immich rejects such import paths.

Then, in the Immich web UI:

1. Administration → External Libraries → Create library, **owned by your own
   user**, import path `/mnt/fuji` (the container path). Add the exclusion
   pattern `**/.incoming/**`, where the receiver keeps partial downloads.
   You can turn off the periodic scan, because the hook triggers one after
   every batch. Note the library ID (it is in the page URL, or list them with
   `curl -H "x-api-key: $KEY" http://immich.lan:2283/api/libraries`).
2. Account Settings → API Keys → New API key, as that same user, with these
   permissions: `library.read`, `library.update`, `asset.read`, `asset.update`,
   `tag.read`, `tag.create`, `tag.asset`, `stack.read`, `stack.create`, `album.read`,
   `album.create`, `albumAsset.create`. (Checked against Immich v3.3.5;
   `asset.update` is also needed to stack.)
3. Account Settings → Features: enable Tags if it is off.

## 4. Inside the container (Alpine)

```sh
apk add build-base cmake samurai pkgconf libusb-dev git python3

addgroup -S fuji && adduser -S -D -H -h /var/lib/fuji-autosave -s /sbin/nologin -G fuji fuji

git clone https://github.com/nyaadesu/fuji-autosave-to-immich /opt/fuji-autosave-to-immich && cd /opt/fuji-autosave-to-immich
scripts/fetch-deps.sh
cmake -G Ninja -B build && cmake --build build
cmake --install build --prefix /usr/local

install -Dm644 packaging/90-fuji-autosave.conf /etc/sysctl.d/90-fuji-autosave.conf
rc-update add sysctl boot

install -Dm640 -g fuji packaging/fuji-autosave.env.example /etc/fuji-autosave/env
vi /etc/fuji-autosave/env                    # Immich URL, API key, library ID, paths
install -Dm755 packaging/fuji-autosave.initd /etc/init.d/fuji-autosave
install -Dm644 packaging/fuji-autosave.confd /etc/conf.d/fuji-autosave
vi /etc/conf.d/fuji-autosave                 # client name, umask (defaults are fine)

# Test the settings and the API key before the first batch
doas -u fuji /usr/local/lib/fuji-autosave/immich-hook --check

rc-update add fuji-autosave default && rc-service fuji-autosave start
tail -f /var/log/messages                    # logs go to syslog, tag fuji-autosave
```

The build tools are only needed to compile. Afterwards you can remove them
with `apk del build-base cmake samurai git`, but keep `libusb` and `python3`.

`supervise-daemon` restarts the receiver if it exits. On stop, a running hook
gets 300 s to finish.

## 5. Pair the camera

1. On the camera, open the network menu → PC AUTO SAVE SETTING and register a
   destination. The log shows `registered with FUJIFILM-...`.
2. Start PC AUTO SAVE (Playback menu). The log shows `AutoSave request`, one
   `saved ...` line per file, `session done`, and then the hook: `scan
   started`, and a `done:` summary with the number of files tagged, pairs
   stacked and RAFs added to the album.
3. If Immich was down or the scan took longer than `SCAN_TIMEOUT`, the batch
   stays queued and the next batch retries it. To retry by hand (the hook reads
   `/etc/fuji-autosave/env` itself):

   ```sh
   doas -u fuji /usr/local/lib/fuji-autosave/immich-hook
   ```

## 6. First batch: check how stacks look

Before relying on stacks, import one RAW+JPEG pair and check two things in
Immich: the timeline shows only the JPEG, and the `Fuji RAW` album shows the
RAF. If the album doesn't show the stacked RAF properly, set `RAW_MODE=archive`
in `/etc/fuji-autosave/env`. Paired RAFs are then archived instead of stacked:
they are hidden from the timeline but still appear in the album and in search.
Unstack the test pair by hand and rerun the hook.

## Things to know

- **Immich's "Sidecar" job fails for every tagged asset. That is expected.**
  Each tag added through the API makes Immich (v3.3.5) try to write the tags
  into `<file>.xmp`, which for a RAF is darktable's `DSCF1234.RAF.xmp`. The
  read-only mount stops it, and that is what keeps darktable's sidecars safe.
  **Never mount the library read-write into Immich.**
- **darktable/Lightroom keywords don't show up as Immich tags.** A tag added
  through the API locks the asset's tag list in Immich, so keywords that
  darktable writes into the sidecar later are ignored. Ratings and descriptions
  are not affected by this.
- **Lightroom Classic** names RAW sidecars `DSCF1234.xmp`. Immich also treats that
  file as the sidecar of `DSCF1234.JPG`, so Lightroom's rating and keywords show up on the
  JPEG. darktable's `DSCF1234.RAF.xmp` only applies to the RAF.
- **File times.** The receiver sets each file's mtime to the capture time the
  camera reports. The camera has no time zone setting for this, so the mtime is
  interpreted in the container's time zone (Alpine LXC: UTC unless
  `/etc/localtime` is set). Immich takes dates from EXIF, so this only affects
  `ls`. The hook pairs a JPEG and RAF only if their mtimes are within 2 s, so
  if you copy files into the library by hand, keep their times (`cp -p`,
  `rsync -t`).
