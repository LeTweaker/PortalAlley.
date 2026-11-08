"""
props - scanned CC0 props (Poly Haven "Hidden Alley" family and friends)
converted from glTF 2.0 into MeshBuilder geometry + alley materials.

Sources: Vendor/polyhaven/models/<asset>/<asset>_1k.gltf (+ .bin, textures).
Provenance and checksums: Vendor/polyhaven/provenance.json.

Conversion
  * glTF is Y-up, metres, front = +Z: the same axes as a Facade's local
    frame (s along the wall, h up, d out of the wall), so a prop whose back
    sits at d = 0 faces out of the wall.
  * Node TRS is applied; a kit item lists the nodes it uses and the variant
    offset to remove (Poly Haven lays variants out side by side).
  * Materials become `alleyLit` (or `alleyLitCutout` for alpha-masked parts)
    with the scan's albedo, ARM (ao, rough, metal) -> packed (rough, ao, wet)
    and OpenGL normal map.  Metal pixels are darkened slightly in albedo and
    get a smoother packed roughness, which is how the unlit alley shading
    approximates metallic response.
"""
from __future__ import annotations

import json
import math
import os

import numpy as np
from PIL import Image

from meshkit import MeshBuilder

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(ROOT, "Vendor", "polyhaven", "models")
TEX_PX = 512          # albedo (props are small on screen)
AUX_PX = 256          # packed + normal maps

# kit id -> asset, node names, offset removed (variant layout), primitives skipped
KIT = {
    "aircon":        dict(asset="exterior_aircon_unit", nodes=["exterior_aircon_unit"], offset=(-0.5, 0, 0)),
    "aircon_rusted": dict(asset="exterior_aircon_unit", nodes=["exterior_aircon_unit_rusted"], offset=(0.5, 0, 0)),
    "trash_can":     dict(asset="metal_trash_can", nodes=["metal_trash_can", "metal_trash_can_handle_left", "metal_trash_can_handle_right"], offset=(0.5, 0, 0)),
    "trash_can_rust": dict(asset="metal_trash_can", nodes=["metal_trash_can_rust", "metal_trash_can_rust_handle_left", "metal_trash_can_rust_handle_right", "metal_trash_can_rust_lid"], offset=(-0.5, 0, 0)),
    "propane":       dict(asset="propane_tank", nodes=["propane_tank"]),
    "utility_box_1": dict(asset="utility_box_01", nodes=["utility_box_01_box"]),
    "utility_box_2": dict(asset="utility_box_02", nodes=["utility_box_02"]),
    "security_light": dict(asset="security_light", nodes=["security_light"]),
    "fluorescent":   dict(asset="mounted_fluorescent_lights", nodes=["mounted_fluorescent_lights_d"]),
    "shutter_window": dict(asset="rollershutter_window_03", nodes=["rollershutter_window_03"]),
    "camera":        dict(asset="security_camera_01", nodes=["security_camera_01"], skip_mats=["security_camera_01_glass"]),
    "duct_triple":   dict(asset="modular_airduct_circular_01", nodes=["modular_airduct_circular_triple"], offset=(1.9, 0, 0)),
    "duct_double":   dict(asset="modular_airduct_circular_01", nodes=["modular_airduct_circular_double"], offset=(1.3, 0, 0)),
    "duct_bend":     dict(asset="modular_airduct_circular_01", nodes=["modular_airduct_circular_bend_quater"], offset=(-0.7, 0, 0.7)),
    "duct_fan":      dict(asset="modular_airduct_circular_01", nodes=["modular_airduct_circular_fan"], offset=(0.7, 0, 0.7)),
    "duct_brace":    dict(asset="modular_airduct_circular_01", nodes=["modular_airduct_circular_brace"], offset=(0.7, 0, 0.3)),
}

# glTF material name -> alley material id + shading tweaks
#   tint, wet (rain film strength), spec, emissive gain (if a light)
MAT_TWEAKS = {
    "mounted_fluorescent_lights_glass": dict(emissive=1.9, tint=(0.86, 0.95, 1.0)),
    "security_light_bulb": dict(emissive=2.2, tint=(1.0, 0.86, 0.66)),
}
SKIP_GLOBAL = {"security_light_glass"}


def _q2m(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def _node_matrix(n):
    M = np.eye(4)
    if "matrix" in n:
        return np.array(n["matrix"], np.float64).reshape(4, 4).T
    R = _q2m(n.get("rotation", (0, 0, 0, 1)))
    S = np.diag(n.get("scale", (1, 1, 1)))
    M[:3, :3] = R @ S
    M[:3, 3] = n.get("translation", (0, 0, 0))
    return M


class GLTF:
    def __init__(self, asset):
        self.dir = os.path.join(MODELS, asset)
        self.g = json.load(open(os.path.join(self.dir, f"{asset}_1k.gltf")))
        self.bins = [open(os.path.join(self.dir, b["uri"]), "rb").read() for b in self.g["buffers"]]

    def acc(self, i):
        a = self.g["accessors"][i]
        bv = self.g["bufferViews"][a["bufferView"]]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
        stride = bv.get("byteStride", 0)
        assert stride in (0, n * np.dtype(dt).itemsize), "interleaved buffers not supported"
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        arr = np.frombuffer(self.bins[bv["buffer"]], dt, a["count"] * n, off)
        return arr.reshape(a["count"], n) if n > 1 else arr

    def image_path(self, tex_info):
        if not tex_info:
            return None
        src = self.g["textures"][tex_info["index"]]["source"]
        return os.path.join(self.dir, self.g["images"][src]["uri"])

    def node(self, name):
        for n in self.g["nodes"]:
            if n.get("name") == name:
                return n
        raise KeyError(f"node {name} not in {self.dir}")


def mat_id(gltf_name):
    return "prop_" + gltf_name


_cache: dict[str, MeshBuilder] = {}


def kit(item: str) -> MeshBuilder:
    """Geometry of one kit item in its own frame (cached)."""
    if item in _cache:
        return _cache[item]
    spec = KIT[item]
    G = GLTF(spec["asset"])
    mb = MeshBuilder()
    off = np.array(spec.get("offset", (0, 0, 0)), np.float64)
    skip = set(spec.get("skip_mats", [])) | SKIP_GLOBAL
    for name in spec["nodes"]:
        n = G.node(name)
        M = _node_matrix(n)
        M[:3, 3] -= off
        R = M[:3, :3]
        Rn = np.linalg.inv(R).T
        for pr in G.g["meshes"][n["mesh"]]["primitives"]:
            mname = G.g["materials"][pr["material"]]["name"]
            if mname in skip:
                continue
            P = G.acc(pr["attributes"]["POSITION"]).astype(np.float64)
            N = G.acc(pr["attributes"]["NORMAL"]).astype(np.float64)
            UV = G.acc(pr["attributes"]["TEXCOORD_0"]).astype(np.float64).copy()
            I = G.acc(pr["indices"]).astype(np.int64)
            P = P @ R.T + M[:3, 3]
            N = N @ Rn.T
            N /= np.linalg.norm(N, axis=1, keepdims=True) + 1e-12
            # glTF uv origin is top-left; pipeline uses USD (bottom-left)
            UV[:, 1] = 1.0 - UV[:, 1]
            mb.tri_batch(mat_id(mname), P, N, UV, I)
    # glTF winding is CCW like ours; verify against the normals
    for key, part in mb.parts.items():
        P, N, _, I = part.arrays()
        tri = I.reshape(-1, 3)
        fn = np.cross(P[tri[:, 1]] - P[tri[:, 0]], P[tri[:, 2]] - P[tri[:, 0]])
        ok = (np.einsum("ij,ij->i", fn, N[tri].sum(1)) >= 0).mean()
        assert ok > 0.97, f"{item}/{key}: winding agrees with normals for only {ok:.2%}"
    _cache[item] = mb
    return mb


def bounds(item):
    lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
    for p in kit(item).parts.values():
        P = p.arrays()[0]
        lo, hi = np.minimum(lo, P.min(0)), np.maximum(hi, P.max(0))
    return lo, hi


def place(dst: MeshBuilder, item, pos, rot_y=0.0, rot_x=0.0, scale=1.0, anchor="back"):
    """Merge a kit item into dst.  The anchor shift is applied in the item's
    own frame before rotation: 'back' puts its min z (wall side) on pos.z,
    'bottom' its min y on pos.y, 'center' centres it, 'none' keeps its origin."""
    lo, hi = bounds(item)
    shift = np.zeros(3)
    if anchor == "back":
        shift[2] = -lo[2]
    elif anchor == "bottom":
        shift[1] = -lo[1]
    elif anchor == "back_bottom":
        shift[1], shift[2] = -lo[1], -lo[2]
    elif anchor == "top_back":
        shift[1], shift[2] = -hi[1], -lo[2]
    elif anchor == "center":
        shift = -(lo + hi) / 2
    elif anchor != "none":
        raise ValueError(anchor)
    M0 = np.eye(4)
    M0[:3, 3] = shift
    S = np.eye(4) * scale
    S[3, 3] = 1
    a, b = math.radians(rot_y), math.radians(rot_x)
    Ry = np.array([[math.cos(a), 0, math.sin(a), 0], [0, 1, 0, 0], [-math.sin(a), 0, math.cos(a), 0], [0, 0, 0, 1]])
    Rx = np.array([[1, 0, 0, 0], [0, math.cos(b), -math.sin(b), 0], [0, math.sin(b), math.cos(b), 0], [0, 0, 0, 1]])
    T = np.eye(4)
    T[:3, 3] = pos
    dst.merge(kit(item), T @ Ry @ Rx @ S @ M0)


# ---------------------------------------------------------------- textures
MATS: dict[str, dict] = {}


def _img(path, px, mode="RGB"):
    im = Image.open(path)
    im = im.convert(mode)
    return im.resize((px, px), Image.Resampling.LANCZOS) if im.size != (px, px) else im


def build_textures(save_png, save_jpg):
    """Convert every material used by the kit.  Returns stats."""
    used = {}
    for item, spec in KIT.items():
        G = GLTF(spec["asset"])
        skip = set(spec.get("skip_mats", [])) | SKIP_GLOBAL
        for name in spec["nodes"]:
            for pr in G.g["meshes"][G.node(name)["mesh"]]["primitives"]:
                m = G.g["materials"][pr["material"]]
                if m["name"] in skip or m["name"] in used:
                    continue
                used[m["name"]] = (G, m)
    stats = {}
    for name, (G, m) in sorted(used.items()):
        pbr = m.get("pbrMetallicRoughness", {})
        base = G.image_path(pbr.get("baseColorTexture"))
        arm_p = G.image_path(pbr.get("metallicRoughnessTexture"))
        nrm_p = G.image_path(m.get("normalTexture"))
        key = mat_id(name)
        cutout = m.get("alphaMode") in ("BLEND", "MASK") and base and "opacity" in os.path.basename(base)
        arm = np.asarray(_img(arm_p, TEX_PX), np.float32) / 255.0 if arm_p else np.ones((TEX_PX, TEX_PX, 3), np.float32) * (1, 0.6, 0)
        ao, rough, metal = arm[..., 0], arm[..., 1], arm[..., 2]
        arm_small = np.asarray(_img(arm_p, AUX_PX), np.float32) / 255.0 if arm_p else np.ones((AUX_PX, AUX_PX, 3), np.float32) * (1, 0.6, 0)
        if cutout:
            # Poly Haven exports the grille's opacity mask as its base colour:
            # dark painted steel mesh, alpha from the mask.
            alpha = np.asarray(_img(base, TEX_PX, "L"), np.float32) / 255.0
            rgb = np.ones((TEX_PX, TEX_PX, 3), np.float32) * np.array([0.10, 0.10, 0.11])
        else:
            rgb = np.asarray(_img(base, TEX_PX), np.float32) / 255.0
            alpha = None
        # metallic approximation for the unlit alley model: metals reflect,
        # they do not diffuse; darken their albedo and smooth them a little
        rgb = rgb * (1.0 - 0.45 * metal[..., None])
        ao_s, rough_s, metal_s = arm_small[..., 0], arm_small[..., 1], arm_small[..., 2]
        rough_s = np.clip(rough_s * (1.0 - 0.25 * metal_s), 0.04, 1.0)
        wet = (80 + (1 - rough_s) * 255 * 0.6) / 255.0
        packed = np.stack([rough_s, ao_s, wet], -1)
        if cutout:
            rgba = np.concatenate([rgb, alpha[..., None]], -1)
            save_png(f"{key}_albedo", Image.fromarray((rgba * 255 + 0.5).clip(0, 255).astype(np.uint8), "RGBA"), "color")
        else:
            save_jpg(f"{key}_albedo", Image.fromarray((rgb * 255 + 0.5).clip(0, 255).astype(np.uint8)), "color")
        save_png(f"{key}_packed", Image.fromarray((packed * 255 + 0.5).clip(0, 255).astype(np.uint8)), "raw")
        if nrm_p:
            save_jpg(f"{key}_normal", _img(nrm_p, AUX_PX), "raw")
        MATS[key] = dict(cutout=bool(cutout), normal=bool(nrm_p), src=name, tweak=MAT_TWEAKS.get(name, {}))
        stats[key] = dict(source=os.path.relpath(base or "", ROOT), cutout=bool(cutout),
                          metalFraction=round(float(metal.mean()), 3))
    return stats


def materials(lit, exposure):
    """Material definitions for every converted prop material."""
    out = {}
    for key, info in MATS.items():
        tw = info["tweak"]
        if "emissive" in tw:
            out[key] = dict(shader="alleyEmissive", textures=dict(baseColor=f"{key}_albedo", custom="neutral_packed"),
                            tint=list(tw["tint"]), params=[tw["emissive"], 0.0, 0.0, exposure])
            continue
        m = lit(f"{key}_albedo", f"{key}_packed", tw.get("tint", (1, 1, 1)), wet=0.5, spec=0.8,
                normal=f"{key}_normal" if info["normal"] else None, uvmul=1.0)
        if info["cutout"]:
            m["shader"] = "alleyLitCutout"
            m["cull"] = "none"
        out[key] = m
    return out
