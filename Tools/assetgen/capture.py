"""
capture - genuinely captured (photogrammetry) destinations for Spatial Mode.

A capture is a textured mesh reconstructed from photographs.  Its texture IS
the photographs (re-projected), so it renders unlit: no lighting model is
applied on top of the light that was in the scene when it was photographed.

Conversion (offline, deterministic):
  1. glTF scene graph flattened to world space (Sketchfab's root transform
     included: for Woolwich Alley this is the author's metric calibration,
     checked against a 2.0 m door and 1.0 m wheelie bins).
  2. Portal space: the opening is placed at a chosen point at the alley
     entrance, looking down the alley (portal -z), the captured ground 2 cm
     below the room floor.
  3. Everything on the room side of the occluder plane is removed; triangles
     straddling it are clamped onto the plane, so the threshold has no gap.
  4. A low-tier LOD by UV-aware vertex clustering (vertices only merge when
     both position and texture coordinate are close, so seams don't smear).
  5. A gradient sky dome closes holes in the reconstruction (otherwise the
     live room would show through them) and depth-placed rain layers.

Destination-space apertures for floor / ceiling portals are recorded in the
manifest (PortalCore DestinationScene).
"""
from __future__ import annotations

import io
import json
import math
import os

import numpy as np
from PIL import Image

import glbscene
from meshkit import MeshBuilder

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OCCLUDER_Z = -0.125
KEEP_Z = OCCLUDER_Z - 0.004

CAPTURES = {
    "woolwich": dict(
        glb="Vendor/captures/woolwich_alley/woolwich_alley.glb",
        provenance="Vendor/captures/woolwich_alley/provenance.json",
        # entrance point (glTF world, metres) and viewing direction (+z in the capture)
        entrance=(-1.0, -11.3), forward=(0.0, 1.0), floorDrop=0.02,
        floorAperture=(0.0, 4.5, -8.0), ceilingAperture=(0.0, 2.4, -6.0),
        sky=dict(horizon=(0.78, 0.79, 0.81), zenith=(0.56, 0.62, 0.70)),
        lodCell=0.07, texturePx=1024,
        rain=[(-1.2, 3.0), (-2.8, 3.2), (-5.0, 3.4), (-8.5, 3.6), (-13.0, 4.0), (-19.0, 5.0)],
    ),
}


def _floor_height(P, N, x, z, radius=1.6):
    up = N[:, 1] > 0.85
    near = up & (np.hypot(P[:, 0] - x, P[:, 2] - z) < radius)
    assert near.sum() > 50, "no captured ground near the entrance"
    return float(np.median(P[near, 1]))


def _cluster(P, UV, I, cell, uvq=1 / 96):
    """Watertight vertex-clustering decimation (low tier).  Positions are
    clustered by grid cell only, so every vertex in a cell lands on the same
    point (no cracks); vertices on different sides of a texture seam stay
    separate vertices with their own averaged UVs (no smearing)."""
    pc = np.floor(P / cell).astype(np.int64)
    _, pinv, pcnt = np.unique(pc, axis=0, return_inverse=True, return_counts=True)
    pinv = pinv.reshape(-1)
    Prep = np.zeros((len(pcnt), 3)); np.add.at(Prep, pinv, P); Prep /= pcnt[:, None]
    key = np.concatenate([pinv[:, None], np.floor(UV / uvq).astype(np.int64)], 1)
    _, inv, cnt = np.unique(key, axis=0, return_inverse=True, return_counts=True)
    inv = inv.reshape(-1)
    n = len(cnt)
    UVn = np.zeros((n, 2)); np.add.at(UVn, inv, UV); UVn /= cnt[:, None]
    Pn = np.zeros((n, 3)); Pn[inv] = Prep[pinv]
    tri = inv[I.reshape(-1, 3)]
    ptri = pinv[I.reshape(-1, 3)]
    tri = tri[(ptri[:, 0] != ptri[:, 1]) & (ptri[:, 1] != ptri[:, 2]) & (ptri[:, 0] != ptri[:, 2])]
    _, first = np.unique(np.sort(tri, 1), axis=0, return_index=True)   # drop duplicates, keep winding
    tri = tri[np.sort(first)]
    used = np.unique(tri)
    remap = np.full(n, -1); remap[used] = np.arange(len(used))
    return Pn[used], UVn[used], remap[tri].reshape(-1)


def _normals(P, I):
    tri = I.reshape(-1, 3)
    fn = np.cross(P[tri[:, 1]] - P[tri[:, 0]], P[tri[:, 2]] - P[tri[:, 0]])
    N = np.zeros_like(P)
    for k in range(3):
        np.add.at(N, tri[:, k], fn)
    N /= np.linalg.norm(N, axis=1, keepdims=True) + 1e-12
    N[np.linalg.norm(N, axis=1) < 0.5] = (0, 1, 0)
    return N


def build(name, save_jpg, out_dir):
    c = CAPTURES[name]
    g, prims, texs, mats = glbscene.load(os.path.join(ROOT, c["glb"]))
    assert len(texs) == 1, "multi-texture captures: extend the material mapping"
    P = np.concatenate([p["pos"] for p in prims])
    N0 = np.concatenate([p["nrm"] for p in prims])
    UV = np.concatenate([p["uv"] for p in prims]).copy()
    offs = np.cumsum([0] + [len(p["pos"]) for p in prims])
    I = np.concatenate([p["idx"] + o for p, o in zip(prims, offs[:-1])])
    ex, ez = c["entrance"]
    fy = _floor_height(P, N0, ex, ez)
    # portal space: forward (capture) -> portal -z, up stays up
    fx, fz = c["forward"]
    f = np.array([fx, 0.0, fz]) / math.hypot(fx, fz)
    right = np.cross(f, [0, 1, 0])                 # portal +x
    R = np.stack([right, [0, 1, 0], -f])           # rows: portal x, y, z in capture coords
    origin = np.array([ex, fy + c["floorDrop"], ez])
    Q = (P - origin) @ R.T
    assert np.linalg.det(R) > 0
    # crop the room side of the occluder plane; clamp straddling triangles onto it
    tri = I.reshape(-1, 3)
    behind = Q[:, 2] < KEEP_Z
    keep = behind[tri].any(1)
    tri = tri[keep]
    Q[:, 2] = np.minimum(Q[:, 2], KEEP_Z)
    used = np.unique(tri)
    remap = np.full(len(Q), -1); remap[used] = np.arange(len(used))
    Q, UV = Q[used], UV[used]
    I = remap[tri].reshape(-1)
    UV[:, 1] = 1.0 - UV[:, 1]                      # glTF top-left -> USD bottom-left
    N = _normals(Q, I)
    mat = f"capture_{name}"
    hi = MeshBuilder(); hi.chunk = "capture"
    hi.tri_batch(mat, Q, N, UV, I)
    Pl, UVl, Il = _cluster(Q, UV, I, c["lodCell"])
    lo = MeshBuilder(); lo.chunk = "capture"
    lo.tri_batch(mat, Pl, _normals(Pl, Il), UVl, Il)
    # sky dome (destination space), inward, closes reconstruction holes
    sky = MeshBuilder(); sky.chunk = "sky"
    Rr, na, ne = 90.0, 48, 20
    Ps, Ns, Us, Is = [], [], [], []
    for j in range(ne + 1):
        el = math.radians(-20 + 110 * j / ne)
        for i in range(na + 1):
            az = 2 * math.pi * i / na
            d = np.array([math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el)])
            Ps.append(d * Rr); Ns.append(-d); Us.append((i / na, j / ne))
    for j in range(ne):
        for i in range(na):
            a = j * (na + 1) + i; b = a + na + 1
            Is += [a, a + 1, b + 1, a, b + 1, b]
    # wall portals: only the part behind the aperture plane (the occluder
    # hides nothing on the room side); floor/ceiling portals: the full dome,
    # trimmed by the shader clip instead (chunk "skyfull", enabled per mode)
    Ps = np.array(Ps); Is = np.array(Is).reshape(-1, 3)
    full = MeshBuilder(); full.chunk = "skyfull"
    full.tri_batch(f"{mat}_sky", Ps, Ns, Us, Is.reshape(-1))
    full._fix_winding_last(f"{mat}_sky")
    back = Is[(Ps[Is][:, :, 2] < KEEP_Z).any(1)]
    Pc = Ps.copy(); Pc[:, 2] = np.minimum(Pc[:, 2], KEEP_Z)
    sky.tri_batch(f"{mat}_sky", Pc, Ns, Us, back.reshape(-1))
    sky._fix_winding_last(f"{mat}_sky")
    # rain layers: vertical sheets across the alley at increasing depth
    rain = MeshBuilder(); rain.chunk = "rain"
    for k, (z, w) in enumerate(c["rain"]):
        rain.quad(f"{mat}_rain", (-w / 2, -0.02, z), (w, 0, 0), (0, 7.0, 0),
                  uv0=(z * 0.37, 0), uv1=(z * 0.37 + w / 1.6, 7.0 / 6.0))
    # texture
    img = texs[0]
    if img.size[0] > c["texturePx"]:
        img = img.resize((c["texturePx"], c["texturePx"]), Image.Resampling.LANCZOS)
    save_jpg(f"{mat}_albedo", img, "color")
    sizes = {}
    for key, mb in ((f"{mat}", hi), (f"{mat}_low", lo)):
        mb.merge(sky)
        mb.merge(full)
        mb.merge(rain)
        sizes[key] = mb
    stats = dict(trianglesHigh=int(len(I) // 3), trianglesLow=int(len(Il) // 3), verticesHigh=int(len(Q)),
                 verticesLow=int(len(Pl)), floorY=round(fy, 3), extentMin=Q.min(0).round(2).tolist(),
                 extentMax=Q.max(0).round(2).tolist())
    prov = json.load(open(os.path.join(ROOT, c["provenance"])))
    dest = dict(kind="capture", title=prov["title"], mesh=f"{mat}", meshLow=f"{mat}_low",
                floorAperture=list(c["floorAperture"]), ceilingAperture=list(c["ceilingAperture"]),
                credit=f"“{prov['title']}” by {prov['author']}, {prov['licence']} ({prov['source']})",
                licence=prov["licence"], source=prov["source"], location=prov["location"], stats=stats)
    materials = {
        mat: dict(shader="captureUnlit", textures=dict(baseColor=f"{mat}_albedo", custom="neutral_packed"),
                  tint=[1, 1, 1], params=[1.0, 1.0, 0.0, 1.0], cull="none"),
        f"{mat}_sky": dict(shader="captureSky", textures=dict(baseColor="white", custom="neutral_packed"),
                           tint=list(c["sky"]["zenith"]), params=[*c["sky"]["horizon"], 1.0]),
        f"{mat}_rain": dict(shader="captureRain", textures=dict(baseColor="rain", custom="neutral_packed"),
                            tint=[0.86, 0.88, 0.92], params=[5.0, 0.0, 0.34, 1.0], blend="transparent", cull="none"),
    }
    return sizes, dest, materials
