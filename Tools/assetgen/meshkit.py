"""
meshkit - small, dependency-light mesh authoring toolkit used to build the
portal doorway and the alley.  All geometry is authored in *portal space*:

    +x  right (as seen from the room, looking into the portal)
    +y  up (y = 0 is the detected real floor)
    +z  toward the room / viewer.  The alley extends to -z.

Front faces are counter-clockwise when seen from the side the normal points to
(RealityKit and WebGL both default to CCW front faces).

UVs use the USD convention (v = 0 at the bottom of the image).  Custom shaders
flip v before sampling; RealityKit's built-in PBR shader does this itself.

Output format (.pmsh, little endian):
    char[4]  'PMSH'
    u32      version (1)
    u32      part count
    per part:
        u16 nameLen, utf8 name
        u16 matLen,  utf8 material id
        u32 vertexCount, u32 indexCount
        f32[3*vc] positions, f32[3*vc] normals, f32[2*vc] uvs, u32[ic] indices
"""
from __future__ import annotations

import math
import struct
from collections import defaultdict

import numpy as np

V3 = np.ndarray


def v3(x, y, z):
    return np.array([x, y, z], dtype=np.float64)


def norm(a):
    a = np.asarray(a, dtype=np.float64)
    n = np.linalg.norm(a)
    return a / n if n > 1e-12 else a


class Part:
    __slots__ = ("pos", "nrm", "uv", "idx", "count")

    def __init__(self):
        self.pos, self.nrm, self.uv, self.idx = [], [], [], []
        self.count = 0

    def add(self, P, N, UV, I):
        P = np.asarray(P, np.float64).reshape(-1, 3)
        N = np.asarray(N, np.float64).reshape(-1, 3)
        UV = np.asarray(UV, np.float64).reshape(-1, 2)
        I = np.asarray(I, np.int64).reshape(-1)
        assert len(P) == len(N) == len(UV)
        self.pos.append(P)
        self.nrm.append(N)
        self.uv.append(UV)
        self.idx.append(I + self.count)
        self.count += len(P)

    def arrays(self):
        if not self.pos:
            return None
        return (np.concatenate(self.pos), np.concatenate(self.nrm),
                np.concatenate(self.uv), np.concatenate(self.idx))


class MeshBuilder:
    """Collects geometry per (chunk, material)."""

    def __init__(self):
        self.parts: dict[tuple[str, str], Part] = defaultdict(Part)
        self.chunk = "main"

    def part(self, mat: str) -> Part:
        return self.parts[(self.chunk, mat)]

    # ------------------------------------------------------------------ basic
    def tri_batch(self, mat, P, N, UV, I):
        self.part(mat).add(P, N, UV, I)

    def quad(self, mat, o, u, v, uv0=(0.0, 0.0), uv1=None, uv_scale=(1.0, 1.0),
             normal=None, double=False):
        """Quad with corners o, o+u, o+u+v, o+v.  Normal = u x v (CCW front)."""
        o, u, v = (np.asarray(a, np.float64) for a in (o, u, v))
        n = norm(np.cross(u, v)) if normal is None else norm(normal)
        if uv1 is None:
            lu, lv = np.linalg.norm(u), np.linalg.norm(v)
            uv1 = (uv0[0] + lu / uv_scale[0], uv0[1] + lv / uv_scale[1])
        P = [o, o + u, o + u + v, o + v]
        UV = [(uv0[0], uv0[1]), (uv1[0], uv0[1]), (uv1[0], uv1[1]), (uv0[0], uv1[1])]
        self.tri_batch(mat, P, [n] * 4, UV, [0, 1, 2, 0, 2, 3])
        if double:
            self.tri_batch(mat, P, [-n] * 4, UV, [0, 2, 1, 0, 3, 2])

    def wquad(self, mat, o, u, v, scale=(1.0, 1.0), offset=(0.0, 0.0), double=False):
        """Quad whose UVs are world-anchored (adjacent quads tile seamlessly).
        U follows u's direction, V follows v's direction."""
        o, u, v = (np.asarray(a, np.float64) for a in (o, u, v))
        du, dv = norm(u), norm(v)
        a0 = np.dot(o, du) / scale[0] + offset[0]
        b0 = np.dot(o, dv) / scale[1] + offset[1]
        a1 = a0 + np.linalg.norm(u) / scale[0]
        b1 = b0 + np.linalg.norm(v) / scale[1]
        self.quad(mat, o, u, v, uv0=(a0, b0), uv1=(a1, b1), double=double)

    # ------------------------------------------------------------------ boxes
    def box(self, mat, lo, hi, faces="xXyYzZ", scale=1.0, uv_world=True, mats=None):
        """Axis aligned box.  faces: subset of 'xXyYzZ' (lower = -axis face).
        mats: optional dict face->material overriding mat."""
        lo, hi = np.asarray(lo, np.float64), np.asarray(hi, np.float64)
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        dx, dy, dz = hi - lo
        sc = (scale, scale) if np.isscalar(scale) else scale
        F = {
            "X": (v3(x1, y0, z1), v3(0, 0, -dz), v3(0, dy, 0)),
            "x": (v3(x0, y0, z0), v3(0, 0, dz), v3(0, dy, 0)),
            "Y": (v3(x0, y1, z1), v3(dx, 0, 0), v3(0, 0, -dz)),
            "y": (v3(x0, y0, z0), v3(dx, 0, 0), v3(0, 0, dz)),
            "Z": (v3(x0, y0, z1), v3(dx, 0, 0), v3(0, dy, 0)),
            "z": (v3(x1, y0, z0), v3(-dx, 0, 0), v3(0, dy, 0)),
        }
        for f in faces:
            o, u, v = F[f]
            m = (mats or {}).get(f, mat)
            if uv_world:
                self.wquad(m, o, u, v, scale=sc)
            else:
                self.quad(m, o, u, v, uv0=(0, 0), uv1=(1, 1))

    def bevel_box(self, mat, lo, hi, r, scale=1.0, faces="xXyYzZ"):
        """Box with chamfered edges (radius r).  Hard-edged facets; reads as a
        manufactured bevel under lighting.  World-anchored UVs."""
        lo, hi = np.asarray(lo, np.float64), np.asarray(hi, np.float64)
        r = min(r, *(0.49 * (hi - lo)))
        c = (lo + hi) / 2
        h = (hi - lo) / 2
        sc = (scale, scale) if np.isscalar(scale) else scale
        # face quads (inset by r)
        axes = [(0, "x", "X"), (1, "y", "Y"), (2, "z", "Z")]
        for ax, lo_name, hi_name in axes:
            a1, a2 = [i for i in range(3) if i != ax]
            for sgn, name in ((-1, lo_name), (1, hi_name)):
                if name not in faces:
                    continue
                n = np.zeros(3)
                n[ax] = sgn
                o = c.copy()
                o[ax] += sgn * h[ax]
                u = np.zeros(3)
                v = np.zeros(3)
                u[a1] = 2 * (h[a1] - r)
                v[a2] = 2 * (h[a2] - r)
                if np.dot(np.cross(u, v), n) < 0:
                    u, v = v, u
                corner = o - u / 2 - v / 2
                self.wquad(mat, corner, u, v, scale=sc)
        # edge strips
        for ax in range(3):
            b1, b2 = [i for i in range(3) if i != ax]
            for s1 in (-1, 1):
                for s2 in (-1, 1):
                    n1 = np.zeros(3); n1[b1] = s1
                    n2 = np.zeros(3); n2[b2] = s2
                    p_a = c.copy(); p_a[b1] += s1 * h[b1]; p_a[b2] += s2 * (h[b2] - r)
                    p_b = c.copy(); p_b[b1] += s1 * (h[b1] - r); p_b[b2] += s2 * h[b2]
                    L = np.zeros(3); L[ax] = h[ax] - r
                    P = [p_a - L, p_b - L, p_b + L, p_a + L]
                    n = norm(n1 + n2)
                    tri = [0, 1, 2, 0, 2, 3]
                    if np.dot(np.cross(P[1] - P[0], P[2] - P[0]), n) < 0:
                        tri = [0, 2, 1, 0, 3, 2]
                    ln = np.linalg.norm(P[3] - P[0])
                    UV = [(0, 0), (r * 1.4 / sc[0], 0), (r * 1.4 / sc[0], ln / sc[1]), (0, ln / sc[1])]
                    self.tri_batch(mat, P, [n] * 4, UV, tri)
        # corner triangles
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    s = np.array([sx, sy, sz], np.float64)
                    P = []
                    for ax in range(3):
                        p = c + s * h
                        p = p.copy()
                        for o_ax in range(3):
                            if o_ax != ax:
                                p[o_ax] = c[o_ax] + s[o_ax] * (h[o_ax] - r)
                        P.append(p)
                    n = norm(s)
                    tri = [0, 1, 2]
                    if np.dot(np.cross(P[1] - P[0], P[2] - P[0]), n) < 0:
                        tri = [0, 2, 1]
                    self.tri_batch(mat, P, [n] * 3, [(0, 0), (0.02, 0), (0, 0.02)], tri)

    # ------------------------------------------------------------- revolved
    def lathe(self, mat, base, profile, segs=16, axis="y", uv_u=1.0, cap_top=False,
              cap_bottom=False, smooth=True, u_range=(0.0, 1.0), v_range=None):
        """Revolve profile [(radius, height), ...] (bottom to top) around an
        axis through `base`.  axis 'y' (vertical) or 'x'/'z' (horizontal)."""
        base = np.asarray(base, np.float64)
        prof = np.asarray(profile, np.float64)
        n_p = len(prof)
        # cumulative profile length for v
        seg_len = np.r_[0, np.cumsum(np.hypot(np.diff(prof[:, 0]), np.diff(prof[:, 1])))]
        vv = seg_len / max(seg_len[-1], 1e-9)
        if v_range is not None:
            vv = v_range[0] + vv * (v_range[1] - v_range[0])
        # profile normals (2D) in (r, h)
        t2 = np.zeros_like(prof)
        t2[1:-1] = prof[2:] - prof[:-2]
        t2[0] = prof[1] - prof[0]
        t2[-1] = prof[-1] - prof[-2]
        t2 /= np.linalg.norm(t2, axis=1, keepdims=True) + 1e-12
        n2 = np.stack([t2[:, 1], -t2[:, 0]], 1)  # rotate -90: outward

        def frame(theta):
            if axis == "y":
                return v3(math.cos(theta), 0, -math.sin(theta)), v3(0, 1, 0)
            if axis == "x":
                return v3(0, math.cos(theta), -math.sin(theta)), v3(1, 0, 0)
            return v3(math.cos(theta), math.sin(theta), 0), v3(0, 0, 1)

        P, N, UV = [], [], []
        for s in range(segs + 1):
            th = 2 * math.pi * s / segs
            radial, up = frame(th)
            for i in range(n_p):
                r, hgt = prof[i]
                P.append(base + radial * r + up * hgt)
                N.append(norm(radial * n2[i, 0] + up * n2[i, 1]))
                UV.append((u_range[0] + (u_range[1] - u_range[0]) * s / segs * uv_u, vv[i]))
        I = []
        for s in range(segs):
            for i in range(n_p - 1):
                a = s * n_p + i
                b = (s + 1) * n_p + i
                I += [a, b, b + 1, a, b + 1, a + 1]
        self.tri_batch(mat, P, N, UV, I)
        self._fix_winding_last(mat)
        _, up = frame(0)
        for cap, idx, sgn in ((cap_top, -1, 1), (cap_bottom, 0, -1)):
            if not cap:
                continue
            r, hgt = prof[idx]
            if r < 1e-6:
                continue
            ctr = base + up * hgt
            Pc, Nc, UVc, Ic = [ctr], [up * sgn], [(0.5, 0.5)], []
            for s in range(segs + 1):
                th = 2 * math.pi * s / segs
                radial, _ = frame(th)
                Pc.append(ctr + radial * r)
                Nc.append(up * sgn)
                UVc.append((0.5 + 0.5 * math.cos(th), 0.5 + 0.5 * math.sin(th)))
            for s in range(segs):
                if sgn > 0:
                    Ic += [0, s + 1, s + 2]
                else:
                    Ic += [0, s + 2, s + 1]
            self.tri_batch(mat, Pc, Nc, UVc, Ic)
            self._fix_winding_last(mat)

    def _fix_winding_last(self, mat):
        """Ensure the last batch's triangle winding agrees with its normals."""
        part = self.part(mat)
        P, N, I = part.pos[-1], part.nrm[-1], part.idx[-1] - (part.count - len(part.pos[-1]))
        tri = I.reshape(-1, 3)
        a, b, c = P[tri[:, 0]], P[tri[:, 1]], P[tri[:, 2]]
        fn = np.cross(b - a, c - a)
        nn = N[tri[:, 0]] + N[tri[:, 1]] + N[tri[:, 2]]
        bad = np.einsum("ij,ij->i", fn, nn) < 0
        if bad.any():
            tri[bad] = tri[bad][:, [0, 2, 1]]
            part.idx[-1] = tri.reshape(-1) + (part.count - len(part.pos[-1]))

    def cylinder(self, mat, p0, p1, radius, segs=12, caps=True, uv_u=1.0, uv_v=None):
        """Cylinder between arbitrary points with smooth sides."""
        p0, p1 = np.asarray(p0, np.float64), np.asarray(p1, np.float64)
        ax = p1 - p0
        L = np.linalg.norm(ax)
        a = ax / L
        t = norm(np.cross(a, v3(0, 1, 0) if abs(a[1]) < 0.9 else v3(1, 0, 0)))
        b = np.cross(a, t)
        P, N, UV, I = [], [], [], []
        vlen = L / (uv_v if uv_v else L)
        for s in range(segs + 1):
            th = 2 * math.pi * s / segs
            d = t * math.cos(th) + b * math.sin(th)
            P += [p0 + d * radius, p1 + d * radius]
            N += [d, d]
            UV += [(s / segs * uv_u, 0), (s / segs * uv_u, vlen)]
        for s in range(segs):
            i = 2 * s
            I += [i, i + 2, i + 3, i, i + 3, i + 1]
        self.tri_batch(mat, P, N, UV, I)
        self._fix_winding_last(mat)
        if caps:
            for pc, sgn in ((p0, -1), (p1, 1)):
                Pc, Nc, UVc, Ic = [pc], [a * sgn], [(0.5, 0.5)], []
                for s in range(segs + 1):
                    th = 2 * math.pi * s / segs
                    d = t * math.cos(th) + b * math.sin(th)
                    Pc.append(pc + d * radius)
                    Nc.append(a * sgn)
                    UVc.append((0.5 + 0.5 * math.cos(th), 0.5 + 0.5 * math.sin(th)))
                for s in range(segs):
                    Ic += [0, s + 1, s + 2]
                self.tri_batch(mat, Pc, Nc, UVc, Ic)
                self._fix_winding_last(mat)

    def tube(self, mat, pts, radius, segs=6, uv_len=1.0):
        """Smooth tube along a polyline (cables, conduit)."""
        pts = np.asarray(pts, np.float64)
        n = len(pts)
        tang = np.zeros_like(pts)
        tang[1:-1] = pts[2:] - pts[:-2]
        tang[0] = pts[1] - pts[0]
        tang[-1] = pts[-1] - pts[-2]
        tang /= np.linalg.norm(tang, axis=1, keepdims=True)
        ref = v3(0, 1, 0) if abs(tang[0][1]) < 0.9 else v3(1, 0, 0)
        t = norm(np.cross(tang[0], ref))
        P, N, UV, I = [], [], [], []
        acc = 0.0
        for i in range(n):
            if i > 0:
                acc += np.linalg.norm(pts[i] - pts[i - 1])
                # parallel transport
                t = norm(t - tang[i] * np.dot(t, tang[i]))
            b = np.cross(tang[i], t)
            for s in range(segs + 1):
                th = 2 * math.pi * s / segs
                d = t * math.cos(th) + b * math.sin(th)
                P.append(pts[i] + d * radius)
                N.append(d)
                UV.append((s / segs, acc / uv_len))
        for i in range(n - 1):
            for s in range(segs):
                a = i * (segs + 1) + s
                c = (i + 1) * (segs + 1) + s
                I += [a, c, c + 1, a, c + 1, a + 1]
        self.tri_batch(mat, P, N, UV, I)
        self._fix_winding_last(mat)

    def sweep(self, mat, profile, path, closed=False, scale_uv=1.0, smooth_profile=None):
        """Sweep a 2D profile [(a, b)] along a polyline path.  At each path point
        the profile's a-axis maps to the in-plane outward vector `side` and the
        b-axis to the path plane normal `up`.  path: list of (point, side, up).
        Mitered: the side vector at a corner is scaled by 1/cos(theta/2).
        Profile is a polyline traversed so that faces point outward; hard edges
        between profile segments (each segment gets its own normal)."""
        prof = np.asarray(profile, np.float64)
        m = len(prof)
        acc = 0.0
        for k in range(m - 1):
            a0, b0 = prof[k]
            a1, b1 = prof[k + 1]
            P, N, UV, I = [], [], [], []
            acc_path = 0.0
            for i, (pt, side, up) in enumerate(path):
                pt, side, up = (np.asarray(x, np.float64) for x in (pt, side, up))
                if i > 0:
                    acc_path += np.linalg.norm(pt - path[i - 1][0])
                q0 = pt + side * a0 + up * b0
                q1 = pt + side * a1 + up * b1
                P += [q0, q1]
                UV += [(acc_path / scale_uv, acc / scale_uv),
                       (acc_path / scale_uv, (acc + math.hypot(a1 - a0, b1 - b0)) / scale_uv)]
            seglen = math.hypot(a1 - a0, b1 - b0)
            acc += seglen
            # normals: per path point, perpendicular to (q1-q0) and path tangent
            for i in range(len(path)):
                q0, q1 = P[2 * i], P[2 * i + 1]
                if i < len(path) - 1:
                    tg = np.asarray(path[i + 1][0]) - np.asarray(path[i][0])
                else:
                    tg = np.asarray(path[i][0]) - np.asarray(path[i - 1][0])
                e = q1 - q0
                nrm = norm(np.cross(tg, e))
                # orient outward relative to the profile's own 2D normal
                side, up = np.asarray(path[i][1]), np.asarray(path[i][2])
                n2 = v3(0, 0, 0) + side * (b1 - b0) - up * (a1 - a0)
                if np.dot(nrm, n2) < 0:
                    nrm = -nrm
                N += [nrm, nrm]
            for i in range(len(path) - 1):
                a = 2 * i
                I += [a, a + 2, a + 3, a, a + 3, a + 1]
            self.tri_batch(mat, P, N, UV, I)
            self._fix_winding_last(mat)

    def polygon_cap(self, mat, pts, normal):
        """Triangle-fan cap for a convex-ish planar polygon."""
        pts = np.asarray(pts, np.float64)
        c = pts.mean(0)
        n = norm(normal)
        P = [c] + list(pts)
        I = []
        k = len(pts)
        for i in range(k):
            I += [0, 1 + i, 1 + (i + 1) % k]
        UV = [(0.5, 0.5)] + [(0.5 + 0.5 * math.cos(2 * math.pi * i / k), 0.5 + 0.5 * math.sin(2 * math.pi * i / k)) for i in range(k)]
        self.tri_batch(mat, P, [n] * len(P), UV, I)
        self._fix_winding_last(mat)

    def sweep_flat(self, profile, mats, path, uv_scale=1.0):
        """Hard-edged sweep.  profile: CCW closed-or-open polyline [(a, b)] in
        the (side, up) plane; mats[k] = material of profile segment k.
        path: [(point, side, up)] where side may carry a miter scale.
        Every (path segment x profile segment) becomes one flat quad."""
        prof = np.asarray(profile, np.float64)
        acc_prof = np.r_[0, np.cumsum(np.hypot(*np.diff(prof, axis=0).T))]
        acc_path = 0.0
        for i in range(len(path) - 1):
            p0, s0, u0 = (np.asarray(x, np.float64) for x in path[i])
            p1, s1, u1 = (np.asarray(x, np.float64) for x in path[i + 1])
            seg = np.linalg.norm(p1 - p0)
            tang = (p1 - p0) / seg
            for k in range(len(prof) - 1):
                (a0, b0), (a1, b1) = prof[k], prof[k + 1]
                q00 = p0 + s0 * a0 + u0 * b0
                q01 = p0 + s0 * a1 + u0 * b1
                q10 = p1 + s1 * a0 + u1 * b0
                q11 = p1 + s1 * a1 + u1 * b1
                # outward normal from the profile's own 2D normal (db, -da)
                sd = norm(s0 + s1) if np.linalg.norm(s0 + s1) > 1e-9 else norm(s0)
                ud = norm(u0 + u1)
                # remove tangent components so the normal is perpendicular to the path
                sd = norm(sd - tang * np.dot(sd, tang))
                n2 = sd * (b1 - b0) - ud * (a1 - a0)
                e = q01 - q00
                nrm = norm(np.cross(tang, e))
                if np.dot(nrm, n2) < 0:
                    nrm = -nrm
                P = [q00, q10, q11, q01]
                v0 = acc_prof[k] / uv_scale
                v1 = acc_prof[k + 1] / uv_scale
                UV = [(acc_path / uv_scale, v0), ((acc_path + seg) / uv_scale, v0),
                      ((acc_path + seg) / uv_scale, v1), (acc_path / uv_scale, v1)]
                tri = [0, 1, 2, 0, 2, 3]
                if np.dot(np.cross(P[1] - P[0], P[2] - P[0]), nrm) < 0:
                    tri = [0, 2, 1, 0, 3, 2]
                self.tri_batch(mats[k], P, [nrm] * 4, UV, tri)
            acc_path += seg

    def merge(self, other: "MeshBuilder", M=None, chunk=None):
        """Merge another builder's parts, optionally transformed by 4x4 M."""
        for (ch, mat), part in other.parts.items():
            arr = part.arrays()
            if arr is None:
                continue
            P, N, UV, I = arr
            if M is not None:
                R = M[:3, :3]
                Rn = np.linalg.inv(R).T
                P = P @ R.T + M[:3, 3]
                N = N @ Rn.T
                N = N / (np.linalg.norm(N, axis=1, keepdims=True) + 1e-12)
                if np.linalg.det(R) < 0:
                    I = I.reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)
            self.parts[(chunk or ch, mat)].add(P, N, UV, I)

    # ------------------------------------------------------------- transform
    def transformed(self, fn_build, M):
        """Run fn_build(MeshBuilder) into a temp builder, transform by 4x4 M, merge."""
        tmp = MeshBuilder()
        tmp.chunk = self.chunk
        fn_build(tmp)
        R = M[:3, :3]
        Rn = np.linalg.inv(R).T
        for key, part in tmp.parts.items():
            arr = part.arrays()
            if arr is None:
                continue
            P, N, UV, I = arr
            P2 = P @ R.T + M[:3, 3]
            N2 = N @ Rn.T
            N2 /= np.linalg.norm(N2, axis=1, keepdims=True) + 1e-12
            if np.linalg.det(R) < 0:
                I = I.reshape(-1, 3)[:, [0, 2, 1]].reshape(-1)
            self.parts[key].add(P2, N2, UV, I)

    # ------------------------------------------------------------- stats/io
    def stats(self):
        tris = 0
        verts = 0
        for p in self.parts.values():
            arr = p.arrays()
            if arr is None:
                continue
            verts += len(arr[0])
            tris += len(arr[3]) // 3
        return verts, tris

    def write(self, path, name_prefix=""):
        out = bytearray()
        items = [(k, p.arrays()) for k, p in sorted(self.parts.items())]
        items = [(k, a) for k, a in items if a is not None]
        out += b"PMSH" + struct.pack("<II", 1, len(items))
        for (chunk, mat), (P, N, UV, I) in items:
            # strip degenerate triangles (lathe poles etc.)
            tri = I.reshape(-1, 3)
            a, b, c = P[tri[:, 0]], P[tri[:, 1]], P[tri[:, 2]]
            keep = np.linalg.norm(np.cross(b - a, c - a), axis=1) > 1e-10
            I = tri[keep].reshape(-1)
            name = f"{name_prefix}{chunk}".encode()
            m = mat.encode()
            out += struct.pack("<H", len(name)) + name
            out += struct.pack("<H", len(m)) + m
            out += struct.pack("<II", len(P), len(I))
            out += P.astype("<f4").tobytes()
            out += N.astype("<f4").tobytes()
            out += UV.astype("<f4").tobytes()
            out += I.astype("<u4").tobytes()
        with open(path, "wb") as f:
            f.write(out)
        return len(out)

    def check(self):
        """Sanity: finite values, unit normals, no degenerate-heavy parts, and
        winding consistent with normals (fraction reported)."""
        report = {}
        for key, part in self.parts.items():
            arr = part.arrays()
            if arr is None:
                continue
            P, N, UV, I = arr
            assert np.isfinite(P).all() and np.isfinite(N).all() and np.isfinite(UV).all(), key
            tri = I.reshape(-1, 3)
            assert tri.max() < len(P), key
            a, b, c = P[tri[:, 0]], P[tri[:, 1]], P[tri[:, 2]]
            fn = np.cross(b - a, c - a)
            area = np.linalg.norm(fn, axis=1)
            nn = N[tri].sum(1)
            ok = np.einsum("ij,ij->i", fn, nn) >= 0
            report[key] = (len(tri), float(ok.mean()), int((area < 1e-10).sum()))
        return report


def rot_y(deg):
    a = math.radians(deg)
    M = np.eye(4)
    M[0, 0] = math.cos(a); M[0, 2] = math.sin(a)
    M[2, 0] = -math.sin(a); M[2, 2] = math.cos(a)
    return M


def translate(x, y, z):
    M = np.eye(4)
    M[:3, 3] = (x, y, z)
    return M
