# Deploying with Docker

The image contains the receiver and the Immich hook. Run it with Docker
Compose on the Docker host that runs Immich. Every setting is in
`compose.yaml`, and only the API key lives in `.env`. Updating is a `pull`, so
nothing has to be set up from scratch on a reinstall. (The manual Alpine LXC
setup is still described in [deploy-lxc.md](deploy-lxc.md).)

```
host /tank/fuji ──> fuji-autosave  /fuji      (read-write, the receiver's inbox)
                ──> immich-server  /mnt/fuji  (read-write, the library's import path)
                ──> SMB            darktable / Lightroom
```

The design is in [immich-import-plan.md](immich-import-plan.md).

## 1. Requirements on the Docker host

- **On the camera's LAN, with host networking.** The camera finds the
  receiver by UDP broadcast and then connects back to it, so the container
  uses `network_mode: host`. If the Docker host is an LXC or VM, give it a NIC
  bridged onto the LAN, not a NAT network. (A macvlan network with its own
  LAN IP also works if you prefer that.)
- **Ports.** Fuji uses UDP 51541/51542 (discovery), TCP 51540–51562 and TCP
  55740 (camera). If the host has a firewall, allow them from the LAN. They lie
  inside Linux's ephemeral port range, so reserve them **on the host**, because
  the container shares the host's network:

  ```sh
  install -m644 packaging/90-fuji-autosave.conf /etc/sysctl.d/   # or copy its one line
  sysctl --system
  ```

- **The dataset**, mounted at the same path on the Docker host. If Docker runs
  in an LXC on Proxmox, bind-mount it there first
  (`pct set <id> -mpX /tank/fuji,mp=/tank/fuji`).

## 2. Dataset and ownership

```sh
zfs create -o recordsize=1M -o compression=lz4 tank/fuji
chown 1000:1000 /tank/fuji
```

The container runs as `user: "1000:1000"` (in `compose.yaml`), and new files
belong to that uid. Immich (step 3) and the user that edits over SMB also have
to delete files and write `.xmp` sidecars in the library, so give them all one
group: pick a gid (here 2000), set it as the container's group
(`user: "1000:2000"`), make Immich's user and the SMB user members, and make
the folders setgid so new files keep the group. `FUJI_UMASK: "002"` (the
default) makes new folders and files group-writable. On the host:

```sh
chgrp -R 2000 /tank/fuji && find /tank/fuji -type d -exec chmod 2775 {} +
```

In an unprivileged LXC, host ids are shifted by 100000 (container uid 1000 =
host uid 101000, container gid 2000 = host gid 102000): use host gid 102000
above, and the same gid 2000 in every LXC that shares the dataset.

Keep ZFS snapshots of `tank/fuji` (sanoid, zfs-auto-snapshot). The hook deletes
files that you deleted in Immich, and snapshots are the safety net.

## 3. Immich (one time)

Needs **Immich 3.2 or newer**. Mount the dataset **read-write** into
`immich-server` (in Immich's own compose file):

```yaml
immich-server:
  volumes:
    - /tank/fuji:/mnt/fuji
```

Read-write, because deleting a photo for good in Immich then deletes its file
and sidecar (with a read-only mount the next scan would import it again), and
because Immich writes ratings and other changes into `<file>.xmp`, where
darktable reads them (see [Ratings and darktable](#ratings-and-darktable)).
Immich's user needs the group from step 2. If Immich runs natively in an LXC,
bind-mount the dataset there (`pct set <id> -mpX /tank/fuji,mp=/fuji`), add
its user to the group (`groupadd -g 2000 fuji && usermod -aG fuji immich`,
then restart Immich), and use `/fuji` as the import path and as
`PHOTO_ROOT_CONTAINER`.

Then, in the Immich web UI:

1. Administration → External Libraries → Create library, owned by your own
   user, import path `/mnt/fuji`, with the exclusion patterns `**/.incoming/**`
   (partial downloads) and `**/.fuji-autosave/**` (the receiver's state). Note
   its ID (shown in the page URL).
2. Periodic scanning of external libraries (Administration → Settings →
   External Library) can stay on. With a read-only mount it has to be off,
   or a scan imports a photo deleted in Immich again before the hook
   deletes its file.
3. Account Settings → API Keys → New API key, as that same user, with these
   permissions: `library.read`, `library.update`, `asset.read`, `asset.update`,
   `tag.read`, `tag.create`, `tag.asset`, `stack.read`, `stack.create`,
   `album.read`, `album.create`, `albumAsset.create`.
4. Account Settings → Features: enable Tags.

## 4. Install

```sh
mkdir -p /opt/fuji-autosave && cd /opt/fuji-autosave
curl -fsSLO https://raw.githubusercontent.com/nyaadesu/fuji-autosave-to-immich/main/compose.yaml
echo 'IMMICH_API_KEY=...' > .env && chmod 600 .env
vi compose.yaml        # LIBRARY_ID, IMMICH_URL, paths, user, client name

docker compose run --rm fuji-autosave check     # Immich version, library, API key
docker compose up -d
docker compose logs -f
```

`IMMICH_URL` defaults to `http://127.0.0.1:2283`. With host networking that's
Immich's published port on the same host.

**Building the image yourself** instead of pulling it from GHCR:

```sh
git clone https://github.com/nyaadesu/fuji-autosave-to-immich && cd fuji-autosave-to-immich
scripts/fetch-deps.sh
docker compose build
```

### Immich in the same compose project

If Immich runs with Docker Compose on the same host, both can be managed from
one place. Keep Immich's `docker-compose.yml` (from its release) and this
`compose.yaml` in their own folders, each with its own `.env`, and join them
with a top-level file next to the two folders:

```yaml
name: immich
include:
  - immich/docker-compose.yml
  - fuji-autosave/compose.yaml
```

`docker compose up -d`, `pull`, `ps` and `logs -f <service>` there then cover
both. An included file reads the `.env` in its own folder, so neither app gets
the other's secrets. `IMMICH_URL` stays `http://127.0.0.1:2283`. For the hook
and darktable, `immich-server` needs the library mounted read-write at
`PHOTO_ROOT_CONTAINER`, the library's group, and a umask that keeps the
sidecars it writes group-writable:

```yaml
services:
  immich-server:
    volumes:
      - /tank/fuji:/mnt/fuji
    group_add:
      - "2000"   # the library's group (step 2)
    # The image runs `bash -c start.sh`
    command: ["umask 0007 && exec start.sh"]
```

Add these to Immich's `docker-compose.yml`, and compare it with the new
release's file when you update Immich.

## 5. Pair the camera

1. On the camera, open the network menu → PC AUTO SAVE SETTING and register.
   The log shows `registered with FUJIFILM-...`.
2. Start PC AUTO SAVE from the Playback menu. The log shows each `saved ...`
   file, `session done`, then the hook (`scan started`, and a `done:` summary).

## Ratings and darktable

Pick photos in Immich, edit them in darktable. When you change a rating,
description, date or location in Immich, it writes that into the file's
`.xmp` sidecar, and darktable reads it from there.

- Rate the stack (its cover is the JPEG). Within `SYNC_INTERVAL` (5 minutes)
  the receiver copies a rating or favorite to the other file of the pair, so
  `DSCF1234.RAF.xmp` gets the stars darktable shows. Favorites stay in Immich.
- In darktable, turn on Preferences → Storage → "look for updated XMP files on
  startup", so it loads what Immich changed instead of overwriting it, and
  set the initial rating of imported images to 0 stars.
- Don't rate or describe in darktable: Immich doesn't read a sidecar again
  when it changes, and its next write would overwrite those fields.
- Immich's thumbnails are the camera's rendering, not darktable's edits.

## Operating it

| Task | Command |
| --- | --- |
| Logs | `docker compose logs -f` |
| Retry queued batches now | `docker compose exec fuji-autosave docker-entrypoint hook` |
| Check settings and API key | `docker compose run --rm fuji-autosave check` |
| Sync pair ratings and deletions now | `docker compose exec fuji-autosave docker-entrypoint hook --sync` |
| Update | `docker compose pull && docker compose up -d` |
| Verbose protocol log | set `FUJI_EXTRA_ARGS: "--verbose"`, then `docker compose up -d` |

On stop, a hook that is still waiting for an Immich scan gets up to 5 minutes
(`stop_grace_period`). The state (`seen.tsv`, queued batch lists,
`library.json`) is in `.fuji-autosave/` in the library, so it survives updates
and reinstalls, and the dataset's snapshots cover it. Without `library.json`,
the hook treats every photo as new once.

See [deploy-lxc.md § Things to know](deploy-lxc.md#things-to-know) for how
deletion, sidecars, tags and file times behave. That applies here too.
