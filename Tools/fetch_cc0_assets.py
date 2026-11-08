#!/usr/bin/env python3
"""Fetch the CC0 photographed surfaces and scanned props used by v1.3.

Runs in CI (GitHub Actions has internet access; the authoring sandbox does
not).  The workflow commits the result under Vendor/polyhaven/ on the
`assets/cc0-vendor` branch so the files can be reviewed and vendored into the
repository.  App builds then use the vendored files and never need a network.

Every file is checksum-verified against Poly Haven's API metadata, and
provenance (asset id, name, authors, url, md5, sha256, license) is written to
Vendor/polyhaven/provenance.json.

Models are resolved BY NAME from the public asset list, so a renamed id fails
loudly instead of silently fetching something unrelated.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Vendor" / "polyhaven"
UA = "PortalAlley-CC0-Vendor/1.3 (build-time importer; credit: Poly Haven)"

# Photographed surfaces (ids verified on polyhaven.com).  1k JPG maps.
TEXTURES = [
    "asphalt_02", "concrete_floor_01", "concrete_wall_003",     # v1.2 set
    "concrete_tile_facade",     # tiled building facade (common in Japan)
    "red_plaster_weathered", "beige_wall_001", "concrete_wall_008",
    "concrete_layers", "precast_concrete_wall", "painted_concrete_02",
    "rusty_metal_03", "rust_coarse_01", "garage_floor", "mixed_brick_wall",
]
# Optional surfaces discovered by name (first match per pattern).
TEXTURE_PATTERNS = {
    "corrugated": r"corrugated",
    "planks": r"(weathered|old|dark).*plank|plank",
}
# Scanned / photographed props from "The Hidden Alley" and related CC0 sets.
MODELS_REQUIRED = ["Exterior Aircon Unit", "Utility Box 01", "Utility Box 02", "Metal Trash Can"]
MODELS_OPTIONAL = ["Propane Tank", "Security Light", "Mounted Fluorescent Lights",
                   "Rollershutter Window 03", "Modular Airduct Circular 01", "Security Camera 01"]
# Names to list (for review only) - candidate future props.
DISCOVER = r"bicycle|bike|crate|bucket|umbrella|plant|pot|lantern|pipe|cable|vending|bottle|sign|meter|scooter|bin|cone|barrier"
MAX_FILE = 30_000_000


def get(url: str) -> bytes:
    host = urlparse(url).hostname or ""
    if not (host == "api.polyhaven.com" or host.endswith(".polyhaven.org") or host.endswith(".polyhaven.com")):
        raise ValueError(f"unexpected host {host}")
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
                data = r.read(MAX_FILE + 1)
            if len(data) > MAX_FILE:
                raise ValueError(f"file over budget: {url}")
            return data
        except Exception as e:  # noqa: BLE001
            if attempt == 3:
                raise
            print(f"  retry {url}: {e}")
            time.sleep(2 * (attempt + 1))
    raise AssertionError


def save(rel: str, data: bytes, md5: str | None, meta: dict, prov: list) -> None:
    if md5 and hashlib.md5(data).hexdigest() != md5:
        raise ValueError(f"checksum mismatch {rel}")
    path = OUT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    prov.append({**meta, "file": rel, "md5": md5, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})


def authors(info: dict) -> list[str]:
    a = info.get("authors") or {}
    return sorted(a.keys()) if isinstance(a, dict) else list(a)


def texture_maps(files: dict) -> dict[str, dict]:
    """Pick 1k jpg (or png) records for diff/rough/nor_gl/ao/arm."""
    wanted = {"diff": ("diffuse", "diff"), "rough": ("rough",), "nor_gl": ("nor_gl",), "ao": ("ao",), "arm": ("arm",)}
    out = {}
    for key, rec in files.items():
        k = key.lower()
        role = next((r for r, names in wanted.items() if k in names), None)
        if not role or not isinstance(rec, dict):
            continue
        res = rec.get("1k") or rec.get("2k")
        if not isinstance(res, dict):
            continue
        fmt = res.get("jpg") or res.get("png")
        if isinstance(fmt, dict) and fmt.get("url"):
            out[role] = fmt
    return out


def gltf_record(files: dict) -> dict | None:
    g = files.get("gltf")
    if not isinstance(g, dict):
        return None
    res = g.get("1k") or g.get("2k")
    if not isinstance(res, dict):
        return None
    rec = res.get("gltf")
    return rec if isinstance(rec, dict) and rec.get("url") else None


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    prov: list = []
    report = {"textures": {}, "models": {}, "missing": [], "discovered": {}}

    tex_list = json.loads(get("https://api.polyhaven.com/assets?t=textures"))
    mdl_list = json.loads(get("https://api.polyhaven.com/assets?t=models"))
    print(f"Poly Haven: {len(tex_list)} textures, {len(mdl_list)} models listed")

    chosen_tex = list(TEXTURES)
    for label, pat in TEXTURE_PATTERNS.items():
        hits = sorted(i for i, v in tex_list.items() if re.search(pat, (v.get("name", "") + " " + i).lower()))
        report["discovered"][f"texture:{label}"] = hits[:30]
        if hits:
            chosen_tex.append(hits[0])

    for tid in chosen_tex:
        if tid not in tex_list:
            report["missing"].append(f"texture {tid}")
            print(f"MISSING texture {tid}")
            continue
        info = tex_list[tid]
        files = json.loads(get(f"https://api.polyhaven.com/files/{tid}"))
        maps = texture_maps(files)
        if "diff" not in maps:
            report["missing"].append(f"texture {tid} (no diffuse; maybe vault-locked)")
            print(f"SKIP texture {tid}: maps {sorted(maps)} keys {sorted(files)[:12]}")
            continue
        meta = {"asset": tid, "name": info.get("name"), "type": "texture", "authors": authors(info), "license": "CC0"}
        for role, rec in maps.items():
            ext = urlparse(rec["url"]).path.rsplit(".", 1)[-1]
            save(f"textures/{tid}/{role}.{ext}", get(rec["url"]), rec.get("md5"), {**meta, "role": role, "url": rec["url"]}, prov)
        report["textures"][tid] = {"name": info.get("name"), "maps": sorted(maps), "dimensions_mm": info.get("dimensions")}
        print(f"texture {tid}: {sorted(maps)}")

    by_name = {v.get("name", "").strip().lower(): k for k, v in mdl_list.items()}
    for name in MODELS_REQUIRED + MODELS_OPTIONAL:
        mid = by_name.get(name.lower())
        if not mid:
            close = [v.get("name") for k, v in mdl_list.items() if name.split()[0].lower() in v.get("name", "").lower()][:8]
            report["missing"].append(f"model '{name}' (similar: {close})")
            print(f"MISSING model '{name}', similar: {close}")
            if name in MODELS_REQUIRED:
                report["required_missing"] = True
            continue
        info = mdl_list[mid]
        files = json.loads(get(f"https://api.polyhaven.com/files/{mid}"))
        rec = gltf_record(files)
        if not rec:
            report["missing"].append(f"model {mid} (no 1k glTF)")
            continue
        meta = {"asset": mid, "name": info.get("name"), "type": "model", "authors": authors(info), "license": "CC0"}
        gname = Path(urlparse(rec["url"]).path).name
        save(f"models/{mid}/{gname}", get(rec["url"]), rec.get("md5"), {**meta, "url": rec["url"]}, prov)
        for rel, inc in (rec.get("include") or {}).items():
            if isinstance(inc, dict) and inc.get("url"):
                save(f"models/{mid}/{rel}", get(inc["url"]), inc.get("md5"), {**meta, "url": inc["url"]}, prov)
        report["models"][mid] = {"name": info.get("name"), "polycount": info.get("polycount"),
                                 "dimensions_mm": info.get("dimensions"), "gltf": gname,
                                 "includes": sorted((rec.get("include") or {}).keys())}
        print(f"model {mid} ({info.get('name')}): {gname} + {len(rec.get('include') or {})} files")

    report["discovered"]["models"] = sorted(f"{k} | {v.get('name')}" for k, v in mdl_list.items()
                                            if re.search(DISCOVER, (v.get("name", "") + " " + k).lower()))
    (OUT / "provenance.json").write_text(json.dumps({"provider": "Poly Haven (polyhaven.com)", "license": "CC0",
                                                    "fetched": time.strftime("%Y-%m-%d"), "files": prov}, indent=1))
    (OUT / "report.json").write_text(json.dumps(report, indent=1))
    total = sum(p["bytes"] for p in prov)
    print(f"done: {len(prov)} files, {total / 1e6:.1f} MB; missing: {report['missing']}")
    if report.get("required_missing"):
        sys.exit(1)


if __name__ == "__main__":
    main()
