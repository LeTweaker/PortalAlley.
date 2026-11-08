"""
Doorway frame geometry.

Design: a restrained, freestanding "aperture" doorway.  Dark brushed-metal
body with a graphite ceramic front face, beveled edges catching room light,
a stepped inner reveal with a narrow lip (the actual aperture), a recessed
cyan light channel on the front face, a machined threshold, splayed feet with
bolts, a control module with vents on the right jamb, a fin array on the head
and finished rear panels (the doorway is meant to be seen from behind too).

All numbers in metres, portal space (see meshkit).
"""
import math

import numpy as np

from meshkit import MeshBuilder, v3, norm

# ---------------------------------------------------------------- dimensions
OPEN_HALF_W = 0.48          # clear opening is 0.96 m wide
OPEN_Y0 = 0.03              # top of threshold
OPEN_Y1 = 2.05              # underside of head lip -> 2.02 m clear height
JAMB_HALF = 0.085           # half profile width
DEPTH_HALF = 0.12           # frame depth 0.24 m
JAMB_CX = OPEN_HALF_W + JAMB_HALF          # 0.565 centre line of jamb
HEAD_CY = OPEN_Y1 + JAMB_HALF              # 2.135 centre line of head
OUTER_HALF_W = JAMB_CX + JAMB_HALF         # 0.65 -> 1.30 m overall width
OUTER_TOP = HEAD_CY + JAMB_HALF            # 2.22 m overall height

FRAME_BACK_Z = -DEPTH_HALF                 # -0.12
APERTURE_PANEL_Z = -0.1225                 # animated occluder leaves
OCCLUDER_Z = -0.125                        # big occluder wall
# Occluder hole: everything a ray can reach through the frame at the back plane
# lies within |x| <= 0.506; the 1 cm extra margin is hidden behind the frame's
# opaque back face, so the mask edge is never visible.
HOLE_HALF_W = 0.515
HOLE_Y0 = -0.05
HOLE_Y1 = 2.085

# Cross-section profile, CCW in (a = outward from the opening, b = toward room)
# with the material of every segment.  a = -JAMB_HALF is the opening edge.
PROFILE = [
    (-0.060, -0.120),   # 0 back, inner chamfer end
    (0.074, -0.120),    # 1 back face
    (0.085, -0.109),    # 2 back outer chamfer
    (0.085, 0.088),     # 3 outer side
    (0.081, 0.104),     # 4 front outer bevel
    (0.071, 0.115),     # 5
    (0.056, 0.120),     # 6 front face (ceramic)
    (0.021, 0.120),     # 7 groove edge
    (0.017, 0.1135),    # 8 groove wall
    (-0.005, 0.1135),   # 9 groove floor
    (-0.009, 0.120),    # 10 groove wall
    (-0.041, 0.120),    # 11 front face (ceramic)
    (-0.056, 0.115),    # 12 inner front bevel
    (-0.065, 0.101),    # 13
    (-0.065, 0.036),    # 14 inner reveal (front)
    (-0.085, 0.026),    # 15 lip chamfer
    (-0.085, -0.026),   # 16 lip (the aperture edge)
    (-0.065, -0.036),   # 17 lip chamfer
    (-0.065, -0.106),   # 18 inner reveal (back)
    (-0.060, -0.120),   # 19 close
]
PROFILE_MATS = [
    "frame_body",      # 0-1 back face
    "frame_trim",      # 1-2
    "frame_body",      # 2-3 outer side
    "frame_trim",      # 3-4
    "frame_trim",      # 4-5
    "frame_trim",      # 5-6
    "frame_ceramic",   # 6-7
    "frame_body",      # 7-8
    "frame_body",      # 8-9 groove floor (light strip sits here)
    "frame_body",      # 9-10
    "frame_ceramic",   # 10-11
    "frame_trim",      # 11-12
    "frame_trim",      # 12-13
    "frame_ceramic",   # 13-14 reveal
    "frame_trim",      # 14-15
    "frame_trim",      # 15-16 lip
    "frame_trim",      # 16-17
    "frame_ceramic",   # 17-18 reveal
    "frame_trim",      # 18-19
]


def u_path(inset=0.0):
    """U path around the opening: left jamb up, head across, right jamb down.
    side vectors carry the 90-degree miter (length sqrt 2 at the corners)."""
    up = v3(0, 0, 1)
    cx, cy = JAMB_CX, HEAD_CY
    return [
        (v3(-cx, 0.0, 0), v3(-1, 0, 0), up),
        (v3(-cx, cy, 0), v3(-1, 1, 0), up),
        (v3(cx, cy, 0), v3(1, 1, 0), up),
        (v3(cx, 0.0, 0), v3(1, 0, 0), up),
    ]


def hex_bolt(mb, mat, p, n, r=0.008, h=0.006):
    """Small hex-head bolt at p pointing along n."""
    mb.cylinder(mat, p, np.asarray(p) + norm(n) * h, r, segs=6, caps=True)


def build_frame():
    mb = MeshBuilder()
    mb.chunk = "frame"

    # --- main body: profile swept around the U
    mb.sweep_flat(PROFILE, PROFILE_MATS, u_path(), uv_scale=0.5)

    # --- light channel strip (sits in the groove, 1.5 mm proud of the floor)
    strip = [(-0.003, 0.1150), (0.015, 0.1150)]
    # sweep a single flat segment facing +z: profile from a=0.015 to -0.003 so
    # the 2D normal (db,-da) points +b (toward the room)
    mb.sweep_flat([(0.015, 0.1150), (-0.003, 0.1150)], ["frame_light"], u_path(), uv_scale=1.0)

    # --- threshold (sill) between the jambs: machined plate with chamfers
    x0, x1 = -OPEN_HALF_W - 0.002, OPEN_HALF_W + 0.002
    sill_prof = [(-0.120, 0.0), (-0.120, 0.022), (-0.112, OPEN_Y0), (0.112, OPEN_Y0), (0.120, 0.022), (0.120, 0.0)]
    # build as extruded polygon along x: faces
    for k in range(len(sill_prof) - 1):
        (za, ya), (zb, yb) = sill_prof[k], sill_prof[k + 1]
        o = v3(x1, ya, za)
        u = v3(x0 - x1, 0, 0)          # -x so that u x v points outward
        v = v3(0, yb - ya, zb - za)
        mat = "frame_trim" if k in (1, 2, 3) else "frame_body"
        mb.wquad(mat, o, u, v, scale=(0.5, 0.5))
    # grip grooves on the sill top (thin dark inlays) + cyan accent line
    for zc in (-0.07, -0.035, 0.035, 0.07):
        mb.quad("frame_detail", v3(x0 + 0.03, OPEN_Y0 + 0.0008, zc + 0.004), v3(x1 - x0 - 0.06, 0, 0), v3(0, 0, -0.008))
    mb.quad("frame_light", v3(x0 + 0.05, OPEN_Y0 + 0.0009, 0.0025), v3(x1 - x0 - 0.10, 0, 0), v3(0, 0, -0.005))
    # sill end caps are hidden inside the jambs.

    # --- feet: L-shaped base plates under each jamb (forward + outward), bolted.
    # Nothing may extend behind the aperture plane: the depth-only occluder at
    # OCCLUDER_Z would clip it, so the feet stop flush with the frame's back.
    for sx in (-1, 1):
        cx = sx * JAMB_CX
        xin, xout = cx - sx * 0.11, cx + sx * 0.24
        x0, x1 = min(xin, xout), max(xin, xout)
        mb.bevel_box("frame_body", (x0, 0.0, FRAME_BACK_Z + 0.002), (x1, 0.024, 0.215), 0.006, scale=0.5)
        # front gusset and outer gusset
        mb.bevel_box("frame_trim", (cx - 0.03, 0.024, 0.12), (cx + 0.03, 0.075, 0.19), 0.004, scale=0.3)
        gx = cx + sx * OUTER_HALF_W - cx  # outer face offset
        ox0, ox1 = (sx * OUTER_HALF_W, sx * (OUTER_HALF_W + 0.075))
        mb.bevel_box("frame_trim", (min(ox0, ox1), 0.024, -0.03), (max(ox0, ox1), 0.075, 0.03), 0.004, scale=0.3)
        for (bx, bz) in ((cx - sx * 0.07, 0.165), (cx + sx * 0.07, 0.165), (cx + sx * 0.19, 0.12), (cx + sx * 0.19, -0.07)):
            hex_bolt(mb, "frame_bolt", v3(bx, 0.024, bz), v3(0, 1, 0))
        # rubber pad line where the foot meets the floor
        mb.box("frame_detail", (x0 - 0.003, 0.0, FRAME_BACK_Z + 0.0015), (x1 + 0.003, 0.004, 0.218), faces="xXZ", scale=0.2)

    # --- corner brackets on the front face (outer corners), with bolts
    for sx in (-1, 1):
        bx = sx * (OUTER_HALF_W - 0.045)
        mb.bevel_box("frame_trim", (bx - 0.035, OUTER_TOP - 0.085, 0.120), (bx + 0.035, OUTER_TOP - 0.015, 0.128), 0.003, scale=0.2)
        hex_bolt(mb, "frame_bolt", v3(bx, OUTER_TOP - 0.05, 0.128), v3(0, 0, 1), r=0.006, h=0.004)
        mb.bevel_box("frame_trim", (bx - 0.035, 0.10, 0.120), (bx + 0.035, 0.17, 0.128), 0.003, scale=0.2)
        hex_bolt(mb, "frame_bolt", v3(bx, 0.135, 0.128), v3(0, 0, 1), r=0.006, h=0.004)

    # --- control module on the right jamb's outer side (+x face at x=0.65)
    xo = OUTER_HALF_W
    mb.bevel_box("frame_trim", (xo - 0.004, 1.05, -0.07), (xo + 0.022, 1.42, 0.07), 0.004, scale=0.3)
    # vent slots (dark inlays, slightly proud)
    for i in range(7):
        y = 1.10 + i * 0.026
        mb.quad("frame_detail", v3(xo + 0.0225, y, 0.045), v3(0, 0, -0.09), v3(0, 0.010, 0))
    # status LED (amber) and two cyan pips
    mb.quad("frame_led", v3(xo + 0.0226, 1.335, 0.010), v3(0, 0, -0.020), v3(0, 0.010, 0))
    mb.quad("frame_light", v3(xo + 0.0226, 1.375, 0.032), v3(0, 0, -0.010), v3(0, 0.006, 0))
    mb.quad("frame_light", v3(xo + 0.0226, 1.375, -0.022), v3(0, 0, -0.010), v3(0, 0.006, 0))
    hex_bolt(mb, "frame_bolt", v3(xo + 0.022, 1.07, 0.05), v3(1, 0, 0), r=0.005, h=0.003)
    hex_bolt(mb, "frame_bolt", v3(xo + 0.022, 1.07, -0.05), v3(1, 0, 0), r=0.005, h=0.003)
    hex_bolt(mb, "frame_bolt", v3(xo + 0.022, 1.40, 0.05), v3(1, 0, 0), r=0.005, h=0.003)
    hex_bolt(mb, "frame_bolt", v3(xo + 0.022, 1.40, -0.05), v3(1, 0, 0), r=0.005, h=0.003)
    # conduit from module down to the foot
    pts = [v3(xo + 0.012, 1.05, -0.04), v3(xo + 0.012, 0.30, -0.04), v3(xo + 0.03, 0.12, -0.04), v3(xo + 0.05, 0.03, -0.04)]
    mb.tube("frame_detail", pts, 0.009, segs=8)

    # --- heat-sink fin array on top of the head
    for i in range(11):
        x = -0.30 + i * 0.06
        mb.bevel_box("frame_body", (x - 0.004, OUTER_TOP, -0.07), (x + 0.004, OUTER_TOP + 0.032, 0.07), 0.0015, scale=0.2)
    mb.bevel_box("frame_trim", (-0.33, OUTER_TOP, -0.085), (0.33, OUTER_TOP + 0.008, 0.085), 0.002, scale=0.3)

    # --- rear panels (recessed look): proud plates on the back face with screws
    zb = FRAME_BACK_Z
    for sx in (-1, 1):
        cx = sx * JAMB_CX
        mb.bevel_box("frame_trim", (cx - 0.055, 0.30, zb - 0.0025), (cx + 0.055, 1.85, zb + 0.0005), 0.001, scale=0.4)
        for y in (0.33, 1.82):
            hex_bolt(mb, "frame_bolt", v3(cx, y, zb - 0.0025), v3(0, 0, -1), r=0.005, h=0.0018)
    mb.bevel_box("frame_trim", (-0.42, HEAD_CY - 0.055, zb - 0.0025), (0.42, HEAD_CY + 0.055, zb + 0.0005), 0.001, scale=0.4)
    for x in (-0.39, 0.39):
        hex_bolt(mb, "frame_bolt", v3(x, HEAD_CY, zb - 0.0025), v3(0, 0, -1), r=0.005, h=0.0018)

    return mb


def build_occluders():
    """Depth-only geometry.  'occluder_wall' is a huge plane at OCCLUDER_Z with
    a rectangular hole; the alley is only visible through the hole."""
    mb = MeshBuilder()
    mb.chunk = "occluder"
    W, Y0, Y1 = 220.0, -6.0, 160.0
    z = OCCLUDER_Z
    hw, hy0, hy1 = HOLE_HALF_W, HOLE_Y0, HOLE_Y1
    rects = [
        (-W, Y0, -hw, Y1),      # left of hole
        (hw, Y0, W, Y1),        # right of hole
        (-hw, Y0, hw, hy0),     # below
        (-hw, hy1, hw, Y1),     # above
    ]
    for x0, y0, x1, y1 in rects:
        mb.quad("occluder", v3(x0, y0, z), v3(x1 - x0, 0, 0), v3(0, y1 - y0, 0))
    return mb


def build_aperture_leaf():
    """Unit leaf (1 x 1, origin at its inner edge, extending to +x) used for the
    animated aperture: the app scales/positions two of these at APERTURE_PANEL_Z."""
    mb = MeshBuilder()
    mb.chunk = "leaf"
    mb.quad("occluder", v3(0, 0, 0), v3(1, 0, 0), v3(0, 1, 0))
    return mb


def build_contact_shadow():
    mb = MeshBuilder()
    mb.chunk = "shadow"
    # 2.2 x 1.1 m soft shadow quad centred on the doorway, 2 mm above the floor
    mb.quad("contact_shadow", v3(-1.1, 0.002, 0.55), v3(2.2, 0, 0), v3(0, 0, -1.1), uv0=(0, 0), uv1=(1, 1))
    return mb


def build_spill():
    mb = MeshBuilder()
    mb.chunk = "spill"
    # light spill on the real floor in front of the opening (optional, subtle)
    mb.quad("spill", v3(-0.9, 0.003, 1.6), v3(1.8, 0, 0), v3(0, 0, -1.55), uv0=(0, 0), uv1=(1, 1))
    return mb


def build_veil():
    mb = MeshBuilder()
    mb.chunk = "veil"
    # Between the aperture leaves (-0.1225) and the occluder wall (-0.125): the
    # closed leaves hide it (so a closed doorway shows the real room, never a
    # haze), while in the opened area it sits in front of the whole alley.
    z = APERTURE_PANEL_Z - 0.001
    mb.quad("veil", v3(-HOLE_HALF_W, HOLE_Y0, z), v3(2 * HOLE_HALF_W, 0, 0), v3(0, HOLE_Y1 - HOLE_Y0, 0), uv0=(0, 0), uv1=(1, 1))
    return mb


def build_seam():
    """Opening-animation seam: a thin vertical light line in the aperture."""
    mb = MeshBuilder()
    mb.chunk = "seam"
    z = APERTURE_PANEL_Z + 0.0015     # between the leaves and the frame's back face
    mb.quad("seam", v3(-0.5, OPEN_Y0, z), v3(1.0, 0, 0), v3(0, OPEN_Y1 - OPEN_Y0, 0), uv0=(0, 0), uv1=(1, 1))
    return mb


def build_preview_footprint():
    """Placement preview: floor footprint outline + facing chevron (unit metres)."""
    mb = MeshBuilder()
    mb.chunk = "footprint"
    t = 0.012
    x0, x1, z0, z1 = -0.72, 0.72, -0.24, 0.24
    y = 0.004
    for (a, b) in [((x0, z0), (x1, z0)), ((x1, z0), (x1, z1)), ((x1, z1), (x0, z1)), ((x0, z1), (x0, z0))]:
        a = v3(a[0], y, a[1]); b = v3(b[0], y, b[1])
        d = b - a
        side = norm(np.cross(v3(0, 1, 0), d)) * t
        mb.quad("footprint", a - side, d, 2 * side) if np.dot(np.cross(d, 2 * side), v3(0, 1, 0)) > 0 else mb.quad("footprint", a + side, d, -2 * side)
    # chevron pointing toward the room (+z): the side you look through
    for sx in (-1, 1):
        a = v3(0, y, 0.75)
        b = v3(sx * 0.22, y, 0.55)
        d = b - a
        side = norm(np.cross(v3(0, 1, 0), d)) * t
        if np.dot(np.cross(d, 2 * side), v3(0, 1, 0)) > 0:
            mb.quad("footprint", a - side, d, 2 * side)
        else:
            mb.quad("footprint", a + side, d, -2 * side)
    return mb


DIMENSIONS = dict(
    openHalfWidth=OPEN_HALF_W, openY0=OPEN_Y0, openY1=OPEN_Y1,
    outerHalfWidth=OUTER_HALF_W, outerTop=OUTER_TOP,
    frameBackZ=FRAME_BACK_Z, frameFrontZ=DEPTH_HALF,
    apertureLeafZ=APERTURE_PANEL_Z, occluderZ=OCCLUDER_Z,
    holeHalfWidth=HOLE_HALF_W, holeY0=HOLE_Y0, holeY1=HOLE_Y1,
    veilZ=APERTURE_PANEL_Z - 0.001, seamZ=APERTURE_PANEL_Z + 0.0015,
)

