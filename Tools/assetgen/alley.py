"""
The destination: a rainy night alley ("ほたる横丁", fictional) seen through
the doorway.  Portal space: the doorway's aperture plane is z ~ 0, the alley
runs toward -z, y = 0 is the room floor.  The alley asphalt sits one step
lower (G = -0.12) behind a concrete stoop, so the view through the door looks
slightly down onto wet pavement.

Composition (from the doorway):
  near  0-3.5 m : stoop, crates, gutter grates, service doors, wall lamp,
                  pipes, meters, a vending-machine pair catching the eye right
  mid   3.5-13 m: arch sign across the alley, cafe + awning (left), laundromat
                  (right), izakaya with red lanterns (right), bar blade sign
                  and a stacked-sign tower (left), utility pole, overhead cables
  far  13-21 m  : side passage glowing red (left), pharmacy (right), a
                  T-junction cross lane; the focal ramen shop faces straight
                  down the alley, the lane continues brightly to the right
  beyond        : taller buildings, towers with aviation lights, sky dome
"""
import math

import numpy as np

from meshkit import MeshBuilder, v3, norm
import props

G = -0.12          # asphalt level
XL = -1.45         # left facade plane
XR = 1.65          # right facade plane
Z_END = -17.5      # alley meets the cross lane
Z_FAR = -20.0      # far side of the cross lane (ramen facade)


# ---------------------------------------------------------------- transforms
def frame_matrix(es, eh, ed, origin):
    M = np.eye(4)
    M[:3, 0], M[:3, 1], M[:3, 2] = es, eh, ed
    M[:3, 3] = origin
    assert abs(np.linalg.det(M[:3, :3]) - 1) < 1e-6
    return M


def M_left(z_start, x=XL):
    return frame_matrix(v3(0, 0, -1), v3(0, 1, 0), v3(1, 0, 0), v3(x, G, z_start))


def M_right(z_far, x=XR):
    return frame_matrix(v3(0, 0, 1), v3(0, 1, 0), v3(-1, 0, 0), v3(x, G, z_far))


def M_front(x_left, z):
    return frame_matrix(v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1), v3(x_left, G, z))


def catenary(p0, p1, sag, n=14):
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    pts = []
    for i in range(n + 1):
        t = i / n
        p = p0 * (1 - t) + p1 * t
        p[1] -= sag * 4 * t * (1 - t)
        pts.append(p)
    return pts


# ---------------------------------------------------------------- facade kit
class Facade:
    """Builds one building face in local coordinates (s along, h up, d out).
    side: 'left' | 'right' | 'front' decides which box face looks at the
    viewer for projecting signs."""

    def __init__(self, length, height, wall_mat, side, uv_scale=2.0):
        self.mb = MeshBuilder()
        self.L, self.H = length, height
        self.wall_mat = wall_mat
        self.side = side
        self.sc = uv_scale
        self.holes = []

    # holes -------------------------------------------------------------
    def hole(self, s0, s1, h0, h1):
        self.holes.append((s0, s1, h0, h1))

    def build_wall(self, h_top=None):
        H = h_top if h_top is not None else self.H
        cuts = sorted({0.0, self.L, *[c for hl in self.holes for c in hl[:2]]})
        for a, b in zip(cuts[:-1], cuts[1:]):
            if b - a < 1e-6:
                continue
            covered = sorted((h0, h1) for s0, s1, h0, h1 in self.holes if s0 <= a + 1e-6 and s1 >= b - 1e-6)
            y = 0.0
            for h0, h1 in covered + [(H, H)]:
                if h0 > y + 1e-6:
                    self.mb.wquad(self.wall_mat, v3(a, y, 0), v3(b - a, 0, 0), v3(0, h0 - y, 0), scale=(self.sc, self.sc))
                y = max(y, h1)
        # parapet: coping + top
        self.mb.bevel_box("concrete_dark", (0, H - 0.18, -0.25), (self.L, H + 0.05, 0.05), 0.015, scale=2.0, faces="XxYZ")

    def recess(self, s0, s1, h0, h1, depth, back_mat=None, reveal_mat=None, back_uv=None, floor_mat=None):
        """Opening with reveals; optional back panel (glass/interior/door)."""
        rm = reveal_mat or self.wall_mat
        mb = self.mb
        sc = (0.5, 0.5)
        mb.wquad(rm, v3(s0, h0, -depth), v3(0, h1 - h0, 0), v3(0, 0, depth), scale=sc)    # left reveal (+s)
        mb.wquad(rm, v3(s1, h0, 0), v3(0, h1 - h0, 0), v3(0, 0, -depth), scale=sc)        # right reveal (-s)
        mb.wquad(rm, v3(s0, h1, -depth), v3(s1 - s0, 0, 0), v3(0, 0, depth), scale=sc)    # soffit
        mb.wquad(floor_mat or rm, v3(s0, h0, 0), v3(s1 - s0, 0, 0), v3(0, 0, -depth), scale=sc)  # sill/floor
        if back_mat:
            if back_uv:
                u0, v0, u1, v1 = back_uv
                mb.quad(back_mat, v3(s0, h0, -depth), v3(s1 - s0, 0, 0), v3(0, h1 - h0, 0), uv0=(u0, v0), uv1=(u1, v1))
            else:
                mb.wquad(back_mat, v3(s0, h0, -depth), v3(s1 - s0, 0, 0), v3(0, h1 - h0, 0), scale=(1.0, 1.0))

    def window(self, s, h, w, hh, interior_uv, mat="windows_upper", depth=0.12, mullion=True, frame="metal_dark"):
        self.hole(s, s + w, h, h + hh)
        self.recess(s, s + w, h, h + hh, depth)
        mb = self.mb
        u0, v0, u1, v1 = interior_uv
        mb.quad(mat, v3(s, h, -depth), v3(w, 0, 0), v3(0, hh, 0), uv0=(u0, v0), uv1=(u1, v1))
        t = 0.035
        d0, d1 = -depth, -depth + 0.045
        for lo, hi in (((s, h, d0), (s + w, h + t, d1)), ((s, h + hh - t, d0), (s + w, h + hh, d1)),
                       ((s, h, d0), (s + t, h + hh, d1)), ((s + w - t, h, d0), (s + w, h + hh, d1))):
            mb.box(frame, lo, hi, faces="xXyYZ", scale=0.5)
        if mullion:
            m = s + w / 2
            mb.box(frame, (m - t / 2, h, d0), (m + t / 2, h + hh, d1), faces="xXZ", scale=0.5)
        # sill ledge
        mb.bevel_box("concrete", (s - 0.04, h - 0.05, -0.02), (s + w + 0.04, h, 0.06), 0.01, scale=1.0, faces="xXYyZ")

    # attachments -------------------------------------------------------
    def view_face(self):
        return {"left": "x", "right": "X", "front": "Z"}[self.side]

    def blade_sign(self, s, h0, h1, out, thick, atlas_uv, mat="sign_static", standoff=0.18, back_uv=None):
        """Sign perpendicular to the wall, readable from the doorway."""
        mb = self.mb
        d0, d1 = standoff, standoff + out
        s0, s1 = s - thick / 2, s + thick / 2
        mb.box("metal_dark", (s0, h0, d0), (s1, h1, d1), faces="yYZ", scale=0.5)
        u0, v0, u1, v1 = atlas_uv
        bu0, bv0, bu1, bv1 = back_uv or atlas_uv
        # -s face (viewer for left) : u along +d
        mb.quad(mat, v3(s0, h0, d0), v3(0, 0, d1 - d0), v3(0, h1 - h0, 0), uv0=(u0, v0), uv1=(u1, v1))
        # +s face (viewer for right): u along -d
        mb.quad(mat, v3(s1, h0, d1), v3(0, 0, d0 - d1), v3(0, h1 - h0, 0), uv0=(bu0, bv0), uv1=(bu1, bv1))
        # brackets
        for hb in (h0 + 0.12, h1 - 0.12):
            mb.box("metal_dark", (s - 0.012, hb - 0.012, 0), (s + 0.012, hb + 0.012, d0), faces="xXyYZ", scale=0.3)

    def flat_sign(self, s0, s1, h0, h1, atlas_uv, mat="sign_static", proud=0.08, frame_mat="metal_dark"):
        mb = self.mb
        mb.box(frame_mat, (s0 - 0.02, h0 - 0.02, 0), (s1 + 0.02, h1 + 0.02, proud), faces="xXyYZ", scale=0.5)
        u0, v0, u1, v1 = atlas_uv
        mb.quad(mat, v3(s0, h0, proud + 0.003), v3(s1 - s0, 0, 0), v3(0, h1 - h0, 0), uv0=(u0, v0), uv1=(u1, v1))

    def ac_unit(self, s, h, w=0.78, hh=0.56, dep=0.28, pipe_to=None):
        """Scanned outdoor AC unit (Poly Haven, CC0) on its wall bracket.
        s = left edge of the body, h = underside of the body."""
        mb = self.mb
        item = "aircon_rusted" if int(round(s * 7 + h * 3)) % 3 == 0 else "aircon"
        props.place(mb, item, (s + 0.40, h, 0.0), anchor="back")
        # pipe cover duct down the wall (white PVC trunking, typical in Japan)
        if pipe_to is not None:
            px = s + w + 0.05
            top = h + hh * 0.5
            mb.box("metal_white", (px, min(pipe_to, top), 0.0), (px + 0.09, max(pipe_to, top), 0.07), faces="xXyYZ", scale=0.5)
            mb.box("metal_white", (s + w - 0.02, top - 0.04, 0.0), (px + 0.09, top + 0.04, 0.07), faces="yYZ", scale=0.5)

    def shutter_window(self, s, h, graffiti=False):
        """Surface-mounted window with a closed roller shutter (scan)."""
        props.place(self.mb, "shutter_window", (s + 0.49, h, 0.0), anchor="back")

    def security_light(self, s, h):
        props.place(self.mb, "security_light", (s, h, 0.0), anchor="back")

    def camera(self, s, h):
        props.place(self.mb, "camera", (s, h, 0.0), anchor="back", rot_y=0.0)

    def fluorescent(self, s, h, d):
        """Bare tube fitting hanging from a soffit at height h, d out from the wall."""
        props.place(self.mb, "fluorescent", (s, h, d), anchor="none")

    def utility_box(self, s, which=1, d=0.02):
        props.place(self.mb, f"utility_box_{which}", (s, 0.0, d), anchor="back_bottom")

    def duct_run(self, s, h0, h1, d=0.0):
        """Vertical circular exhaust duct (scan): 1.42 m sections held off the
        wall by strap braces (brace bar on the wall, duct axis 0.49 m out)."""
        dc = d + 0.50
        y = h0
        while y < h1 - 0.2:
            props.place(self.mb, "duct_triple", (s, y, dc), rot_x=-90.0, anchor="none")
            props.place(self.mb, "duct_brace", (s, y + 0.71, dc), rot_x=-90.0, anchor="none")
            y += 1.42

    def pipe(self, s, h0, h1, r=0.045, mat="metal_grey", d=0.07):
        self.mb.cylinder(mat, v3(s, h0, d), v3(s, h1, d), r, segs=10, caps=False)
        for hb in np.arange(h0 + 0.5, h1, 1.6):
            self.mb.box("metal_dark", (s - r - 0.01, hb, 0), (s + r + 0.01, hb + 0.03, d + r + 0.01), faces="xXyYZ", scale=0.3)

    def hpipe(self, s0, s1, h, r=0.035, mat="metal_grey", d=0.07):
        self.mb.cylinder(mat, v3(s0, h, d), v3(s1, h, d), r, segs=10, caps=False)

    def meter_box(self, s, h, w=0.32, hh=0.42):
        mb = self.mb
        mb.bevel_box("metal_grey", (s, h, 0.0), (s + w, h + hh, 0.14), 0.012, scale=0.5)
        mb.box("metal_dark", (s + 0.05, h + hh * 0.55, 0.14), (s + w - 0.05, h + hh * 0.85, 0.145), faces="Z", scale=0.3)

    def balcony(self, s0, s1, h, depth=0.75):
        mb = self.mb
        mb.bevel_box("concrete", (s0, h - 0.14, 0), (s1, h, depth), 0.02, scale=2.0, faces="xXyYZ")
        mb.box("metal_dark", (s0, h + 0.95, depth - 0.04), (s1, h + 1.0, depth), faces="yYZx", scale=0.5)
        for x in np.arange(s0 + 0.06, s1, 0.12):
            mb.box("metal_dark", (x, h, depth - 0.03), (x + 0.015, h + 0.95, depth - 0.015), faces="xXZ", scale=0.5)
        for x in (s0, s1 - 0.04):
            mb.box("metal_dark", (x, h, 0), (x + 0.04, h + 1.0, depth), faces="xXYZ", scale=0.5)

    def door(self, s, w, hh, mat="metal_grey", depth=0.12, step=True, floor=0.0):
        self.hole(s, s + w, floor, floor + hh)
        self.recess(s, s + w, floor, floor + hh, depth, back_mat=mat)
        mb = self.mb
        mb.box("metal_dark", (s + w - 0.16, floor + hh * 0.48, -depth), (s + w - 0.06, floor + hh * 0.5, -depth + 0.05), faces="xXyYZ", scale=0.2)
        if step:
            mb.bevel_box("concrete", (s - 0.08, 0, -0.02), (s + w + 0.08, 0.15, 0.32), 0.012, scale=1.0, faces="xXYZ")

    def lamp(self, s, h, light="bulb_warm_uv"):
        mb = self.mb
        mb.box("metal_dark", (s - 0.015, h + 0.12, 0), (s + 0.015, h + 0.15, 0.35), faces="xXyYZ", scale=0.3)
        mb.lathe("metal_dark", v3(s, h, 0.33), [(0.0, 0.12), (0.17, 0.05), (0.16, 0.06), (0.0, 0.10)], segs=14)
        mb.lathe("bulb", v3(s, h + 0.02, 0.33), [(0.0, -0.05), (0.035, -0.03), (0.045, 0.0), (0.035, 0.03), (0.0, 0.05)], segs=10)
        return v3(s, h + 0.02, 0.33)


# ---------------------------------------------------------------- the alley
def build(signs_atlas, interiors):
    SA = signs_atlas.uv
    IA = interiors.uv
    world = MeshBuilder()

    def place(fac: Facade, M, chunk):
        world.merge(fac.mb, M, chunk=chunk)

    # ============================================================ GROUND
    world.chunk = "near"
    # concrete stoop under the doorway (top = room floor), nosing strip
    world.box("concrete_stoop", (-0.95, G, -0.86), (0.95, 0.0, -0.13), faces="xXYz", scale=1.5)
    world.box("metal_grey", (-0.95, -0.012, -0.86), (0.95, 0.0005, -0.80), faces="Yz", scale=0.5)
    # asphalt, split by chunk for culling
    for chunk, z0, z1 in (("near", -0.13, -3.5), ("mid", -3.5, -12.5), ("far", -12.5, Z_END)):
        world.chunk = chunk
        world.wquad("asphalt", v3(-1.17, G, z0), v3(1.45 + 1.17, 0, 0), v3(0, 0, z1 - z0), scale=(4.0, 4.0))
        # left gutter grates (0.5 m pieces)
        z = z0
        while z > z1 + 1e-6:
            dz = max(z1 - z, -0.5)
            world.quad("grate", v3(XL, G + 0.0, z), v3(0.28, 0, 0), v3(0, 0, dz), uv0=(0, 0), uv1=(1, -dz / 0.5))
            z += dz
        # right curb (4 cm)
        world.wquad("concrete_ground", v3(1.45, G + 0.04, z0), v3(0.2, 0, 0), v3(0, 0, z1 - z0), scale=(1.5, 1.5))
        world.wquad("concrete_ground", v3(1.45, G, z0), v3(0, 0.04, 0), v3(0, 0, z1 - z0), scale=(1.5, 1.5))
    world.chunk = "far"
    # cross lane
    world.wquad("asphalt", v3(-8.0, G, Z_END), v3(22.0, 0, 0), v3(0, 0, Z_FAR - Z_END), scale=(4.0, 4.0))
    # manhole + road marking decal
    world.chunk = "mid"
    pts = [v3(0.3 + math.cos(a) * 0.31, G + 0.003, -7.2 - math.sin(a) * 0.31) for a in np.linspace(0, 2 * math.pi, 40, endpoint=False)]
    c = v3(0.3, G + 0.003, -7.2)
    P = [c] + pts
    UV = [(0.5, 0.5)] + [(0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a)) for a in np.linspace(0, 2 * math.pi, 40, endpoint=False)]
    I = []
    for i in range(40):
        I += [0, 1 + i, 1 + (i + 1) % 40]
    world.tri_batch("manhole", P, [v3(0, 1, 0)] * len(P), UV, I)
    world._fix_winding_last("manhole")
    world.chunk = "far"
    # 止まれ decal (reads from the doorway: characters stacked toward the viewer)
    world.quad("road_paint", v3(-0.35, G + 0.004, -14.6), v3(1.0, 0, 0), v3(0, 0, -2.6), uv0=(0, 0), uv1=(1, 1))

    # ============================================================ LEFT SIDE
    # L1 service side: board-formed concrete
    f = Facade(3.17, 9.5, "concrete", "left", 3.0)
    f.door(1.35, 0.9, 2.05, mat="metal_grey", step=True)
    f.pipe(0.22, 0.0, 9.3, r=0.05)
    f.pipe(0.42, 0.0, 6.0, r=0.03, mat="metal_dark")
    f.hpipe(0.0, 3.17, 3.05, r=0.03)
    f.meter_box(0.6, 1.1)
    f.meter_box(0.6, 1.62, 0.32, 0.36)
    f.ac_unit(2.3, 2.55, pipe_to=0.4)
    f.window(1.2, 3.6, 1.1, 1.1, IA("upper_stair"), mullion=False)
    f.window(0.5, 6.6, 1.2, 1.15, IA("upper_dark"))
    f.window(1.9, 6.6, 1.0, 1.15, IA("upper_warm_curtain"))
    f.ac_unit(0.6, 5.7)
    f.flat_sign(2.55, 2.89, 1.25, 1.42, SA("poster_0"), mat="sign_soft", proud=0.004, frame_mat="metal_white")
    f.fluorescent(1.8, 2.42, 0.10)
    f.camera(2.75, 2.55)
    f.build_wall()
    place(f, M_left(-0.13), "near")

    # L2 cafe "喫茶ミナト": pale mint plaster, awning, blade sign
    f = Facade(4.6, 10.5, "plaster_green", "left", 2.0)
    f.hole(0.25, 4.35, 0.0, 2.45)
    f.recess(0.25, 4.35, 0.0, 2.45, 0.38, floor_mat="concrete")
    m = f.mb
    m.quad("windows", v3(0.25, 0.55, -0.38), v3(2.7, 0, 0), v3(0, 1.75, 0), uv0=IA("cafe")[:2], uv1=IA("cafe")[2:])
    m.box("wood_dark", (0.25, 0.0, -0.38), (2.95, 0.55, -0.30), faces="YZ", scale=1.0)            # kick panel
    m.quad("windows", v3(3.15, 0.17, -0.38), v3(1.0, 0, 0), v3(0, 2.1, 0), uv0=(IA("cafe")[0] + 0.12, IA("cafe")[1]), uv1=(IA("cafe")[0] + 0.32, IA("cafe")[3]))
    m.box("wood_dark", (2.95, 0.0, -0.38), (3.15, 2.45, -0.30), faces="xXZ", scale=1.0)
    m.box("wood_dark", (4.15, 0.0, -0.38), (4.35, 2.45, -0.30), faces="xXZ", scale=1.0)
    for x in (0.25 + 0.9, 0.25 + 1.8):
        m.box("wood_dark", (x - 0.03, 0.55, -0.38), (x + 0.03, 2.3, -0.33), faces="xXZ", scale=1.0)
    m.box("wood_dark", (0.25, 2.3, -0.38), (4.35, 2.45, -0.30), faces="yZ", scale=1.0)
    m.bevel_box("concrete", (3.05, 0.0, -0.05), (4.25, 0.17, 0.30), 0.012, scale=1.0, faces="xXYZ")   # step
    # awning (sloped canvas + valance)
    a_h, a_d = 2.75, 0.95
    m.quad("canvas", v3(0.1, a_h, 0.02), v3(4.4, 0, 0), v3(0, -0.32, a_d), uv0=(0, 0), uv1=(4.4, 1.0))
    m.quad("canvas", v3(4.5, a_h, 0.02), v3(-4.4, 0, 0), v3(0, -0.32, a_d), uv0=(0, 0), uv1=(4.4, 1.0))
    m.quad("canvas", v3(0.1, a_h - 0.32, a_d + 0.02), v3(4.4, 0, 0), v3(0, -0.22, 0), uv0=(0, 0), uv1=(4.4, 0.25), double=True)
    m.quad("canvas", v3(0.1, a_h - 0.54, 0.02), v3(0, 0, a_d), v3(0, 0.22, 0), uv0=(0, 0), uv1=(1, 0.25), double=True)
    # menu board on the ground (A-frame)
    m.box("wood_dark", (3.0, 0.0, 0.55), (3.04, 0.95, 1.0), faces="xXyYZz", scale=0.5)
    m.quad("sign_soft", v3(2.995, 0.08, 0.57), v3(0, 0, 0.41), v3(0, 0.82, 0), uv0=SA("menu_board")[:2], uv1=SA("menu_board")[2:])
    f.blade_sign(0.25, 2.95, 4.45, 0.5, 0.12, SA("cafe_blade"), mat="sign_static")
    # upper floors
    for h in (3.6, 6.7):
        f.window(0.45, h, 1.3, 1.25, IA("upper_warm_curtain" if h < 5 else "upper_tv"))
        f.window(2.6, h, 1.3, 1.25, IA("upper_cool_blinds" if h < 5 else "upper_dark"))
    f.balcony(2.45, 4.1, 3.45)
    f.ac_unit(0.6, 5.55, pipe_to=3.4)
    f.ac_unit(2.6, 8.4)
    f.window(1.4, 9.3, 1.0, 0.8, IA("upper_lamp"))
    # bar blade sign (cyan neon, flickers) near the far end of this building
    f.blade_sign(4.25, 3.35, 5.55, 0.48, 0.14, SA("bar_blade"), mat="sign_flicker")
    f.build_wall()
    place(f, M_left(-3.3), "mid")

    # L3 bookshop "古書ふくろう堂": beige tile, half-closed shutter, sign tower
    f = Facade(5.1, 13.5, "tile_beige", "left", 2.0)
    f.hole(0.3, 3.9, 0.0, 2.6)
    f.recess(0.3, 3.9, 0.0, 2.6, 0.25, floor_mat="concrete")
    m = f.mb
    # shutter rolled down to 0.62 m, warm interior visible below
    m.wquad("shutter", v3(0.3, 0.62, -0.20), v3(3.6, 0, 0), v3(0, 1.98, 0), scale=(1.0, 1.0))
    m.box("metal_dark", (0.3, 0.58, -0.22), (3.9, 0.64, -0.12), faces="yYZ", scale=0.5)
    m.quad("windows", v3(0.3, 0.0, -0.25), v3(3.6, 0, 0), v3(0, 0.62, 0), uv0=IA("shutter_gap")[:2], uv1=IA("shutter_gap")[2:])
    m.box("metal_grey", (0.2, 2.6, -0.05), (4.0, 2.95, 0.12), faces="xXyYZ", scale=0.5)               # shutter box
    f.flat_sign(0.5, 3.7, 3.05, 3.62, SA("book_board"), mat="sign_dim", proud=0.06, frame_mat="wood_dark")
    # stacked sign tower ("zakkyo" building directory)
    for i, nm in enumerate(["stack_5", "stack_4", "stack_3", "stack_2", "stack_1"]):
        h0 = 3.0 + i * 0.86
        f.blade_sign(4.6, h0, h0 + 0.72, 0.62, 0.2, SA(nm), mat="sign_static", standoff=0.16)
    f.mb.box("metal_dark", (4.55, 2.9, 0.16), (4.65, 7.35, 0.24), faces="xXZ", scale=0.5)
    for h in (4.0, 7.2, 10.4):
        f.window(0.6, h, 1.2, 1.2, IA("upper_dark" if h == 7.2 else "upper_lamp"))
        f.window(2.2, h, 1.2, 1.2, IA("upper_warm_curtain" if h == 4.0 else "upper_cool_blinds"))
    f.ac_unit(3.6, 3.85, pipe_to=3.0)
    f.ac_unit(3.6, 6.9)
    f.pipe(4.95, 0.0, 13.3, r=0.05)
    f.build_wall()
    place(f, M_left(-7.9), "mid")
    # rooftop water tank on L3 (silhouette in low views)
    world.chunk = "mid"
    world.lathe("metal_white", v3(-3.0, G + 13.55, -10.4), [(0.0, 0.0), (0.75, 0.0), (0.78, 0.05), (0.78, 1.7), (0.7, 1.85), (0.0, 1.95)], segs=20)
    for dx in (-0.6, 0.6):
        world.box("metal_dark", (-3.0 + dx - 0.04, G + 13.35, -10.9), (-3.0 + dx + 0.04, G + 13.6, -9.9), faces="xXYZz", scale=0.5)

    # side passage between L3 and L4 (z -13.0 .. -13.9): dim red light deep inside
    world.chunk = "far"
    world.wquad("plaster_rust", v3(-6.0, G, -13.9), v3(4.55, 0, 0), v3(0, 9.0, 0), scale=(2.0, 2.0))     # faces +z
    world.wquad("brick", v3(-6.0, G, -13.0), v3(0, 0, -0.9), v3(0, 7.0, 0), scale=(2.0, 2.0))          # end wall faces +x
    world.wquad("asphalt", v3(-6.0, G, -13.0), v3(4.55, 0, 0), v3(0, 0, -0.9), scale=(4.0, 4.0))
    world.box("concrete_dark", (-6.0, G, -13.02), (XL, G + 13.5, -13.0), faces="z", scale=3.0)         # back of L3 (rarely seen)
    world.box("passage_red", (-5.3, G + 1.9, -13.88), (-4.8, G + 2.02, -13.84), faces="xXyYZ", uv_world=False)
    world.lathe("passage_red", v3(-3.4, G + 2.6, -13.80), [(0.0, -0.05), (0.04, -0.03), (0.05, 0.0), (0.04, 0.03), (0.0, 0.05)], segs=8)
    for k in range(3):
        world.cylinder("metal_dark", v3(-5.6 + k * 1.3, G + 2.6 + k * 0.3, -13.85), v3(-5.6 + k * 1.3, G + 2.6 + k * 0.3, -13.0), 0.025, segs=8, caps=False)

    # L4: closed shop, crates
    f = Facade(3.6, 9.0, "plaster_cream", "left", 2.0)
    f.hole(0.3, 2.9, 0.0, 2.5)
    f.recess(0.3, 2.9, 0.0, 2.5, 0.2)
    f.mb.wquad("shutter", v3(0.3, 0.0, -0.18), v3(2.6, 0, 0), v3(0, 2.5, 0), scale=(1.0, 1.0))
    f.flat_sign(1.3, 1.62, 1.55, 1.71, SA("eigyo"), mat="sign_dim", proud=0.004, frame_mat="metal_white")
    f.window(0.5, 3.4, 1.1, 1.1, IA("upper_lamp"))
    f.shutter_window(2.0, 3.25)
    f.window(1.2, 6.3, 1.2, 1.1, IA("upper_cool_blinds"))
    f.ac_unit(2.4, 5.4, pipe_to=2.8)
    f.build_wall()
    place(f, M_left(-13.9), "far")

    # ============================================================ RIGHT SIDE
    # R1 service: cream plaster, steel door, wall lamp (near light source)
    f = Facade(2.47, 8.5, "plaster_cream", "right", 2.0)       # s=0 at z=-2.6, s=2.47 at z=-0.13
    f.door(0.55, 0.95, 2.05, mat="metal_grey", step=True, floor=0.04)
    f.lamp(1.02, 2.5)
    f.pipe(2.25, 0.0, 8.3, r=0.05)
    f.pipe(0.2, 0.0, 8.3, r=0.035, mat="metal_dark")
    f.meter_box(1.65, 1.25, 0.34, 0.5)
    f.meter_box(1.65, 0.6, 0.34, 0.5)
    f.hpipe(0.0, 2.47, 2.95, r=0.025)
    f.window(0.7, 4.0, 1.1, 1.1, IA("upper_warm_curtain"))
    f.window(0.7, 6.6, 1.1, 1.1, IA("upper_dark"))
    f.ac_unit(1.1, 5.4, pipe_to=3.2)
    f.flat_sign(1.0, 1.55, 1.15, 1.35, SA("poster_1"), mat="sign_soft", proud=0.004, frame_mat="metal_white")
    f.security_light(0.35, 2.45)
    f.build_wall()
    place(f, M_right(-2.6), "near")

    # R2: grey tile building with vending machines + laundromat
    f = Facade(4.6, 11.0, "tile_grey", "right", 2.0)            # s=0 at z=-7.2, s=4.6 at z=-2.6
    # laundromat glass front (s 0.2 .. 2.4) and blade sign
    f.hole(0.2, 2.45, 0.0, 2.55)
    f.recess(0.2, 2.45, 0.0, 2.55, 0.15, floor_mat="concrete")
    m = f.mb
    m.quad("windows", v3(0.2, 0.25, -0.15), v3(2.25, 0, 0), v3(0, 2.15, 0), uv0=IA("laundry")[:2], uv1=IA("laundry")[2:])
    m.box("metal_grey", (0.2, 0.0, -0.15), (2.45, 0.25, -0.10), faces="YZ", scale=0.5)
    for x in (0.2, 1.3, 2.4):
        m.box("metal_grey", (x, 0.25, -0.15), (x + 0.05, 2.4, -0.11), faces="xXZ", scale=0.5)
    m.box("metal_grey", (0.2, 2.4, -0.15), (2.45, 2.55, -0.10), faces="yZ", scale=0.5)
    # LED ticker above the laundromat
    f.flat_sign(0.35, 2.3, 2.62, 2.80, (0.0, 0.0, 1.0, 1.0), mat="sign_ticker", proud=0.05)
    f.blade_sign(2.5, 3.0, 5.7, 0.42, 0.12, SA("laundry_blade"), mat="sign_static")
    # vending machines in front of the wall (s 2.6 .. 4.5)
    for k, nm in enumerate(["vending_b", "vending_a"]):
        s0 = 2.62 + k * 0.96
        m.bevel_box("metal_white", (s0, 0.04, 0.0), (s0 + 0.92, 1.86, 0.72), 0.02, scale=1.0, faces="xXYZ")
        u0, v0, u1, v1 = SA(nm)
        m.quad("vending", v3(s0 + 0.04, 0.12, 0.724), v3(0.84, 0, 0), v3(0, 1.68, 0), uv0=(u0, v0), uv1=(u1, v1))
        m.box("metal_dark", (s0 + 0.02, 1.86, 0.0), (s0 + 0.9, 1.92, 0.74), faces="xXYZ", scale=0.5)
    # recycling bin next to them
    m.bevel_box("crate_blue", (4.52, 0.04, 0.05), (4.58 + 0.0, 0.85, 0.45), 0.02, scale=0.5, faces="xXYZ")
    # upper floors
    for h in (3.3, 6.0, 8.7):
        f.window(0.4, h, 1.2, 1.2, IA("upper_cool_blinds" if h == 3.3 else ("upper_warm_curtain" if h == 6.0 else "upper_dark")))
        if h == 8.7:
            f.shutter_window(2.95, h - 0.15)
        else:
            f.window(2.9, h, 1.2, 1.2, IA("upper_lamp" if h == 6.0 else "upper_dark"))
    f.ac_unit(1.9, 3.5, pipe_to=2.9)
    f.ac_unit(1.9, 6.3)
    f.ac_unit(1.9, 9.0)
    f.balcony(2.7, 4.3, 5.85)
    f.build_wall()
    place(f, M_right(-7.2), "mid")

    # R3 izakaya "しずく": two-storey, wood front, eave, lanterns, steam vent
    f = Facade(4.6, 7.4, "plaster_rust", "right", 2.0)          # s=0 at z=-11.8 .. 4.6 at z=-7.2
    f.hole(0.3, 4.3, 0.0, 2.4)
    f.recess(0.3, 4.3, 0.0, 2.4, 0.3, floor_mat="concrete")
    m = f.mb
    m.wquad("wood_dark", v3(0.3, 0.0, -0.3), v3(1.2, 0, 0), v3(0, 2.4, 0), scale=(1.0, 1.0))
    m.quad("windows", v3(1.5, 0.75, -0.3), v3(1.3, 0, 0), v3(0, 1.3, 0), uv0=IA("izakaya")[:2], uv1=IA("izakaya")[2:])
    m.wquad("wood_dark", v3(1.5, 0.0, -0.3), v3(1.3, 0, 0), v3(0, 0.75, 0), scale=(1.0, 1.0))
    m.wquad("wood_dark", v3(1.5, 2.05, -0.3), v3(1.3, 0, 0), v3(0, 0.35, 0), scale=(1.0, 1.0))
    # entrance (s 2.9..3.9) with noren
    iu = IA("izakaya")
    m.quad("windows", v3(2.9, 0.17, -0.3), v3(1.0, 0, 0), v3(0, 2.0, 0), uv0=(iu[0] + 0.15, iu[1]), uv1=(iu[0] + 0.33, iu[3]))
    m.wquad("wood_dark", v3(3.9, 0.0, -0.3), v3(0.4, 0, 0), v3(0, 2.4, 0), scale=(1.0, 1.0))
    nu = SA("noren_izakaya")
    for k in range(3):
        s0 = 2.92 + k * 0.33
        uu0 = nu[0] + (nu[2] - nu[0]) * k / 3
        uu1 = nu[0] + (nu[2] - nu[0]) * (k + 1) / 3
        m.quad("sign_soft", v3(s0, 1.45, 0.02), v3(0.31, 0, 0), v3(0, 0.75, 0), uv0=(uu0, nu[1]), uv1=(uu1, nu[3]), double=True)
    m.box("wood_dark", (2.85, 2.18, -0.02), (3.95, 2.22, 0.05), faces="xXyYZ", scale=0.5)
    m.bevel_box("concrete", (2.85, 0.0, -0.05), (3.95, 0.17, 0.28), 0.012, scale=1.0, faces="xXYZ")
    # eave (corrugated metal hisashi)
    m.quad("corrugated", v3(0.0, 2.95, 0.0), v3(4.6, 0, 0), v3(0, -0.28, 0.8), uv0=(0, 0), uv1=(4.6, 0.85))
    m.quad("rust_metal", v3(4.6, 2.95, 0.0), v3(-4.6, 0, 0), v3(0, -0.28, 0.8), uv0=(0, 0), uv1=(4.6, 0.85))
    m.box("wood_dark", (0.0, 2.62, 0.78), (4.6, 2.70, 0.84), faces="xXyYZ", scale=1.0)
    f.blade_sign(4.45, 3.0, 5.6, 0.45, 0.12, SA("izakaya_blade"), mat="sign_static")
    # upper floor
    f.window(0.6, 3.7, 1.4, 1.05, IA("upper_warm_curtain"))
    f.window(2.7, 3.7, 1.4, 1.05, IA("upper_lamp"))
    # steam vent box
    m.bevel_box("metal_grey", (1.0, 3.05, 0.0), (1.4, 3.35, 0.25), 0.01, scale=0.5)
    f.build_wall()
    place(f, M_right(-11.8), "mid")
    world.chunk = "mid"
    # red lanterns hanging from the eave (portal space)
    lu = SA("lantern_izakaya")
    for zl in (-8.15, -10.35):
        c = v3(XR - 0.62, G + 1.95, zl)
        prof = [(0.03, -0.30), (0.17, -0.26), (0.21, -0.14), (0.22, 0.0), (0.21, 0.14), (0.17, 0.26), (0.03, 0.30)]
        world.lathe("lantern", c, prof, segs=18, u_range=(lu[0], lu[2]), v_range=(lu[1], lu[3]))
        world.cylinder("metal_dark", c + v3(0, 0.30, 0), c + v3(0, 0.62, 0), 0.006, segs=4, caps=False)
        world.lathe("rubber_black", c + v3(0, 0.27, 0), [(0.0, 0.0), (0.1, 0.0), (0.1, 0.05), (0.0, 0.05)], segs=12)
        world.lathe("rubber_black", c + v3(0, -0.32, 0), [(0.0, 0.0), (0.1, 0.0), (0.1, 0.05), (0.0, 0.05)], segs=12)
    # propane cylinders by the izakaya
    for k in range(2):
        props.place(world, "propane", (XR - 0.30, G + 0.04, -11.55 + k * 0.46), rot_y=40.0 + 75.0 * k, scale=1.3, anchor="bottom")
    # steam plume above the vent (two crossed quads)
    sv = v3(XR - 0.2, G + 3.35, -10.4)
    world.quad("steam", sv + v3(-0.45, 0, 0), v3(0.9, 0, 0), v3(0, 1.8, 0), uv0=(0, 0), uv1=(1, 1.6), double=True)
    world.quad("steam", sv + v3(0, 0, 0.45), v3(0, 0, -0.9), v3(0, 1.8, 0), uv0=(0.3, 0.2), uv1=(1.3, 1.8), double=True)

    # R4: concrete mid-rise, garage shutter, pharmacy
    f = Facade(5.7, 14.0, "concrete", "right", 3.0)            # s=0 at z=-17.5 .. 5.7 at z=-11.8
    f.hole(4.55, 5.6, 0.0, 2.3)
    f.recess(4.55, 5.6, 0.0, 2.3, 0.12)
    f.mb.wquad("shutter", v3(4.55, 0.0, -0.1), v3(1.05, 0, 0), v3(0, 2.3, 0), scale=(1.0, 1.0))
    f.hole(1.0, 4.2, 0.0, 2.5)
    f.recess(1.0, 4.2, 0.0, 2.5, 0.2, floor_mat="concrete")
    m = f.mb
    m.quad("windows", v3(1.0, 0.1, -0.2), v3(3.2, 0, 0), v3(0, 2.3, 0), uv0=IA("pharmacy")[:2], uv1=IA("pharmacy")[2:])
    for x in (1.0, 2.6, 4.15):
        m.box("metal_grey", (x, 0.0, -0.2), (x + 0.05, 2.5, -0.16), faces="xXZ", scale=0.5)
    f.flat_sign(1.1, 4.1, 2.6, 2.95, SA("tube_cool"), mat="sign_dim", proud=0.08)
    f.blade_sign(3.4, 3.1, 4.9, 0.45, 0.12, SA("pharmacy_blade"), mat="sign_static")
    for h in (3.6, 6.4, 9.2, 12.0):
        f.window(0.5, h, 1.3, 1.25, IA("upper_dark" if h in (6.4, 12.0) else "upper_cool_blinds"))
        f.window(3.2, h, 1.3, 1.25, IA("upper_lamp" if h == 9.2 else "upper_dark"))
        f.ac_unit(2.0, h + 0.2, pipe_to=h - 0.6 if h < 7 else None)
    f.pipe(5.55, 0.0, 13.8, r=0.05)
    f.utility_box(0.12, which=1)
    f.fluorescent(5.08, 2.38, 0.10)
    f.build_wall()
    place(f, M_right(-17.5), "far")

    # ============================================================ SIDE CAPS
    # where a taller building rises behind a lower one, its exposed side wall
    # faces the viewer (+z).  (left: L2 10.5 -> L3 13.5; right: R3 7.4 -> R4 14)
    world.chunk = "mid"
    world.wquad("tile_beige", v3(XL - 6.0, G + 10.5, -7.9), v3(6.0, 0, 0), v3(0, 3.0, 0), scale=(2.0, 2.0))
    world.wquad("concrete", v3(XR, G + 7.4, -11.8), v3(6.0, 0, 0), v3(0, 6.6, 0), scale=(3.0, 3.0))
    world.wquad("tile_grey", v3(XR, G + 8.5, -2.6), v3(6.0, 0, 0), v3(0, 2.5, 0), scale=(2.0, 2.0))      # R2 above R1
    world.wquad("plaster_green", v3(XL - 6.0, G + 9.5, -3.3), v3(6.0, 0, 0), v3(0, 1.0, 0), scale=(2.0, 2.0))  # L2 above L1

    # ============================================================ ARCH SIGN
    world.chunk = "mid"
    za = -6.2
    world.bevel_box("metal_dark", (XL + 0.05, G + 3.0, za - 0.08), (XR - 0.05, G + 3.62, za + 0.08), 0.02, scale=0.5)
    au = SA("arch")
    world.quad("sign_static", v3(-1.25, G + 3.04, za + 0.083), v3(2.7, 0, 0), v3(0, 0.54, 0), uv0=au[:2], uv1=au[2:])
    for k in range(13):
        x = -1.25 + k * 2.7 / 12
        world.lathe("bulb", v3(x, G + 2.93, za + 0.03), [(0.0, -0.035), (0.03, -0.025), (0.035, 0.0), (0.03, 0.025), (0.0, 0.035)], segs=8)
    for x in (XL + 0.1, XR - 0.1):
        world.box("metal_dark", (x - 0.03, G + 3.0, za - 0.03), (x + 0.03, G + 3.9, za + 0.03), faces="xXYZz", scale=0.5)

    # ============================================================ POLE + CABLES
    world.chunk = "far"
    pz, px = -12.45, XR - 0.3
    world.lathe("concrete", v3(px, G, pz), [(0.0, 0.0), (0.175, 0.0), (0.16, 9.0), (0.13, 10.6), (0.0, 10.65)], segs=16)
    tu = SA("tiger")
    world.lathe("pole_sleeve", v3(px, G, pz), [(0.185, 0.0), (0.185, 1.8)], segs=16, u_range=(tu[0], tu[2]), v_range=(tu[1], tu[3]))
    for hy in (8.6, 9.6):
        world.bevel_box("metal_grey", (px - 1.1, G + hy, pz - 0.05), (px + 0.6, G + hy + 0.09, pz + 0.05), 0.01, scale=0.5)
        for dx in (-0.95, -0.45, 0.4):
            world.lathe("metal_white", v3(px + dx, G + hy + 0.09, pz), [(0.0, 0.0), (0.04, 0.0), (0.05, 0.05), (0.03, 0.08), (0.05, 0.11), (0.0, 0.14)], segs=8)
    world.lathe("metal_grey", v3(px - 0.42, G + 7.2, pz), [(0.0, 0.0), (0.24, 0.0), (0.26, 0.04), (0.26, 0.8), (0.22, 0.88), (0.0, 0.9)], segs=16)
    for k in range(10):
        world.cylinder("metal_dark", v3(px, G + 2.2 + k * 0.45, pz), v3(px + (0.22 if k % 2 else -0.22), G + 2.2 + k * 0.45, pz), 0.012, segs=5)
    # cables: across the alley and along it
    cab = []
    for z, yl, yr, sag in ((-1.9, 4.7, 5.0, 0.35), (-2.2, 5.3, 5.2, 0.45), (-5.6, 5.8, 6.1, 0.5),
                           (-6.0, 4.9, 4.6, 0.3), (-9.3, 6.4, 6.0, 0.6), (-10.1, 5.6, 5.9, 0.4),
                           (-14.8, 6.8, 7.2, 0.5), (-15.3, 5.9, 6.3, 0.45)):
        cab.append((v3(XL + 0.05, G + yl, z), v3(XR - 0.05, G + yr, z + 0.3), sag))
    for hy in (8.6, 9.6):
        for dx in (-0.95, -0.45, 0.4):
            top = v3(px + dx, G + hy + 0.14, pz)
            cab.append((top, v3(px + dx * 0.7, G + hy + 0.5, -2.0), 0.9))
            cab.append((top, v3(px + dx * 0.6, G + hy + 0.3, Z_FAR + 0.2), 0.5))
    cab.append((v3(px - 0.3, G + 8.0, pz), v3(XL + 0.05, G + 7.0, -12.0), 0.6))
    cab.append((v3(px - 0.3, G + 7.6, pz), v3(XL + 0.05, G + 6.4, -16.5), 0.5))
    for a, b, sag in cab:
        world.tube("cable", catenary(a, b, sag, n=16), 0.009, segs=5)

    # ============================================================ NEAR CLUTTER
    world.chunk = "near"
    # stacked beer crates (left, ~1.2 m from the opening)
    for (cx, cz, lvl, mat) in ((-1.0, -1.35, 0, "crate_yellow"), (-1.0, -1.35, 1, "crate_blue"), (-0.98, -1.85, 0, "crate_blue")):
        y0 = G + lvl * 0.31
        world.bevel_box(mat, (cx - 0.21, y0, cz - 0.17), (cx + 0.21, y0 + 0.3, cz + 0.17), 0.015, scale=0.5)
        for k in range(4):
            world.box(mat, (cx - 0.22, y0 + 0.06 + k * 0.06, cz - 0.175), (cx + 0.22, y0 + 0.085 + k * 0.06, cz + 0.175), faces="xXZz", scale=0.5)
    # bin with lid (right, ~2 m)
    props.place(world, "trash_can_rust", (1.22, G + 0.04, -2.3), rot_y=-100.0, scale=0.85, anchor="bottom")
    # traffic cone near the junction
    world.chunk = "far"
    world.box("rubber_black", (-0.95, G, -15.95), (-0.55, G + 0.03, -15.55), faces="xXYZz", scale=0.5)
    world.lathe("cone", v3(-0.75, G + 0.03, -15.75), [(0.16, 0.0), (0.13, 0.25), (0.08, 0.5), (0.03, 0.68), (0.0, 0.69)], segs=14)
    props.place(world, "trash_can", (-1.12, G, -14.45), rot_y=70.0, scale=0.85, anchor="bottom")

    # ============================================================ CROSS LANE
    world.chunk = "far"
    # ramen shop facing straight down the alley (focal point)
    f = Facade(3.9, 9.5, "wood_dark", "front", 1.0)              # x -1.9 .. 2.0
    f.hole(0.25, 3.15, 0.0, 2.35)
    f.recess(0.25, 3.15, 0.0, 2.35, 0.35, floor_mat="concrete")
    m = f.mb
    m.quad("windows", v3(0.25, 0.65, -0.35), v3(1.8, 0, 0), v3(0, 1.6, 0), uv0=IA("ramen")[:2], uv1=IA("ramen")[2:])
    m.wquad("wood_dark", v3(0.25, 0.0, -0.35), v3(1.8, 0, 0), v3(0, 0.65, 0), scale=(1.0, 1.0))
    ru = IA("ramen")
    m.quad("windows", v3(2.15, 0.17, -0.35), v3(1.0, 0, 0), v3(0, 2.05, 0), uv0=(ru[0] + 0.2, ru[1]), uv1=(ru[0] + 0.38, ru[3]))
    m.box("wood_dark", (2.05, 0.0, -0.35), (2.15, 2.35, -0.28), faces="xXZ", scale=1.0)
    nu = SA("noren_ramen")
    for k in range(3):
        s0 = 2.17 + k * 0.33
        m.quad("sign_soft", v3(s0, 1.5, 0.03), v3(0.31, 0, 0), v3(0, 0.7, 0),
               uv0=(nu[0] + (nu[2] - nu[0]) * k / 3, nu[1]), uv1=(nu[0] + (nu[2] - nu[0]) * (k + 1) / 3, nu[3]), double=True)
    m.bevel_box("concrete", (2.05, 0.0, -0.05), (3.25, 0.17, 0.3), 0.012, scale=1.0, faces="xXYZ")
    f.flat_sign(0.15, 3.75, 2.5, 3.2, SA("ramen_board"), mat="sign_static", proud=0.12)
    f.flat_sign(3.15, 3.7, 3.4, 5.6, SA("ramen_vertical"), mat="sign_static", proud=0.10)
    f.window(0.4, 3.6, 1.2, 1.1, IA("upper_warm_curtain"), frame="wood_dark")
    f.window(1.85, 3.6, 1.0, 1.1, IA("upper_lamp"), frame="wood_dark")
    f.window(0.6, 6.4, 1.2, 1.1, IA("upper_dark"))
    f.window(2.2, 6.4, 1.2, 1.1, IA("upper_cool_blinds"))
    f.ac_unit(0.3, 5.4)
    # eave
    m.quad("corrugated", v3(0.0, 3.35, 0.0), v3(3.9, 0, 0), v3(0, -0.25, 0.7), uv0=(0, 0), uv1=(3.9, 0.75))
    m.quad("rust_metal", v3(3.9, 3.35, 0.0), v3(-3.9, 0, 0), v3(0, -0.25, 0.7), uv0=(0, 0), uv1=(3.9, 0.75))
    f.build_wall()
    place(f, M_front(-1.9, Z_FAR), "far")
    lu = SA("lantern_ramen")
    for xl in (-1.75, 1.9):
        c = v3(xl, G + 2.2, Z_FAR + 0.45)
        prof = [(0.03, -0.36), (0.2, -0.31), (0.25, -0.16), (0.26, 0.0), (0.25, 0.16), (0.2, 0.31), (0.03, 0.36)]
        world.lathe("lantern", c, prof, segs=18, u_range=(lu[0], lu[2]), v_range=(lu[1], lu[3]))
        world.lathe("rubber_black", c + v3(0, 0.33, 0), [(0.0, 0.0), (0.12, 0.0), (0.12, 0.05), (0.0, 0.05)], segs=12)
        world.lathe("rubber_black", c + v3(0, -0.38, 0), [(0.0, 0.0), (0.12, 0.0), (0.12, 0.05), (0.0, 0.05)], segs=12)
        world.cylinder("metal_dark", c + v3(0, 0.38, 0), c + v3(0, 1.0, -0.4), 0.008, segs=4, caps=False)

    # F0 left of the ramen shop (closed, one lit window)
    f = Facade(6.1, 8.0, "concrete", "front", 3.0)               # x -8 .. -1.9
    f.hole(0.6, 5.4, 0.0, 2.6)
    f.recess(0.6, 5.4, 0.0, 2.6, 0.15)
    f.mb.wquad("shutter", v3(0.6, 0.0, -0.13), v3(4.8, 0, 0), v3(0, 2.6, 0), scale=(1.0, 1.0))
    f.window(1.5, 3.8, 1.2, 1.1, IA("upper_lamp"))
    f.shutter_window(3.85, 3.6)
    f.ac_unit(3.0, 5.6)
    f.duct_run(0.75, 2.9, 7.9)
    f.utility_box(5.35, which=2)
    f.build_wall()
    place(f, M_front(-8.0, Z_FAR), "far")

    # F2 convenience store (bright) and F3
    f = Facade(6.5, 12.0, "tile_grey", "front", 2.0)             # x 2.0 .. 8.5
    f.hole(1.4, 6.1, 0.0, 2.7)
    f.recess(1.4, 6.1, 0.0, 2.7, 0.12, floor_mat="concrete")
    m = f.mb
    m.quad("windows", v3(1.4, 0.0, -0.12), v3(4.7, 0, 0), v3(0, 2.7, 0), uv0=IA("store")[:2], uv1=IA("store")[2:])
    for x in (1.4, 2.6, 3.8, 5.0, 6.05):
        m.box("metal_white", (x, 0.0, -0.12), (x + 0.05, 2.7, -0.08), faces="xXZ", scale=0.5)
    f.flat_sign(1.5, 6.0, 2.8, 3.5, SA("conv_store"), mat="sign_static", proud=0.15, frame_mat="metal_white")
    for h in (4.2, 7.0, 9.8):
        for s in (0.5, 2.4, 4.4):
            f.window(s, h, 1.2, 1.2, IA(["upper_dark", "upper_lamp", "upper_cool_blinds", "upper_warm_curtain"][int(s + h) % 4]))
    f.build_wall()
    place(f, M_front(2.0, Z_FAR), "far")

    f = Facade(5.5, 10.0, "plaster_cream", "front", 2.0)         # x 8.5 .. 14
    f.hole(0.5, 4.8, 0.0, 2.5)
    f.recess(0.5, 4.8, 0.0, 2.5, 0.15)
    f.mb.wquad("shutter", v3(0.5, 0.0, -0.13), v3(4.3, 0, 0), v3(0, 2.5, 0), scale=(1.0, 1.0))
    f.window(0.8, 3.6, 1.2, 1.1, IA("upper_warm_curtain"))
    f.window(3.0, 3.6, 1.2, 1.1, IA("upper_dark"))
    f.window(1.9, 6.6, 1.2, 1.1, IA("upper_tv"))
    f.build_wall()
    place(f, M_front(8.5, Z_FAR), "far")

    # lane end caps (left x=-8 facing +x, right x=14 facing -x)
    world.wquad("concrete_dark", v3(-8.0, G, Z_END), v3(0, 0, Z_FAR - Z_END), v3(0, 8.0, 0), scale=(3.0, 3.0))
    world.wquad("plaster_cream", v3(14.0, G, Z_FAR), v3(0, 0, Z_END - Z_FAR), v3(0, 10.0, 0), scale=(2.0, 2.0))
    # street lamp on the right of the junction
    world.cylinder("metal_dark", v3(3.6, G, -17.8), v3(3.6, G + 4.6, -17.8), 0.06, segs=10, caps=True)
    world.cylinder("metal_dark", v3(3.6, G + 4.6, -17.8), v3(3.6, G + 4.6, -18.5), 0.035, segs=8, caps=True)
    world.box("metal_dark", (3.45, G + 4.48, -18.75), (3.75, G + 4.62, -18.4), faces="xXYZz", scale=0.5)
    world.quad("lamp_lens", v3(3.47, G + 4.475, -18.73), v3(0.26, 0, 0), v3(0, 0, 0.31), uv0=SA("lamp_led")[:2], uv1=SA("lamp_led")[2:])

    # ============================================================ BACK CAP
    # Only shown for floor / ceiling portals (chunk "backcap"): a wall-mounted
    # doorway IS the alley's open end, but looking down or up from the middle
    # of the alley the user can see back toward it.  0.42 m behind the
    # doorway plane so recesses and coping keep the occluder invariant.
    f = Facade(XR - XL, 12.0, "plaster_cream", "front", 2.0)
    f.door(1.15, 1.0, 2.05, mat="metal_grey", step=False, floor=0.12)
    f.lamp(1.65, 2.45)
    f.window(0.35, 3.5, 1.0, 1.1, IA("upper_dark"))
    f.window(1.85, 3.5, 1.0, 1.1, IA("upper_warm_curtain"))
    f.ac_unit(0.3, 5.3, pipe_to=3.0)
    f.shutter_window(1.9, 6.1)
    f.window(0.35, 8.6, 1.0, 1.1, IA("upper_lamp"))
    f.pipe(2.95, 0.0, 11.8, r=0.05)
    f.build_wall()
    world.merge(f.mb, frame_matrix(v3(-1, 0, 0), v3(0, 1, 0), v3(0, 0, -1), v3(XR, G, -0.42)), chunk="backcap")

    # ============================================================ BEYOND
    world.chunk = "distant"
    # B1 behind the ramen shop, T1 further, plus towers
    def tower(x0, x1, z, h, gain_mat="far_windows", top_light=False):
        world.quad(gain_mat, v3(x0, G, z), v3(x1 - x0, 0, 0), v3(0, h, 0), uv0=(0, 0), uv1=((x1 - x0) / 12.0, h / 12.0))
        world.box("concrete_dark", (x0, G + h, z - 0.4), (x1, G + h + 0.6, z), faces="xXYZ", scale=4.0)
        if top_light:
            cx = (x0 + x1) / 2
            world.box("aviation", (cx - 0.25, G + h + 0.6, z - 0.25), (cx + 0.25, G + h + 1.1, z + 0.25), faces="xXYZz", uv_world=False)
    tower(-6.0, 5.5, -24.0, 17.0)
    tower(-3.0, 6.0, -31.0, 31.0, top_light=True)
    tower(-14.0, -6.5, -38.0, 44.0, top_light=True)
    tower(8.0, 16.0, -42.0, 52.0, top_light=True)
    tower(-2.0, 7.0, -60.0, 62.0, top_light=True)
    tower(16.0, 26.0, -55.0, 36.0)
    tower(-24.0, -15.0, -52.0, 30.0)
    # side faces of the near towers (seen at oblique angles)
    for x0, x1, z, h, dep in ((-6.0, 5.5, -24.0, 17.0, 6.0), (-3.0, 6.0, -31.0, 31.0, 8.0)):
        world.quad("far_windows", v3(x0, G, z - dep), v3(0, 0, dep), v3(0, h, 0), uv0=(0, 0), uv1=(dep / 12, h / 12))
        world.quad("far_windows", v3(x1, G, z), v3(0, 0, -dep), v3(0, h, 0), uv0=(0, 0), uv1=(dep / 12, h / 12))

    # sky dome (front hemisphere, inward facing) radius 95
    world.chunk = "sky"
    R = 95.0
    na, ne = 40, 16
    P, N, UV, I = [], [], [], []
    for j in range(ne + 1):
        el = math.radians(-5 + 90 * j / ne)
        for i in range(na + 1):
            az = math.radians(-84 + 168 * i / na)
            d = v3(math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el))
            P.append(v3(0, G, 0) + d * R)
            N.append(-d)
            UV.append((i / na, j / ne))
    for j in range(ne):
        for i in range(na):
            a = j * (na + 1) + i
            b = a + na + 1
            I += [a, a + 1, b + 1, a, b + 1, b]
    world.tri_batch("sky", P, N, UV, I)
    world._fix_winding_last("sky")

    # ============================================================ RAIN LAYERS
    world.chunk = "rain"
    for k, (z, x0, x1) in enumerate(((-1.25, -1.4, 1.6), (-2.9, -1.4, 1.6), (-5.6, -1.4, 1.6), (-9.8, -1.4, 1.6), (-15.6, -1.4, 1.6), (-18.7, -6.0, 9.0))):
        world.quad(f"rain_{k}", v3(x0, G, z), v3(x1 - x0, 0, 0), v3(0, 7.0, 0), uv0=(x0 / 1.6, 0), uv1=(x1 / 1.6, 7.0 / 6.0))

    return world


# Point lights in portal space: (name, position, linear colour, intensity, radius, flicker id)
# flicker ids: 0 steady, 1 neon stutter, 2 slow breathe, 3 car sweep (position animated)
LIGHTS = [
    ("cafe_window",   (-1.00, 1.15, -5.05), (1.00, 0.60, 0.28), 1.55, 4.5, 0),
    ("vending",       (0.86, 0.95, -3.65),  (0.72, 0.86, 1.00), 1.30, 3.4, 0),
    ("laundromat",    (1.25, 1.45, -5.95),  (0.78, 0.94, 1.00), 1.35, 4.2, 0),
    ("lanterns",      (1.00, 1.90, -9.20),  (1.00, 0.30, 0.10), 1.70, 3.8, 2),
    ("izakaya",       (1.30, 1.00, -9.90),  (1.00, 0.58, 0.26), 1.10, 3.4, 0),
    ("bar_neon",      (-0.90, 4.30, -7.55), (0.22, 0.85, 1.00), 2.10, 4.4, 1),
    ("bookshop",      (-1.10, 0.30, -10.4), (1.00, 0.60, 0.30), 1.10, 2.8, 0),
    ("sign_stack",    (-0.85, 5.00, -11.4), (1.00, 0.26, 0.62), 2.00, 5.0, 0),
    ("ramen_front",   (0.00, 1.40, -19.45), (1.00, 0.64, 0.33), 2.70, 6.5, 0),
    ("ramen_sign",    (1.45, 4.40, -19.55), (1.00, 0.16, 0.10), 1.50, 4.8, 0),
    ("street_lamp",   (3.60, 4.30, -18.55), (0.80, 0.90, 1.00), 2.00, 8.0, 0),
    ("pharmacy",      (1.30, 2.40, -14.70), (0.42, 1.00, 0.76), 1.40, 4.4, 0),
    ("near_lamp",     (1.32, 2.45, -1.60),  (1.00, 0.68, 0.38), 1.05, 3.4, 0),
    ("arch_bulbs",    (0.15, 2.80, -6.10),  (1.00, 0.72, 0.40), 1.30, 3.8, 0),
    ("store",         (5.80, 1.40, -19.30), (0.90, 0.97, 1.00), 2.00, 6.0, 0),
    ("car_sweep",     (12.0, 0.70, -18.70), (1.00, 0.94, 0.84), 3.20, 7.5, 3),
]
