"""
bake - per-vertex ambient occlusion and direct-light visibility for the alley.

Why per vertex: RealityKit CustomMaterial has no lightmap slot, but a mesh can
carry a second UV set (uv1) via LowLevelMesh (iOS 18+).  Large flat surfaces
are tessellated first so the baked shading has enough resolution for contact
shadows (ground around props, under awnings and eaves, wall/ground corners).

Encoding in uv1 (so "no bake data" is distinguishable from "fully occluded"):
    uv1.x = 3 - ao     in [2, 3]   (ao 1 = open)
    uv1.y = 1 - vis    in [0, 1]   (vis 1 = fully lit by the authored lights)
A mesh without uv1 reads (0, 0) in the shader, which then falls back to the
pre-1.3 height-based approximation (see AlleyShadingCore.h).
"""
from __future__ import annotations

import math
import os
import shutil
import subprocess
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

RECEIVER_SHADERS = {"alleyLit", "alleyLitCutout", "alleyGround"}
# materials that never block light: transparent layers, sky, decals, masked
# grilles, and the emitters themselves (bulbs, lanterns, sign faces, lit
# windows) - the authored point lights sit at or just in front of them
NON_OCCLUDING_SHADERS = {"alleyRain", "alleySteam", "alleySky", "alleyDecal", "alleyLitCutout",
                         "alleyEmissive", "alleyWindow"}
SKIP_CHUNKS = {"sky", "rain", "distant"}

AO_RAYS = 64
AO_DIST = 1.6
SHADOW_SAMPLES = 8


def _subdivide(P, N, UV, I, max_edge):
    """Uniform barycentric subdivision; n per triangle from its longest edge
    (identical for both triangles of a quad, so shared edges stay watertight)."""
    tri = I.reshape(-1, 3)
    A, B, C = P[tri[:, 0]], P[tri[:, 1]], P[tri[:, 2]]
    e = np.stack([np.linalg.norm(B - A, axis=1), np.linalg.norm(C - B, axis=1), np.linalg.norm(A - C, axis=1)], 1)
    emax = e.max(1)
    area = 0.5 * np.linalg.norm(np.cross(B - A, C - A), axis=1)
    alt = 2 * area / np.maximum(emax, 1e-9)
    n = np.ceil(emax / max_edge).astype(int)
    # slivers (pipes, cables, trims): only split along their length coarsely
    n = np.where(alt < 0.1, np.ceil(emax / 1.0).astype(int), n)
    n = np.clip(n, 1, 24)
    outP, outN, outUV, outI = [P], [N], [UV], []
    base = len(P)
    keep = tri[n == 1]
    outI.append(keep.reshape(-1))
    for k in np.unique(n[n > 1]):
        sel = tri[n == k]
        ij = [(i, j) for i in range(k + 1) for j in range(k + 1 - i)]
        lut = {p: q for q, p in enumerate(ij)}
        w = np.array([(1 - (i + j) / k, i / k, j / k) for i, j in ij])        # weights of A, B, C
        loc = []
        for i in range(k):
            for j in range(k - i):
                loc.append((lut[(i, j)], lut[(i + 1, j)], lut[(i, j + 1)]))
                if j < k - 1 - i:
                    loc.append((lut[(i + 1, j)], lut[(i + 1, j + 1)], lut[(i, j + 1)]))
        loc = np.array(loc)
        nv = len(ij)
        for arr, out in ((P, outP), (N, outN), (UV, outUV)):
            a, b, c = arr[sel[:, 0]], arr[sel[:, 1]], arr[sel[:, 2]]
            v = (w[None, :, 0:1] * a[:, None] + w[None, :, 1:2] * b[:, None] + w[None, :, 2:3] * c[:, None])
            out.append(v.reshape(-1, arr.shape[1]))
        offs = base + np.arange(len(sel)) * nv
        outI.append((loc[None] + offs[:, None, None]).reshape(-1))
        base += len(sel) * nv
    P2 = np.concatenate(outP)
    N2 = np.concatenate(outN)
    N2 /= np.linalg.norm(N2, axis=1, keepdims=True) + 1e-12
    return P2, N2, np.concatenate(outUV), np.concatenate(outI)


def _compact(P, N, UV, I):
    used = np.unique(I)
    remap = np.full(len(P), -1, np.int64)
    remap[used] = np.arange(len(used))
    return P[used], N[used], UV[used], remap[I]


def _max_edge(chunk, shader):
    if shader == "alleyGround":
        return 0.20 if chunk in ("near", "mid") else 0.35
    return {"near": 0.30, "mid": 0.40}.get(chunk, 0.60)


def compiler():
    for cc in ("cc", "gcc", "clang"):
        if shutil.which(cc):
            return cc
    raise RuntimeError("a C compiler is needed to bake the alley lighting")


def bake(world, materials, lights, log=print):
    """world: MeshBuilder (portal space).  lights: rows (name, pos, col, intensity, radius, flicker)."""
    shader_of = {k: v["shader"] for k, v in materials.items()}
    recv_keys, occ = [], []
    for key, part in world.parts.items():
        arr = part.arrays()
        if arr is None:
            continue
        chunk, mat = key
        sh = shader_of.get(mat, "")
        if sh in RECEIVER_SHADERS and chunk not in SKIP_CHUNKS:
            P, N, UV, I = _subdivide(*arr, max_edge=_max_edge(chunk, sh))
            P, N, UV, I = _compact(P, N, UV, I)
            part.pos, part.nrm, part.uv, part.idx = [P], [N], [UV], [I]
            part.count = len(P)
            recv_keys.append(key)
        # the back cap only exists in floor/ceiling views: it must not darken
        # the wall-portal lighting it would never be seen in
        if sh not in NON_OCCLUDING_SHADERS and chunk not in ("sky", "rain", "backcap"):
            P, _, _, I = part.arrays()
            occ.append(P[I.reshape(-1, 3)].reshape(-1, 9))
    tris = np.concatenate(occ).astype("<f4")
    recv = []
    for key in recv_keys:
        P, N, _, _ = world.parts[key].arrays()
        recv.append(np.concatenate([P, N], 1))
    recv = np.concatenate(recv).astype("<f4")
    L = []
    for (name, p, c, inten, rad, fl) in lights:
        weight = 0.0 if fl == 3 else 1.0          # moving car headlights: not baked
        L.append([*p, rad, c[0] * inten, c[1] * inten, c[2] * inten, weight])
    L = np.array(L, "<f4")

    tmp = tempfile.mkdtemp(prefix="aobake")
    exe = os.path.join(tmp, "aobake")
    cc = compiler()
    flags = ["-O3", "-ffast-math", "-march=native"]
    omp = subprocess.run([cc, *flags, "-fopenmp", os.path.join(HERE, "aobake.c"), "-o", exe, "-lm"], capture_output=True)
    if omp.returncode != 0:
        subprocess.run([cc, *flags, os.path.join(HERE, "aobake.c"), "-o", exe, "-lm"], check=True)
    paths = {k: os.path.join(tmp, f"{k}.f32") for k in ("tris", "recv", "lights", "out")}
    tris.tofile(paths["tris"])
    recv.tofile(paths["recv"])
    L.tofile(paths["lights"])
    subprocess.run([exe, paths["tris"], paths["recv"], paths["lights"], paths["out"],
                    str(AO_RAYS), str(AO_DIST), str(SHADOW_SAMPLES)], check=True)
    out = np.fromfile(paths["out"], "<f4").reshape(-1, 2)
    shutil.rmtree(tmp, ignore_errors=True)
    o = 0
    for key in recv_keys:
        part = world.parts[key]
        n = part.count
        ao, vis = out[o:o + n, 0], out[o:o + n, 1]
        part.uv1 = np.stack([3.0 - ao, 1.0 - vis], 1)
        o += n
    log(f"baked {len(recv)} receiver vertices against {len(tris)} triangles: "
        f"mean ao {out[:, 0].mean():.2f}, mean vis {out[:, 1].mean():.2f}")
    return dict(receivers=int(len(recv)), occluders=int(len(tris)), aoRays=AO_RAYS, aoDistance=AO_DIST,
                shadowSamples=SHADOW_SAMPLES, meanAO=round(float(out[:, 0].mean()), 3),
                meanVisibility=round(float(out[:, 1].mean()), 3))
