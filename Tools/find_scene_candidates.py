"""Discover legally reusable, genuinely captured scenes and footage (CI only).

Runs on GitHub Actions (the development sandbox has no general internet).
Nothing is purchased and no account or token is used:

* Sketchfab public API (search + model metadata): licence, face count,
  description, thumbnails - to find real photogrammetry captures of
  Japanese alleys and streets under CC0 / CC BY.
* Objaverse 1.0 (allenai/objaverse on Hugging Face): a CC-licensed mirror of
  Sketchfab models, downloadable without login.  Candidates present there are
  downloaded (GLB) with their Objaverse licence record.
* Wikimedia Commons API: night / rain street videos of Tokyo with
  machine-readable licence and author.

Output (pushed to the review branch `assets/scene-candidates`):
    candidates/report.json, report.md, thumbs/*.jpg, glb/*.glb, commons/*.jpg
"""
from __future__ import annotations

import gzip
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "candidates")
UA = "PortalAlley-scene-discovery/1.4 (+https://github.com/LeTweaker/PortalAlley.)"
SCAN_WORDS = re.compile(r"scan|photogramm|reality ?capture|realityscan|metashape|polycam|lidar|captured|agisoft|meshroom|kiri", re.I)
OK_LICENCES = {"cc0", "by", "by-sa"}          # by-sa allowed for review; flagged
SKETCHFAB_QUERIES = [
    "tokyo alley", "tokyo alley scan", "shinjuku alley", "shinjuku scan", "yokocho", "omoide yokocho",
    "japan alley photogrammetry", "japanese alley scan", "japanese street scan", "japan street photogrammetry",
    "osaka alley scan", "kyoto alley scan", "tokyo street scan", "tokyo photogrammetry", "golden gai",
    "alley photogrammetry", "back alley scan", "narrow street scan", "alley scan night",
]
PINNED = [
    "ed537aa6aed24d249af239db9e0bf073",   # Tokyo Alley 3 (Geopogo) - Shinjuku alley scan, CC BY
    "0c930d5c8aa54036a97d520615c72195",   # Back Street Alley Photogrammetry Scan, CC BY
    "79e616eab10644f88cb772ddf71bfe0a",   # Freeman Alley Dataset, CC BY
    "fc7cb73b39404c9884888a38ebe67bcc",   # photoscan Alley optimized, CC BY
    "99b4b076710c4fec825d8c1180556902",   # Japanese Street (test), CC BY
    "b2ab0c61868044bf8d35bb0980a87b3c",   # Shinjuku Mosaic Street scan
    "c1bf64e194c848d696317dced64b4a5d",   # Japanese abandoned garage scan
]
COMMONS_QUERIES = [
    "Tokyo alley night filetype:video", "Shinjuku night filetype:video", "Tokyo rain night filetype:video",
    "Omoide Yokocho filetype:video", "Golden Gai filetype:video", "Tokyo street night walk filetype:video",
    "Kabukicho filetype:video", "Japan alley rain filetype:video",
]
MAX_GLB = 95_000_000


def get(url: str, binary: bool = False, tries: int = 3, limit: int = 400_000_000):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read(limit + 1)
            if len(data) > limit:
                raise ValueError("too large")
            return data if binary else json.loads(data)
        except Exception as e:  # noqa: BLE001
            if k == tries - 1:
                print(f"  ! {url[:100]}: {e}")
                return None
            time.sleep(2 + 3 * k)


def sketchfab() -> dict[str, dict]:
    seen: dict[str, dict] = {}
    for q in SKETCHFAB_QUERIES:
        url = "https://api.sketchfab.com/v3/search?" + urllib.parse.urlencode(
            {"type": "models", "q": q, "downloadable": "true", "count": 24})
        res = get(url) or {}
        for m in res.get("results", []):
            seen.setdefault(m["uid"], {"query": q})
        time.sleep(1)
    for uid in PINNED:
        seen.setdefault(uid, {"query": "pinned"})
    out = {}
    for uid, meta in seen.items():
        m = get(f"https://api.sketchfab.com/v3/models/{uid}")
        time.sleep(0.6)
        if not m:
            continue
        lic = (m.get("license") or {})
        slug = lic.get("slug") or ""
        text = " ".join([m.get("name", ""), m.get("description", "") or "", " ".join(t.get("name", "") for t in m.get("tags", []))])
        thumbs = sorted((m.get("thumbnails") or {}).get("images", []), key=lambda i: i.get("width", 0))
        thumb = next((i["url"] for i in thumbs if i.get("width", 0) >= 600), thumbs[-1]["url"] if thumbs else None)
        out[uid] = dict(
            uid=uid, name=m.get("name"), author=(m.get("user") or {}).get("displayName"),
            authorUrl=(m.get("user") or {}).get("profileUrl"), url=m.get("viewerUrl"),
            licence=lic.get("label"), licenceSlug=slug, licenceUrl=lic.get("url"),
            faces=m.get("faceCount"), vertices=m.get("vertexCount"), published=m.get("publishedAt"),
            downloadable=m.get("isDownloadable"), scanEvidence=bool(SCAN_WORDS.search(text)),
            description=(m.get("description") or "")[:600], tags=[t.get("name") for t in m.get("tags", [])][:25],
            query=meta["query"], thumbnail=thumb,
            archives={k: {kk: v.get(kk) for kk in ("size", "faceCount", "textureCount", "textureMaxResolution")}
                      for k, v in (m.get("archives") or {}).items() if isinstance(v, dict)},
        )
    return out


def objaverse(cands: dict[str, dict]):
    base = "https://huggingface.co/datasets/allenai/objaverse/resolve/main/"
    raw = get(base + "object-paths.json.gz", binary=True)
    if not raw:
        return
    paths = json.loads(gzip.decompress(raw))
    print(f"objaverse: {len(paths)} objects indexed")
    meta_cache: dict[str, dict] = {}
    for uid, c in cands.items():
        p = paths.get(uid)
        c["objaverse"] = None
        if not p:
            continue
        shard = p.split("/")[1]
        if shard not in meta_cache:
            mraw = get(base + f"metadata/{shard}.json.gz", binary=True)
            meta_cache[shard] = json.loads(gzip.decompress(mraw)) if mraw else {}
        om = meta_cache[shard].get(uid, {})
        c["objaverse"] = dict(path=p, licence=om.get("license"), name=om.get("name"),
                              published=om.get("publishedAt"), faces=om.get("faceCount"))


def main():
    (OUT / "thumbs").mkdir(parents=True, exist_ok=True)
    (OUT / "glb").mkdir(exist_ok=True)
    (OUT / "commons").mkdir(exist_ok=True)
    cands = sketchfab()
    keep = {u: c for u, c in cands.items() if c["licenceSlug"] in OK_LICENCES}
    print(f"sketchfab: {len(cands)} models inspected, {len(keep)} under CC0/BY/BY-SA")
    objaverse(keep)
    for uid, c in keep.items():
        if c.get("thumbnail") and (c["scanEvidence"] or c["query"] == "pinned"):
            img = get(c["thumbnail"], binary=True, limit=5_000_000)
            if img:
                (OUT / "thumbs" / f"{uid}.jpg").write_bytes(img)
        ov = c.get("objaverse")
        if ov and (c["scanEvidence"] or c["query"] == "pinned"):
            glb = get("https://huggingface.co/datasets/allenai/objaverse/resolve/main/" + ov["path"], binary=True, limit=MAX_GLB)
            if glb:
                (OUT / "glb" / f"{uid}.glb").write_bytes(glb)
                ov["bytes"] = len(glb)
    # Wikimedia Commons footage
    videos = {}
    for q in COMMONS_QUERIES:
        url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode({
            "action": "query", "format": "json", "generator": "search", "gsrsearch": q, "gsrnamespace": 6,
            "gsrlimit": 30, "prop": "imageinfo", "iiprop": "url|size|extmetadata|mediatype|mime",
            "iiurlwidth": 640})
        res = get(url) or {}
        for page in (res.get("query") or {}).get("pages", {}).values():
            ii = (page.get("imageinfo") or [{}])[0]
            if ii.get("mediatype") != "VIDEO":
                continue
            em = ii.get("extmetadata", {})
            val = lambda k: re.sub("<[^>]+>", "", (em.get(k) or {}).get("value", ""))[:300]  # noqa: E731
            videos[page["title"]] = dict(title=page["title"], url=ii.get("descriptionurl"), file=ii.get("url"),
                                         width=ii.get("width"), height=ii.get("height"), seconds=ii.get("duration"),
                                         bytes=ii.get("size"), mime=ii.get("mime"), licence=val("LicenseShortName"),
                                         licenceUrl=val("LicenseUrl"), artist=val("Artist"), credit=val("Credit"),
                                         date=val("DateTimeOriginal"), description=val("ImageDescription"),
                                         poster=ii.get("thumburl"), query=q)
        time.sleep(1)
    for t, v in videos.items():
        if v.get("poster"):
            img = get(v["poster"], binary=True, limit=3_000_000)
            if img:
                safe = re.sub(r"[^A-Za-z0-9._-]+", "_", t)[:120]
                (OUT / "commons" / f"{safe}.jpg").write_bytes(img)
                v["posterFile"] = f"commons/{safe}.jpg"
    report = dict(generated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), sketchfab=keep, commonsVideos=videos)
    (OUT / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    lines = ["# Scene candidates\n", "| scan | objaverse | licence | faces | name | author | url |", "|---|---|---|---|---|---|---|"]
    for c in sorted(keep.values(), key=lambda c: (not c["scanEvidence"], c.get("objaverse") is None)):
        lines.append(f"| {'Y' if c['scanEvidence'] else ''} | {'Y' if c.get('objaverse') else ''} | {c['licence']} | {c['faces']} | {c['name']} | {c['author']} | {c['url']} |")
    lines += ["\n# Commons videos\n", "| licence | s | size | title | artist |", "|---|---|---|---|---|"]
    for v in videos.values():
        lines.append(f"| {v['licence']} | {v['seconds']} | {v['width']}x{v['height']} | {v['title']} | {v['artist'][:60]} |")
    (OUT / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:60]))


if __name__ == "__main__":
    main()
