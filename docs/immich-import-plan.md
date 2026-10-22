# Fuji → Immich import: plan

This document is the agreed design for the camera import app. Use it as the source of truth for storage layout, Immich integration and the per-batch flow. Where an API detail is marked **verify**, confirm it against the running Immich instance's API docs (`/api/docs` or the docs for the installed version) before relying on it.

## Goal

Pull photos from a Fujifilm X-T30 II (shooting RAF + JPEG) onto the home server "roxy" so that:

1. The camera JPEGs show in the Immich timeline right away for viewing.
2. The RAF files are kept on disk as plain files that darktable or Lightroom Classic can open and edit in place over SMB.
3. In Immich, each RAF is grouped with its JPEG, all RAFs are collected in their own album, and every file from the camera is tagged.

Immich is the viewer and organiser. Editing happens in darktable / Lightroom Classic. Immich does not render darktable or Lightroom edits from XMP sidecars, so finished edits are exported as separate files (out of scope for this app, see "Later").

## Storage layout

Runs on roxy (Proxmox, ZFS pool `data2`, mounted at `/data2`). Existing datasets: `data2/backup`, `data2/config`, `data2/immich`, `data2/media`.

```
/data2/immich            Immich upload library (existing dataset, managed by Immich, do not write here)
/data2/fuji              new dataset data2/fuji: external library root for this app, shared over SMB for editing
```

`/data2/fuji` must stay outside `/data2/immich`. Immich rejects external library paths inside its upload location.

Dataset creation (one-time, done by the user, listed for context):

```
zfs create -o recordsize=1M -o compression=lz4 data2/fuji
```

File layout inside the external library:

```
/data2/fuji/YYYY/YYYY-MM-DD/DSCF1234.JPG
/data2/fuji/YYYY/YYYY-MM-DD/DSCF1234.RAF
/data2/fuji/YYYY/YYYY-MM-DD/DSCF1234.RAF.xmp   (written later by darktable, never by this app)
```

- Date folder comes from the capture date in EXIF (fall back to file mtime if EXIF is missing).
- Keep the camera's original filenames. JPEG and RAF share the stem `DSCF1234`, which is how pairs are matched.
- The app never modifies, renames or deletes files after they are written. Immich treats a moved file as a deleted asset plus a new one, which drops it from albums and stacks.

## Immich configuration (one-time, done by the user)

Mount into `immich-server` read-only:

```yaml
immich-server:
  volumes:
    - /data2/fuji:/mnt/fuji:ro
```

- Create an external library owned by the user's account with import path `/mnt/fuji` (container path, not host path). Store its library ID in the app config.
- Read-only matters: darktable owns the `.RAF.xmp` sidecars and Immich must not write to them.
- Tags may need enabling per user under Account Settings → Features.

App config values:

| Key | Example |
|---|---|
| `IMMICH_URL` | `http://immich.lan:2283` |
| `IMMICH_API_KEY` | from env / secrets, never committed |
| `LIBRARY_ID` | external library UUID |
| `PHOTO_ROOT_HOST` | `/data2/fuji` (where the app writes) |
| `PHOTO_ROOT_CONTAINER` | `/mnt/fuji` (path Immich sees, needed for path lookups) |
| `RAW_ALBUM_NAME` | `Fuji RAW` |
| `CAMERA_TAG` | `Camera/X-T30 II` |

API key permissions needed (**verify** exact names): library scan/read, asset read/update, stack create/read, album create/update, tag create/asset.

## Per-batch flow

1. **Copy files.** For each file from the camera, write to `<name>.part` in the target date folder, then rename to the final name once the copy has completed and been verified (size, optionally checksum). Immich must never see a partial file. Skip files that already exist at the destination with the same size/checksum.
2. **Trigger a scan.** `POST /api/libraries/{LIBRARY_ID}/scan`.
3. **Wait for assets.** Scanning and metadata extraction are asynchronous. Poll `POST /api/search/metadata` filtering by `originalPath` (container path, e.g. `/mnt/fuji/2026/2026-10-22/DSCF1234.JPG`) until each new file has an asset ID. Use backoff and an overall timeout. Batches of hundreds of RAFs can take minutes. (**verify** the search filter field name.)
4. **Tag.** Ensure the tag exists with `PUT /api/tags` (upsert, name `CAMERA_TAG`), cache its ID, then `PUT /api/tags/{tagId}/assets` with the IDs of all new JPEGs and RAFs in one call.
5. **Stack each pair.** `POST /api/stacks` with body `{"assetIds": [jpgId, rafId]}`. The first ID becomes the stack's cover, so the JPEG must be first. Skip pairs where either asset already has a `stack` set.
6. **RAW album.** Look up or create the album named `RAW_ALBUM_NAME` (`POST /api/albums` if missing, cache the ID). Add all new RAF asset IDs with `PUT /api/albums/{albumId}/assets`, body `{"ids": [...]}`, in one call.
7. **Report.** Log a summary: files copied, pairs stacked, RAFs added to album, and any unpaired files.

### Idempotency

The app must be safe to re-run on the same card or after a crash at any step:

- Copy skips files already present.
- Tag upsert and adding assets that already carry the tag are harmless.
- Stacking skips already-stacked assets.
- Album add tolerates assets already in the album (the API reports them as duplicates rather than failing, **verify**).

### Edge cases

- **Unpaired files** (JPEG without RAF, or the reverse, e.g. camera set to JPEG-only for some shots): import, tag, log. Do not stack. Unpaired RAFs still go into the RAW album.
- **Counter rollover** (`DSCF9999` → `DSCF0001`): pairs are matched within one date folder, so stems only need to be unique per day.
- **Scan timeout:** leave files in place, log which assets were not found, and let the next run pick them up (steps 4–6 should also process any earlier files in the library that are missing their tag/stack/album membership).

## Open test before building around stacks

It is not confirmed how Immich displays a RAF that is the non-cover member of a stack when that RAF is also in an album. Test with a single pair first:

- If the RAW album shows the RAFs properly and the timeline shows only the JPEG: keep the flow above.
- If not: replace stacking in step 5 with archiving the RAF (`PUT /api/assets` with `{"ids": [...], "visibility": "archive"}`; older versions use `isArchived: true`, **verify** for the installed version). Archived assets are hidden from the timeline but still appear in albums and search. Make this a config switch (`RAW_MODE = stack | archive`).

## Out of scope / later

- Rendering darktable edits in Immich. Immich currently ignores development settings in XMP. A possible later addition: a container that runs `darktable-cli` on any RAF whose `.RAF.xmp` changed and writes JPEGs to a separate folder or library (e.g. a separate `data2/fuji-edits` dataset, kept outside `/data2/fuji` so exported JPEGs never get mixed into RAF/JPEG pairing).
- Off-box backup of `data2/fuji` (ZFS snapshot send to another machine). Handled outside this app.
- If Immich runs in an LXC on Proxmox, `/data2/fuji` must also be bind-mounted into that container (`pct set <id> -mpX ...`) before the Docker volume line above can see it. Same for wherever this app runs.

---

## Appendix: verification and implementation notes (2026-10-22)

The **verify** items above, checked against the Immich **v3.3.5** OpenAPI spec
and server source (latest release on 2026-10-22). Recheck after a major upgrade.

| Item | Result |
|---|---|
| Scan | `POST /api/libraries/{id}/scan`, no body, 204. Permission `library.update`. |
| Search filter | The flat `originalPath` field is a case-insensitive **substring** match (`ilike '%…%'`) and deprecated, see the structured search note below. |
| `stack` on assets | Search results do **not** include `stack` (only `stackId` internally). The hook reads stack membership from `GET /api/stacks` (all of the user's stacks with their assets) instead. |
| Re-stacking | `POST /api/stacks` is not harmless to repeat: it deletes any stack whose primary is one of the given assets and creates a new one with the union of their assets. Hence the skip. It requires `asset.update` on the assets. |
| Tag / album add | `PUT /api/tags/{id}/assets` and `PUT /api/albums/{id}/assets` return per-ID results; assets already present come back as `{"success": false, "error": "duplicate"}`. Confirmed harmless. |
| Tag upsert | `PUT /api/tags` with `{"tags": ["Camera/X-T30 II"]}` creates the hierarchy and returns the tags; the leaf has `value` equal to the full path. |
| Archive | `PUT /api/assets` with `{"ids": [...], "visibility": "archive"}`. `isArchived` is a read-only response field now. |
| Permissions | `library.read`, `library.update`, `asset.read`, `asset.update`, `tag.read`, `tag.create`, `tag.asset`, `stack.read`, `stack.create`, `album.read`, `album.create`, `albumAsset.create`. |

How the implementation maps onto the plan:

- **Step 1 is the receiver itself.** The camera pushes over PTP/IP, so there
  is no card to copy from. The receiver LXC bind-mounts `/data2/fuji` at `/fuji` (so it works the
  same wherever the dataset lives on the host), and `fuji-autosave-receiver --inbox /fuji` writes
  `YYYY/YYYY-MM-DD/NAME`, keeping the camera's file names. As the plan says,
  the date comes from EXIF `DateTimeOriginal` of the downloaded file (a RAF
  through its embedded JPEG, `src/exif.c`). That is the camera's local time,
  which is right even when travelling. Without EXIF the receiver falls back to
  the capture instant from PTP/IP in its own time zone, then to today.
  **The capture date in PTP/IP ObjectInfo is UTC** on the X-T30 II: a shot
  with EXIF `2026:10:22 20:45:28 +02:00` arrives as `20261022T184528`. Using it
  directly would put shots taken between midnight and 2 a.m. CEST into the previous
  day's folder. Partial downloads go to `.incoming/NAME.part` at the library root (same
  dataset, so the rename is atomic) rather than into the day folder, and are
  renamed only after the full size arrived and was fsynced. Add
  `**/.incoming/**` to the library's exclusion patterns. A file already in the
  library is skipped, even if `seen.tsv` was lost (see below).
- **Steps 2–7 are `scripts/immich-hook`** (Python 3, stdlib only), run by the
  receiver after each batch with new files. Steps 4–6 look at the **whole
  library** on every run, so files from timed-out or failed runs are caught up
  automatically. A batch list stays queued until all its files were found.
- **Each step happens once per file.** `$FUJI_STATE_DIR/library.json`
  records each file's asset ID and the steps done (`tag:<tag>`, `stack`,
  `archive`, `album:<name>`), so changes made in Immich afterwards (unstack,
  remove from the album, untag, unarchive) are not undone. A changed
  `CAMERA_TAG(_PREFIX)` or `RAW_ALBUM_NAME` is a new step and applies once to
  every file. A file that shows up with a new asset ID starts over.
- **Deleting in Immich deletes the file (a change from "never delete files").**
  In Immich v3.3.5, permanently deleting an external asset (or emptying the trash)
  removes its database row and queues a delete of the original and its
  sidecar. With the read-only mount that delete fails, and the next scan
  (`filterNewExternalAssetPaths`: any path without a row) imports the file
  again. So before every scan, the hook looks for recorded files whose asset
  is gone, or has a different ID, while the file is still on disk, and deletes
  the file and its `<file>.xmp` itself. A trashed asset still has its row and
  is left alone, so Immich's trash remains the undo window. The safety stops:
  - only files recorded in `library.json`
  - nothing if Immich lists no assets in the library
  - at most `DELETE_LIMIT` (50) files per run, and not more than half the
    library; a run that would delete more fails instead
  - `DELETE_REMOVED=0` to turn deletion off

  Immich's own periodic scan has to be off, or it re-imports a deleted photo
  before the hook sees it. The hook still deletes the file then, and the
  re-imported asset goes offline.
- Each file's mtime is the capture instant (the UTC PTP date). "Already in
  the library" means the same name with the same size **and** mtime in the day
  folder of the UTC date or the day on either side of it. The EXIF folder isn't known
  before downloading, but local time is within a day of UTC. Size alone
  doesn't tell shots apart (uncompressed RAFs are all one size, and `DSCF0001`
  repeats after a counter reset, a second card or a rollover). Such a reused
  name is saved as `DSCF0001-1.RAF`.
- Pairs are files with the same folder and stem (case-insensitive), exactly
  one `.JPG`/`.JPEG` and one `.RAF`, whose mtimes are within 2 s of each other.
  This stops two different shots from being stacked when only one of them got
  a `-1` name. In `RAW_MODE=archive` only paired RAFs
  are archived, so a RAW-only shot stays visible in the timeline.
- The tag is not hardcoded: each asset gets `CAMERA_TAG_PREFIX` (default
  `Camera/`) + its camera model. The model is Immich's EXIF `Model` for the
  asset; for files in the current batch whose EXIF Immich hasn't extracted yet,
  it is the model the camera reported in the PTP/IP session
  (`FUJI_CAMERA_MODEL`). An asset with neither stays untagged until a later run.
  Any `Camera/…` tag counts as tagged. Setting `CAMERA_TAG` restores one fixed
  tag. Listing tags needs `tag.read`.
- **Search uses the structured format (Immich ≥ 3.2).** The flat fields
  `libraryId`, `originalPath`, `tagIds`, `albumIds`, `page` of
  `POST /api/search/metadata` are deprecated since v3.2.0 and removed in v4. The
  hook sends `{"filter": {...}, "size": 1000, "cursor": ...}` instead, for example
  `{"libraryId": {"eq": id}, "originalPath": {"startsWith": "/mnt/fuji/2026/2026-10-22/"}}`,
  `{"tagIds": {"any": [id]}}` and `{"albumIds": {"any": [id]}}`, and follows
  `nextCursor`. Unlike the old format, it returns trashed assets and the owner's
  locked ones unless filtered, so every listing adds
  `trashedAt: {eq: null}`, `isOffline: {eq: false}` and
  `visibility: {in: [timeline, archive]}`. The exception is the wait for new files,
  where any asset at the path counts as found (otherwise a file trashed in Immich
  would keep its batch queued forever). `withExif` is a left join in this format,
  so the main listing returns the EXIF models too. `startsWith` is still a
  case-insensitive LIKE, so paths are compared exactly afterwards. The hook checks
  `GET /api/server/version` and refuses to run on anything older than 3.2.
- Extra settings: `RAW_MODE` (`stack`/`archive`) and `SCAN_TIMEOUT` (seconds,
  default 900).
