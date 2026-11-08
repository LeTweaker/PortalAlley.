"""Import a bounded set of CC0 photographed surfaces for the v1.2 build.

Network work runs only at build time; the installed app stays fully offline.
API usage credit is visible on the start card. Downloads are checksum-checked
against the provider metadata and recorded in the generated provenance report.
"""
from __future__ import annotations

import hashlib
import io
import json
import re
from pathlib import Path
import time
import urllib.request
from urllib.parse import urlparse

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "App/Resources/Portal"
CACHE = ROOT / ".material-cache"
USER_AGENT = "PortalAlley-PhotographicMaterials/1.2 (build-time CC0 importer)"
SOURCES = {
    "asphalt": "asphalt_02",
    "concrete": "concrete_floor_01",
    "plaster": "concrete_wall_003",
}


def request(url: str) -> bytes:
    host = urlparse(url).hostname or ""
    if not (host == "api.polyhaven.com" or host.endswith(".polyhaven.org") or host.endswith(".polyhaven.com")):
        raise ValueError(f"Unexpected material host: {host}")
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=45) as response:
                data = response.read(25_000_001)
            if len(data) > 25_000_000:
                raise ValueError("Texture exceeded the build download budget")
            return data
        except Exception:
            if attempt == 2:
                raise
            time.sleep(attempt + 1)
    raise AssertionError("unreachable")


def descriptor(files: dict, role: str, required: bool = True) -> dict | None:
    # Resolve concrete file records rather than assuming a fixed API nesting.
    # Some assets call the map "Diffuse" and some expose texture dependencies
    # under their model exports. Keep the download bounded to 1k/2k images.
    aliases = {"diff": ("diff", "diffuse", "albedo"), "rough": ("rough", "roughness"),
               "nor_gl": ("nor_gl", "normal_gl", "normal"), "ao": ("ao", "ambient_occlusion")}[role]
    candidates = []
    def walk(node, path=()):
        if isinstance(node, dict):
            url = str(node.get("url", ""))
            lower = url.lower()
            joined = "/".join(path).lower()
            match = any(re.search(r"[_/]" + re.escape(alias) + r"[_/.]", lower)
                        or alias in [part.lower() for part in path] for alias in aliases)
            resolution = 1 if re.search(r"(?:/|_)1k(?:/|_|\.)", lower) or "1k" in joined.split("/") else (2 if re.search(r"(?:/|_)2k(?:/|_|\.)", lower) or "2k" in joined.split("/") else 0)
            fmt = urlparse(url).path.rsplit(".", 1)[-1].lower()
            if url and match and resolution and fmt in ("png", "jpg", "jpeg"):
                candidates.append((resolution, 0 if fmt == "png" else 1, node))
            for key, value in node.items():
                if isinstance(value, (dict, list)):
                    walk(value, path + (str(key),))
        elif isinstance(node, list):
            for value in node:
                walk(value, path)
    walk(files)
    if candidates:
        return sorted(candidates, key=lambda x: x[:2])[0][2]
    if required:
        raise ValueError(f"Provider has no bounded {role} image; keys: {list(files)}; metadata sample: {json.dumps(files)[:1800]}")
    return None


def load_image(asset: str, role: str, desc: dict, report: list) -> Image.Image:
    CACHE.mkdir(exist_ok=True)
    expected = desc.get("md5")
    if not expected or len(expected) != 32:
        raise ValueError(f"Missing provider checksum: {asset}/{role}")
    target = CACHE / f"{asset}-{role}-{expected}"
    raw = target.read_bytes() if target.is_file() else request(desc["url"])
    if hashlib.md5(raw).hexdigest() != expected:
        raise ValueError(f"Checksum mismatch for {asset}/{role}")
    target.write_bytes(raw)
    im = Image.open(io.BytesIO(raw)).convert("RGB")
    if im.width < 512 or im.height < 512:
        raise ValueError(f"Unexpected texture resolution: {asset}/{role}")
    im = im.resize((1024, 1024), Image.Resampling.LANCZOS)
    report.append({"asset": asset, "role": role, "url": desc["url"], "md5": expected,
                   "sha256": hashlib.sha256(raw).hexdigest(), "license": "CC0"})
    return im


def pack(rough: Image.Image, ao: Image.Image) -> Image.Image:
    rough_l = rough.convert("L")
    # R = measured roughness, G = AO, B = wetness variation. Fine normal
    # detail is stored separately rather than pretending RGB is a normal map.
    wet = ImageChops.invert(rough_l).point(lambda x: 80 + int(x * 0.6))
    return Image.merge("RGB", (rough_l, ao.convert("L"), wet))


def main() -> None:
    manifest_path = BASE / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    report = []
    for family, asset in SOURCES.items():
        files = json.loads(request(f"https://api.polyhaven.com/files/{asset}"))
        diffuse = load_image(asset, "diff", descriptor(files, "diff"), report)
        rough = load_image(asset, "rough", descriptor(files, "rough"), report)
        normal = load_image(asset, "nor_gl", descriptor(files, "nor_gl"), report)
        ao_desc = descriptor(files, "ao", required=False)
        ao = load_image(asset, "ao", ao_desc, report) if ao_desc else Image.new("RGB", (1024, 1024), (255, 255, 255))
        diffuse.save(BASE / f"textures/{family}_albedo.png", optimize=True)
        pack(rough, ao).save(BASE / f"textures/{family}_packed.png", optimize=True)
        normal_name = f"{family}_normal"
        normal_file = f"textures/{normal_name}.png"
        normal.save(BASE / normal_file, optimize=True)
        manifest["textures"][normal_name] = {"file": normal_file, "semantic": "raw", "size": [1024, 1024]}
        for suffix in ("albedo", "packed"):
            manifest["textures"][f"{family}_{suffix}"]["size"] = [1024, 1024]
        for material in manifest["materials"].values():
            tex = material.get("textures", {})
            if tex.get("baseColor") == f"{family}_albedo":
                tex["normal"] = normal_name
                if family == "plaster":
                    # More restrained paint tints preserve the photographed wear.
                    tint = material.get("tint", [1, 1, 1])
                    material["tint"] = [0.65 + 0.35 * x for x in tint]
        print(f"Imported {asset}: photographic {family}, 1024px diffuse/roughness/AO/normal")
    for material in manifest["materials"].values():
        if material["shader"] == "alleyRain":
            material["params"][2] *= 0.58  # sparse lit streaks, not opaque sheets
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    # Validate exactly the resources the app is about to package.
    for name, desc in manifest["textures"].items():
        path = BASE / desc["file"]
        if not path.is_file():
            raise ValueError(f"Missing bundled texture: {name}")
        with Image.open(path) as im:
            im.verify()
    for material in manifest["materials"].values():
        for texture in material.get("textures", {}).values():
            if texture not in manifest["textures"]:
                raise ValueError(f"Unknown texture reference: {texture}")
    report_path = ROOT / "docs/generated_material_report.json"
    report_path.write_text(json.dumps({"credit": "Surface materials: Poly Haven", "license": "CC0",
                                       "sources": report}, indent=2) + "\n")
    print(f"Validated all bundled textures; provenance: {report_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
