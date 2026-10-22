#!/usr/bin/env python3
"""Minimal stand-in for the Immich API endpoints scripts/immich-hook uses.

  fake-immich.py STATE_DIR HOST_ROOT CONTAINER_ROOT

Writes its port to STATE_DIR/port and every request to STATE_DIR/calls.log.
A library scan indexes the media files under HOST_ROOT as CONTAINER_ROOT paths,
but only on the FAKE_SCAN_POLLS-th search after it (scans are asynchronous in
Immich). Files whose name contains FAKE_HIDE are never indexed.
FAKE_EXIF="DSCF0030:X-H2;DSCF0031:X-T5" gives files whose name contains the
key an EXIF Model; all others look like metadata extraction hasn't run yet.
Files whose name contains FAKE_TRASH are indexed as trashed. FAKE_VERSION
(default 3.3.5) is the reported server version, FAKE_PAGE_MAX caps page sizes.
Behaviour copied from Immich v3.3.5's structured search (the deprecated flat
fields are rejected, as v4 will): trashed assets match unless trashedAt is
filtered, originalPath.startsWith is a case-insensitive prefix, withExif is a
left join, paging is by cursor. Bulk adds report existing members as
"duplicate", and creating a stack replaces any stack whose primary asset is
one of the given assets.
"""
import json
import os
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

STATE, HOST_ROOT, CONTAINER_ROOT = sys.argv[1:4]
LIBRARY_ID = "11111111-1111-4111-8111-111111111111"
API_KEY = "test-key"
SCAN_POLLS = int(os.environ.get("FAKE_SCAN_POLLS", "2"))
HIDE = os.environ.get("FAKE_HIDE", "")
MEDIA = {".jpg", ".jpeg", ".raf"}
EXIF = dict(kv.split(":", 1) for kv in os.environ.get("FAKE_EXIF", "").split(";") if kv)
TRASH = os.environ.get("FAKE_TRASH", "")
VERSION = os.environ.get("FAKE_VERSION", "3.3.5")
PAGE_MAX = int(os.environ.get("FAKE_PAGE_MAX", "1000"))

assets = {}       # id -> asset
tags = {}         # value -> {id, value, name}
tag_assets = {}   # tag id -> set(asset id)
albums = {}       # id -> {id, albumName, assets:set}
stacks = {}       # id -> {id, primaryAssetId, assets:[ids]}
exif = {}         # asset id -> exifInfo, once "extracted"
scan_pending = None


def new_id():
    return str(uuid.uuid4())


def index_library():
    known = {a["originalPath"] for a in assets.values()}
    for d, _, files in os.walk(HOST_ROOT):
        for f in sorted(files):
            if os.path.splitext(f)[1].lower() not in MEDIA or (HIDE and HIDE in f):
                continue
            rel = os.path.relpath(os.path.join(d, f), HOST_ROOT)
            path = CONTAINER_ROOT + "/" + rel
            if path in known:
                continue
            i = new_id()
            assets[i] = {"id": i, "originalPath": path, "originalFileName": f, "libraryId": LIBRARY_ID,
                         "visibility": "timeline", "isOffline": False, "stackId": None,
                         "deletedAt": "2026-10-01T00:00:00.000Z" if TRASH and TRASH in f else None}
            for key, model in EXIF.items():
                if key in f:
                    exif[i] = {"make": "FUJIFILM", "model": model}


def matches(a, f):
    """The subset of Immich's SearchFilter the hook uses; anything else is a KeyError."""
    for key, cond in f.items():
        if key == "libraryId":
            ok = a["libraryId"] == cond["eq"]
        elif key == "originalPath":
            # startsWith is a case-insensitive LIKE prefix
            ok = a["originalPath"].lower().startswith(cond["startsWith"].lower())
        elif key == "tagIds":
            ok = any(a["id"] in tag_assets.get(t, set()) for t in cond["any"])
        elif key == "albumIds":
            ok = any(a["id"] in albums[al]["assets"] for al in cond["any"])
        elif key == "trashedAt":
            ok = a["deletedAt"] == cond["eq"]
        elif key == "isOffline":
            ok = a["isOffline"] == cond["eq"]
        elif key == "visibility":
            ok = a["visibility"] in cond["in"]
        else:
            raise KeyError(key)
        if not ok:
            return False
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        global scan_pending
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        with open(os.path.join(STATE, "calls.log"), "a") as f:
            f.write(f"{method} {url.path} {json.dumps(body, sort_keys=True) if body is not None else ''}\n")
        if self.headers.get("x-api-key") != API_KEY:
            return self.reply(401, {"message": "Invalid API key"})
        p = url.path

        if method == "GET" and p == f"/api/libraries/{LIBRARY_ID}":
            return self.reply(200, {"id": LIBRARY_ID, "name": "Fuji", "importPaths": [CONTAINER_ROOT]})
        if method == "POST" and p == f"/api/libraries/{LIBRARY_ID}/scan":
            scan_pending = SCAN_POLLS
            return self.reply(204)
        if method == "POST" and p == "/api/search/metadata":
            if scan_pending is not None:
                scan_pending -= 1
                if scan_pending <= 0:
                    index_library()
                    scan_pending = None
            # Structured filters only: the flat fields are deprecated and go away in v4
            flat = sorted(set(body) - {"filter", "cursor", "size", "withExif", "withStacked", "orderBy"})
            if flat:
                return self.reply(400, {"message": f"deprecated flat search fields: {flat}"})
            try:
                items = [a for a in assets.values() if matches(a, body.get("filter") or {})]
            except KeyError as e:
                return self.reply(400, {"message": f"unsupported filter {e}"})
            if body.get("withExif"):
                # A left join: assets without EXIF yet have exifInfo null
                items = [dict(a, exifInfo=exif.get(a["id"])) for a in items]
            items.sort(key=lambda a: a["originalPath"])
            # FAKE_PAGE_MAX caps the page size so tests exercise cursors
            size = min(body.get("size", 250), PAGE_MAX)
            offset = int(body.get("cursor") or 0)
            chunk = items[offset:offset + size]
            more = len(items) > offset + size
            return self.reply(200, {"albums": {"items": [], "total": 0, "count": 0},
                                    "assets": {"items": chunk, "total": len(chunk), "count": len(chunk),
                                               "nextPage": None, "facets": [],
                                               "nextCursor": str(offset + size) if more else None}})
        if method == "GET" and p == "/api/server/version":
            major, minor, patch = (int(x) for x in VERSION.split("."))
            return self.reply(200, {"major": major, "minor": minor, "patch": patch, "prerelease": None})
        if method == "GET" and p == "/api/tags":
            return self.reply(200, list(tags.values()))
        if method == "PUT" and p == "/api/tags":
            out = []
            for value in body["tags"]:
                # "A/B" also creates the parent "A", as Immich does
                parts = value.split("/")
                for n in range(1, len(parts) + 1):
                    v = "/".join(parts[:n])
                    if v not in tags:
                        tags[v] = {"id": new_id(), "value": v, "name": parts[n - 1]}
                out.append(tags[value])
            return self.reply(200, out)
        m = re.fullmatch(r"/api/(tags|albums)/([^/]+)/assets", p)
        if method == "PUT" and m:
            members = tag_assets.setdefault(m[2], set()) if m[1] == "tags" else albums[m[2]]["assets"]
            out = []
            for i in body["ids"]:
                if i in members:
                    out.append({"id": i, "success": False, "error": "duplicate"})
                elif i not in assets:
                    out.append({"id": i, "success": False, "error": "not_found"})
                else:
                    members.add(i)
                    out.append({"id": i, "success": True})
            return self.reply(200, out)
        if method == "GET" and p == "/api/stacks":
            return self.reply(200, [{"id": s["id"], "primaryAssetId": s["primaryAssetId"],
                                     "assets": [assets[i] for i in s["assets"]]} for s in stacks.values()])
        if method == "POST" and p == "/api/stacks":
            ids = list(body["assetIds"])
            for s in [s for s in stacks.values() if s["primaryAssetId"] in ids]:
                ids += [i for i in s["assets"] if i not in ids]
                del stacks[s["id"]]
            s = {"id": new_id(), "primaryAssetId": ids[0], "assets": ids}
            stacks[s["id"]] = s
            for i in ids:
                assets[i]["stackId"] = s["id"]
            return self.reply(201, {"id": s["id"], "primaryAssetId": ids[0], "assets": [assets[i] for i in ids]})
        if method == "GET" and p == "/api/albums":
            return self.reply(200, [{"id": a["id"], "albumName": a["albumName"], "assetCount": len(a["assets"])}
                                    for a in albums.values()])
        if method == "POST" and p == "/api/albums":
            a = {"id": new_id(), "albumName": body["albumName"], "assets": set()}
            albums[a["id"]] = a
            return self.reply(201, {"id": a["id"], "albumName": a["albumName"], "assetCount": 0})
        if method == "PUT" and p == "/api/assets":
            for i in body["ids"]:
                if "visibility" in body:
                    assets[i]["visibility"] = body["visibility"]
            return self.reply(204)
        if method == "POST" and p == "/api/_user":
            # Test-only: what a user does in the web UI, {"op": ..., "path": ...}
            op, path = body["op"], body.get("path")
            ids = [i for i, a in assets.items() if a["originalPath"] == path]
            if op == "wipe":
                assets.clear(); stacks.clear(); exif.clear()
                for members in tag_assets.values():
                    members.clear()
                for al in albums.values():
                    al["assets"].clear()
            for i in ids:
                if op == "unstack":
                    for s in [s for s in stacks.values() if i in s["assets"]]:
                        del stacks[s["id"]]
                        for j in s["assets"]:
                            assets[j]["stackId"] = None
                elif op == "album_remove":
                    for al in albums.values():
                        al["assets"].discard(i)
                elif op == "untag":
                    for members in tag_assets.values():
                        members.discard(i)
                elif op == "unarchive":
                    assets[i]["visibility"] = "timeline"
                elif op == "trash":
                    assets[i]["deletedAt"] = "2026-10-22T00:00:00.000Z"
                elif op == "delete":
                    # Permanent delete: the row goes; the read-only file stays
                    for s in [s for s in stacks.values() if i in s["assets"]]:
                        del stacks[s["id"]]
                        for j in s["assets"]:
                            if j in assets:
                                assets[j]["stackId"] = None
                    for members in tag_assets.values():
                        members.discard(i)
                    for al in albums.values():
                        al["assets"].discard(i)
                    del assets[i]
            return self.reply(204)
        if method == "GET" and p == "/api/_state":
            return self.reply(200, {
                "assets": {a["originalPath"]: a for a in assets.values()},
                "tags": {v: sorted(assets[i]["originalPath"] for i in tag_assets.get(t["id"], ()))
                         for v, t in tags.items()},
                "albums": {a["albumName"]: sorted(assets[i]["originalPath"] for i in a["assets"])
                           for a in albums.values()},
                "stacks": [[assets[i]["originalPath"] for i in s["assets"]] for s in stacks.values()],
            })
        return self.reply(404, {"message": f"no route {method} {p}"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(STATE, "port.tmp"), os.path.join(STATE, "port"))
server.serve_forever()
