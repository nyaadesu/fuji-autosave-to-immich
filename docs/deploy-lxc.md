# Deploying in an Alpine LXC

The setup: an unprivileged **Alpine** LXC bridged
onto the LAN, an inbox on a ZFS dataset, and the Immich CLI upload hook, run
as an OpenRC service. The full build and test suite passes on Alpine 3.24
(musl, busybox) via `tests/alpine-rootless.sh`.

The host commands below **assume a Proxmox VE host** (`pct`, ZFS-backed
storage). On plain LXC/Incus the steps are the same, but the commands differ.
Replace the names `tank/fuji-inbox`, CT ID `140` and bridge `vmbr0` with yours.

## 1. Network: the container must be on the camera's LAN

The camera finds the receiver by UDP broadcast. Give the container a NIC on the
same bridge as the LAN (`vmbr0`). Don't put it behind a NAT bridge, because
broadcasts don't cross NAT.

## 2. Inbox dataset and container (on the host)

```sh
zfs create -o mountpoint=/srv/fuji-inbox tank/fuji-inbox

pveam update && pveam available | grep alpine     # download the current one with pveam
# The template file name below is an example; use the one pveam downloaded
pct create 140 local:vztmpl/alpine-3.24-default_20260601_amd64.tar.xz \
    --hostname fuji-autosave --unprivileged 1 --cores 1 --memory 512 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp --rootfs local-zfs:4 --onboot 1
pct set 140 -mp0 /srv/fuji-inbox,mp=/srv/fuji-inbox
pct start 140

# Reserve Fuji's ports from the ephemeral range (see packaging/90-fuji-autosave.conf).
# This is a per-network-namespace sysctl; set it here if the container can't.
pct exec 140 -- sysctl -w net.ipv4.ip_local_reserved_ports=51540-51562,55740-55742
```

Ownership: the container's `fuji` user (created below) maps to host UID
`100000 + <its uid>`. Give that UID the dataset, for example
`chown 100100:100101 /srv/fuji-inbox` if `id fuji` prints `uid=100 gid=101`.

Use a DHCP reservation so the container keeps a stable address. It isn't
required, but it makes debugging easier.

## 3. Inside the container (Alpine)

```sh
apk add build-base cmake samurai pkgconf libusb-dev git nodejs npm
npm install -g @immich/cli        # flags checked against 3.3.4

addgroup -S fuji && adduser -S -D -H -h /var/lib/fuji-autosave -s /sbin/nologin -G fuji fuji

git clone https://github.com/nyaadesu/fuji-autosave-to-immich /opt/fuji-autosave-to-immich && cd /opt/fuji-autosave-to-immich
scripts/fetch-deps.sh
cmake -G Ninja -B build && cmake --build build
cmake --install build --prefix /usr/local

install -Dm644 packaging/90-fuji-autosave.conf /etc/sysctl.d/90-fuji-autosave.conf
rc-update add sysctl boot

install -Dm640 -g fuji packaging/fuji-autosave.env.example /etc/fuji-autosave/env
vi /etc/fuji-autosave/env                    # Immich URL, API key, album
install -Dm755 packaging/fuji-autosave.initd /etc/init.d/fuji-autosave
install -Dm644 packaging/fuji-autosave.confd /etc/conf.d/fuji-autosave
vi /etc/conf.d/fuji-autosave                 # client name, paths (defaults are fine)

rc-update add fuji-autosave default && rc-service fuji-autosave start
tail -f /var/log/messages                    # logs go to syslog, tag fuji-autosave
```

The build tools are only needed to compile. Afterwards you can remove them
with `apk del build-base cmake samurai git`, but keep `libusb`, `nodejs`
and `npm`.

`supervise-daemon` restarts the receiver if it exits. On stop, a running
upload gets 300 s to finish.

Create the Immich API key under Account Settings → API Keys. It needs asset
upload, and album permissions if `FUJI_IMMICH_ALBUM` is set.

## 4. Pair the camera

1. On the camera, open the network menu → PC AUTO SAVE SETTING and register a
   destination. The log shows `registered with FUJIFILM-...`.
2. Start PC AUTO SAVE (from playback, or automatically at power-off, depending
   on settings). The log shows `AutoSave request`, one `saved ...` line per
   file, `session done`, and then the hook's upload.
3. To retry a failed upload by hand (the hook reads `/etc/fuji-autosave/env`
   itself):

   ```sh
   doas -u fuji /usr/local/lib/fuji-autosave/immich-hook    # or: su -s /bin/sh fuji -c ...
   ```

## Alternative: Immich external library instead of the upload hook

Set `FUJI_HOOK=` (empty) in `/etc/conf.d/fuji-autosave`. Then mount
`/srv/fuji-inbox` read-only into `immich-server` and add it as an
[external library](https://docs.immich.app/features/libraries) with a periodic
rescan. Files are never copied, but Immich metadata is lost if they move later.
