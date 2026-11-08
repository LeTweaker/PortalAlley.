#!/usr/bin/env python3
"""Fetch one downloadable Sketchfab capture for review, with its licence recorded.

Used for the Tokyo captures that are not mirrored on Objaverse. Sketchfab's
download API needs a personal API token from a *free* account (no purchase):
  Sketchfab -> Settings -> Password & API -> API token
Store it as the repository secret SKETCHFAB_TOKEN. Without it this script exits
with a clear message and downloads nothing.

The script refuses any model whose licence is not CC0 / CC BY / CC BY-SA, or that
the author has not marked downloadable. Nothing is bought; paid "store" models
are never downloadable through this endpoint.

usage: fetch_capture.py <model-uid> <out-dir>
"""
from __future__ import annotations
import hashlib, json, os, sys, urllib.request, zipfile, io, pathlib, datetime

API = "https://api.sketchfab.com/v3/models/"
OK = {"cc0": "CC0 1.0", "by": "CC BY 4.0", "by-sa": "CC BY-SA 4.0"}


def req(url: str, token: str | None = None):
    r = urllib.request.Request(url, headers={"User-Agent": "PortalAlley-asset-review/1.4"})
    if token:
        r.add_header("Authorization", f"Token {token}")
    return urllib.request.urlopen(r, timeout=120)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__); return 2
    uid, out = sys.argv[1].strip(), pathlib.Path(sys.argv[2])
    token = os.environ.get("SKETCHFAB_TOKEN", "").strip()
    meta = json.load(req(API + uid))
    lic = (meta.get("license") or {}).get("slug") or (meta.get("license") or {}).get("label", "")
    print(f"{meta.get('name')} by {meta['user']['username']} - licence {lic}, downloadable={meta.get('isDownloadable')}")
    if lic not in OK:
        print(f"refused: licence '{lic}' is not CC0 / CC BY / CC BY-SA"); return 1
    if not meta.get("isDownloadable"):
        print("refused: the author has not made this model downloadable"); return 1
    if not token:
        print("SKETCHFAB_TOKEN secret not set - create a free Sketchfab account, copy its API token,\n"
              "and add it under GitHub -> Settings -> Secrets and variables -> Actions.")
        return 3
    links = json.load(req(API + uid + "/download", token))
    fmt = "glb" if "glb" in links else "gltf"
    blob = req(links[fmt]["url"]).read()
    out.mkdir(parents=True, exist_ok=True)
    if fmt == "glb":
        (out / f"{uid}.glb").write_bytes(blob)
        files = [f"{uid}.glb"]
    else:
        zipfile.ZipFile(io.BytesIO(blob)).extractall(out / uid)
        files = sorted(str(p.relative_to(out)) for p in (out / uid).rglob("*") if p.is_file())
    prov = dict(
        title=meta.get("name"), author=meta["user"].get("displayName") or meta["user"]["username"],
        authorProfile=meta["user"].get("profileUrl"), source=meta.get("viewerUrl"),
        licence=OK[lic], licenceSlug=lic, description=(meta.get("description") or "")[:2000],
        published=meta.get("publishedAt"), faceCount=meta.get("faceCount"), vertexCount=meta.get("vertexCount"),
        format=fmt, files=files, sha256=hashlib.sha256(blob).hexdigest(), bytes=len(blob),
        fetched=datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
        note="Fetched for review only. Verify the capture method (photogrammetry/LiDAR) in the description "
             "before shipping; credit the author in the app per the licence.")
    (out / "provenance.json").write_text(json.dumps(prov, indent=2))
    print(json.dumps({k: prov[k] for k in ("title", "author", "licence", "bytes")}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
