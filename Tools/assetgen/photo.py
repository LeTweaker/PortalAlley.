"""
photo - photographed (CC0, Poly Haven) surface families for the alley.

Source scans live in Vendor/polyhaven/textures/<asset>/{diff,arm,nor_gl}.jpg.
They were downloaded once by Tools/fetch_cc0_assets.py (checksum verified,
provenance in Vendor/polyhaven/provenance.json) and are committed, so the
asset build is fully offline and reproducible.

Each family produces three runtime textures:
    <family>_albedo  (sRGB JPEG)   delit colour, optionally luminance-normalised
    <family>_packed  (linear PNG)  r roughness, g ambient occlusion, b wet mask
    <family>_normal  (linear JPEG) OpenGL tangent-space normal

Luminance normalisation rescales linear RGB so the average luminance hits a
target while keeping the photographed chroma and variation; the per-building
colour then comes from the material tint (one scan, several painted facades).
"""
from __future__ import annotations

import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
VENDOR = os.path.join(ROOT, "Vendor", "polyhaven", "textures")

# family: source asset, real-world tile size (m), albedo px, normal px,
#         target linear luminance (None = keep), rotate (deg CCW), notes
FAMILIES = {
    "tile":       dict(src="concrete_tile_facade",  size=2.09, alb=1024, nrm=1024, lum=0.20, rot=0),
    "concrete":   dict(src="concrete_wall_008",     size=2.71, alb=1024, nrm=1024, lum=None, rot=0),
    "concrete2":  dict(src="concrete_layers",       size=1.55, alb=1024, nrm=512,  lum=None, rot=0),
    "plaster":    dict(src="painted_concrete_02",   size=4.00, alb=1024, nrm=512,  lum=0.30, rot=0),
    "redplaster": dict(src="red_plaster_weathered", size=2.00, alb=1024, nrm=512,  lum=None, rot=0),
    "shutter":    dict(src="corrugated_iron",       size=2.00, alb=1024, nrm=512,  lum=0.30, rot=90),
    "corrugated": dict(src="corrugated_iron",       size=2.00, alb=512,  nrm=512,  lum=0.22, rot=0),
    "wood":       dict(src="black_painted_planks",  size=2.00, alb=1024, nrm=512,  lum=0.045, rot=0),
    "asphalt":    dict(src="asphalt_02",            size=3.00, alb=1024, nrm=1024, lum=None, rot=0),
    "pavement":   dict(src="garage_floor",          size=1.89, alb=1024, nrm=512,  lum=None, rot=0),
    "brick":      dict(src="mixed_brick_wall",      size=1.70, alb=1024, nrm=512,  lum=None, rot=0),
    "rust":       dict(src="rust_coarse_01",        size=2.20, alb=512,  nrm=512,  lum=None, rot=0),
}
PACKED_PX = 512


def _lin(srgb):
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


def _srgb(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)


def _load(asset, role, px, rot):
    im = Image.open(os.path.join(VENDOR, asset, f"{role}.jpg")).convert("RGB")
    if rot:
        im = im.rotate(rot, expand=True)
    if im.size != (px, px):
        im = im.resize((px, px), Image.Resampling.LANCZOS)
    return im


def _rotate_normal(img, rot):
    """Image content rotated by `rot` deg CCW: rotate the tangent-space xy too."""
    if not rot:
        return img
    a = np.asarray(img, np.float32) / 255.0 * 2 - 1
    k = (rot // 90) % 4
    x, y = a[..., 0].copy(), a[..., 1].copy()
    for _ in range(k):
        x, y = -y, x
    a[..., 0], a[..., 1] = x, y
    return Image.fromarray(((a * 0.5 + 0.5) * 255 + 0.5).clip(0, 255).astype(np.uint8))


def build(save_png, save_jpg):
    """save_png(name, img, semantic) / save_jpg(name, img, semantic) register
    files with the manifest.  Returns {family: stats}."""
    stats = {}
    for fam, f in FAMILIES.items():
        src, rot = f["src"], f["rot"]
        d = np.asarray(_load(src, "diff", f["alb"], rot), np.float32) / 255.0
        lin = _lin(d)
        lum = float((lin @ np.array([0.2126, 0.7152, 0.0722])).mean())
        if f["lum"] is not None:
            lin = lin * (f["lum"] / max(lum, 1e-4))
        alb = Image.fromarray((_srgb(lin) * 255 + 0.5).astype(np.uint8))
        save_jpg(f"{fam}_albedo", alb, "color")

        arm = np.asarray(_load(src, "arm", PACKED_PX, rot), np.float32) / 255.0   # r ao, g rough, b metal
        rough, ao = arm[..., 1], arm[..., 0]
        # wet mask: smoother pores hold water films longer (as in v1.2)
        wet = (80 + (1 - rough) * 255 * 0.6) / 255.0
        packed = np.stack([rough, ao, wet], -1)
        save_png(f"{fam}_packed", Image.fromarray((packed * 255 + 0.5).clip(0, 255).astype(np.uint8)), "raw")

        # pixels rotated by _load, tangent-space vectors rotated to match
        nrm = _rotate_normal(_load(src, "nor_gl", f["nrm"], rot), rot)
        save_jpg(f"{fam}_normal", nrm, "raw")
        stats[fam] = dict(source=src, realSizeM=f["size"], sourceLinearLuminance=round(lum, 4),
                          targetLuminance=f["lum"], rotation=rot)
    return stats


def uv_mul(family, authored_scale):
    """UV multiplier so a texture authored at `authored_scale` metres per tile
    shows at its photographed real-world size."""
    return authored_scale / FAMILIES[family]["size"]
