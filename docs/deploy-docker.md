# Deploying with Docker

The image contains the receiver and the Immich hook. Run it with Docker
Compose on the Docker host that runs Immich. Every setting is in
`compose.yaml`, and only the API key lives in `.env`. Updating is a `pull`, so
nothing has to be set up from scratch on a reinstall. (The manual Alpine LXC
setup is still described in [deploy-lxc.md](deploy-lxc.md).)

```
host /data2/fuji ──> fuji-autosave  /fuji      (read-write, the receiver's inbox)
                 ──> immich-server  /mnt/fuji  (read-only, the library's import path)
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
  (`pct set <id> -mpX /data2/fuji,mp=/data2/fuji`).

## 2. Dataset and ownership

```sh
zfs create -o recordsize=1M -o compression=lz4 data2/fuji
mkdir -p /data2/config/fuji-autosave
chown 1000:1000 /data2/fuji /data2/config/fuji-autosave
```

The container runs as `user: "1000:1000"` (in `compose.yaml`), and new files
belong to that uid. Pick the uid of the user that edits over SMB, or give the
dataset a shared group (`chmod 2775`, `FUJI_UMASK: "002"`). In an unprivileged
LXC, host uids are shifted by 100000 (container uid 1000 = host uid 101000).

Keep ZFS snapshots of `data2/fuji` (sanoid, zfs-auto-snapshot). The hook deletes
files that you deleted in Immich, and snapshots are the safety net.

## 3. Immich (one time)

Needs **Immich 3.2 or newer**. Mount the dataset **read-only** into
`immich-server` (in Immich's own compose file):

```yaml
immich-server:
  volumes:
    - /data2/fuji:/mnt/fuji:ro
```

Then, in the Immich web UI:

1. Administration → External Libraries → Create library, owned by your own
   user, import path `/mnt/fuji`. Note its ID (shown in the page URL).
2. Administration → Settings → External Library: turn **off** periodic
   scanning. The hook triggers a scan after every batch, and an extra scan
   would import a photo you deleted in Immich again before the hook can delete
   its file.
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

## 5. Pair the camera

1. On the camera, open the network menu → PC AUTO SAVE SETTING and register.
   The log shows `registered with FUJIFILM-...`.
2. Start PC AUTO SAVE from the Playback menu. The log shows each `saved ...`
   file, `session done`, then the hook (`scan started`, and a `done:` summary).

## Operating it

| Task | Command |
| --- | --- |
| Logs | `docker compose logs -f` |
| Retry queued batches now | `docker compose exec fuji-autosave docker-entrypoint hook` |
| Check settings and API key | `docker compose run --rm fuji-autosave check` |
| Update | `docker compose pull && docker compose up -d` |
| Verbose protocol log | set `FUJI_EXTRA_ARGS: "--verbose"`, then `docker compose up -d` |

On stop, a hook that is still waiting for an Immich scan gets up to 5 minutes
(`stop_grace_period`). The state in `/data2/config/fuji-autosave` (`seen.tsv`,
queued batch lists, `library.json`) survives updates and reinstalls. Keep it
together with the dataset. Without `library.json`, the hook treats every photo
as new once.

See [deploy-lxc.md § Things to know](deploy-lxc.md#things-to-know) for how
deletion, sidecars, tags and file times behave. That applies here too.
