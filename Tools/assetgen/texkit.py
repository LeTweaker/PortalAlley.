"""
Procedural, tileable material textures.

Albedo textures are sRGB.  "Packed" textures are linear:
    R = roughness, G = ambient occlusion / cavity, B = material mask
        (wet streaks, puddle micro-variation, emissive mask ...)
Each texture lists the real-world size one repeat covers (metres) so the
geometry's world-anchored UVs keep a consistent texel density.
"""
import math

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, zoom


def rng(seed):
    return np.random.default_rng(seed)


def periodic_noise(size, cells, seed, octaves=4, persistence=0.5, aspect=(1, 1)):
    """Tileable fBm in [0, 1].  size=(h, w); cells = base grid cells (per axis
    scaled by aspect)."""
    h, w = (size, size) if np.isscalar(size) else size
    r = rng(seed)
    out = np.zeros((h, w))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        ch = max(2, int(cells * aspect[0] * 2 ** o))
        cw = max(2, int(cells * aspect[1] * 2 ** o))
        g = r.random((ch, cw))
        up = zoom(g, (h / ch, w / cw), order=3, mode="grid-wrap", grid_mode=True)
        out += amp * up[:h, :w]
        tot += amp
        amp *= persistence
    out /= tot
    out -= out.min()
    out /= out.max() + 1e-9
    return out


def to_img(a, mode="RGB"):
    a = np.clip(a, 0, 1)
    if a.ndim == 2:
        return Image.fromarray((a * 255 + 0.5).astype(np.uint8), "L")
    return Image.fromarray((a * 255 + 0.5).astype(np.uint8), mode)


def lin2srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def packed(rough, ao, mask):
    return to_img(np.stack([rough, ao, mask], -1))


def streaks(size, seed, density=60, length=(0.1, 0.6)):
    """Tileable vertical run-off streaks (0..1)."""
    h, w = size
    r = rng(seed)
    m = np.zeros((h, w))
    for _ in range(density):
        x = r.integers(0, w)
        y = r.integers(0, h)
        L = int(r.uniform(*length) * h)
        wdt = r.integers(1, 4)
        strength = r.uniform(0.3, 1.0)
        ys = (y + np.arange(L)) % h
        fade = np.linspace(1, 0, L) ** 1.5 * strength
        for dx in range(wdt):
            m[ys, (x + dx) % w] = np.maximum(m[ys, (x + dx) % w], fade)
    m = gaussian_filter(m, (2, 1.2), mode="wrap")
    return np.clip(m / (m.max() + 1e-9), 0, 1)


# ---------------------------------------------------------------- alley
def tile_wall(n=1024, seed=1):
    """Glazed rectangular facade tiles (2.0 m repeat, 9 x 30 tiles, running bond)."""
    cols, rows = 9, 30
    r = rng(seed)
    yy, xx = np.mgrid[0:n, 0:n] / n
    row = np.floor(yy * rows).astype(int)
    off = (row % 2) * 0.5 / cols
    u = (xx + off) % 1.0
    col = np.floor(u * cols).astype(int)
    fu = (u * cols) % 1.0
    fv = (yy * rows) % 1.0
    gw_u = 0.035 * 1.0
    gw_v = 0.10
    grout = (fu < gw_u) | (fu > 1 - gw_u) | (fv < gw_v) | (fv > 1 - gw_v)
    edge = np.minimum(np.minimum(fu, 1 - fu) / 0.12, np.minimum(fv, 1 - fv) / 0.3)
    edge = np.clip(edge, 0, 1)
    tile_rand = r.random((rows, cols + 1))
    tv = tile_rand[row % rows, col % (cols + 1)]
    noise = periodic_noise(n, 8, seed + 1, 5)
    grime = periodic_noise(n, 3, seed + 2, 3)
    st = streaks((n, n), seed + 3, 90)
    base = 0.78 + (tv - 0.5) * 0.16 + (noise - 0.5) * 0.06
    base = base * (1 - 0.25 * grime) * (1 - 0.35 * st)
    alb = np.stack([base * 1.0, base * 0.98, base * 0.94], -1)
    alb[grout] = np.stack([0.42 - 0.1 * grime[grout]] * 3, -1) * np.array([1, 0.98, 0.95])
    alb *= (0.85 + 0.15 * edge)[..., None]
    rough = np.where(grout, 0.9, 0.22 + 0.25 * grime + 0.2 * st)
    ao = np.where(grout, 0.55, 0.75 + 0.25 * edge)
    mask = np.clip(st * 0.8 + 0.2 * noise, 0, 1)
    return to_img(lin2srgb(alb ** 1.0 * 0.85)), packed(rough, ao, mask)


def concrete(n=1024, seed=10):
    """Board-formed concrete, 3.0 m repeat, seams every 1.5 m, tie holes 0.75 m."""
    yy, xx = np.mgrid[0:n, 0:n] / n
    n1 = periodic_noise(n, 4, seed, 6)
    n2 = periodic_noise(n, 24, seed + 1, 3)
    stains = periodic_noise(n, 2, seed + 2, 3)
    st = streaks((n, n), seed + 3, 70, (0.15, 0.7))
    base = 0.50 + (n1 - 0.5) * 0.18 + (n2 - 0.5) * 0.08 - 0.18 * stains ** 2 - 0.22 * st
    seam_h = np.abs(((yy * 2) % 1.0) - 0.5) > 0.497
    seam_v = np.abs(((xx * 2) % 1.0) - 0.5) > 0.4975
    tx = (xx * 4) % 1.0 - 0.5
    ty = (yy * 4) % 1.0 - 0.5
    hole = (tx ** 2 + ty ** 2) < 0.012 ** 2 * 16
    base = np.where(seam_h | seam_v, base * 0.55, base)
    base = np.where(hole, 0.12, base)
    alb = np.stack([base, base * 0.99, base * 0.97], -1)
    rough = np.clip(0.78 + 0.15 * n2 - 0.25 * st, 0, 1)
    ao = np.where(seam_h | seam_v | hole, 0.45, 0.9 + 0.1 * n1)
    return to_img(lin2srgb(alb * 0.8)), packed(rough, ao, st)


def plaster(n=512, seed=20):
    n1 = periodic_noise(n, 6, seed, 6)
    n2 = periodic_noise(n, 40, seed + 1, 2)
    st = streaks((n, n), seed + 2, 40, (0.2, 0.8))
    r = rng(seed + 3)
    crack = np.zeros((n, n))
    for _ in range(5):
        x, y = r.integers(0, n, 2)
        ang = r.uniform(0, 2 * math.pi)
        for _ in range(r.integers(60, 200)):
            ang += r.normal(0, 0.35)
            x = (x + math.cos(ang) * 2) % n
            y = (y + math.sin(ang) * 2) % n
            crack[int(y), int(x)] = 1
    crack = gaussian_filter(crack, 0.6, mode="wrap")
    crack = np.clip(crack * 3, 0, 1)
    base = 0.80 + (n1 - 0.5) * 0.12 + (n2 - 0.5) * 0.05 - 0.25 * st - 0.35 * crack
    alb = np.stack([base] * 3, -1)
    rough = np.clip(0.88 - 0.25 * st, 0, 1)
    ao = 1 - 0.5 * crack
    return to_img(lin2srgb(alb * 0.85)), packed(rough, ao, st)


def metal_panel(n=512, seed=30):
    """Painted sheet metal, 1.0 m repeat, seams at 0.5 m, scratches, rust bloom."""
    yy, xx = np.mgrid[0:n, 0:n] / n
    n1 = periodic_noise(n, 5, seed, 5)
    rust = np.clip((periodic_noise(n, 6, seed + 1, 5) - 0.68) * 4, 0, 1)
    r = rng(seed + 2)
    scr = np.zeros((n, n))
    for _ in range(140):
        x, y = r.integers(0, n, 2)
        L = r.integers(5, 40)
        ang = r.uniform(-0.3, 0.3) + (0 if r.random() < 0.6 else math.pi / 2)
        for t in range(L):
            scr[int(y + math.sin(ang) * t) % n, int(x + math.cos(ang) * t) % n] = r.uniform(0.4, 1)
    scr = gaussian_filter(scr, 0.5, mode="wrap")
    seam = (np.abs(((xx * 2) % 1.0) - 0.5) > 0.496) | (np.abs(((yy * 2) % 1.0) - 0.5) > 0.496)
    base = 0.72 + (n1 - 0.5) * 0.1
    alb = np.stack([base, base, base], -1)
    alb = alb * (1 - 0.35 * scr[..., None])
    rust_col = np.array([0.32, 0.16, 0.08])
    alb = alb * (1 - rust[..., None]) + rust_col * rust[..., None]
    alb[seam] *= 0.5
    rough = np.clip(0.42 + 0.3 * rust + 0.15 * n1 - 0.1 * scr, 0, 1)
    ao = np.where(seam, 0.45, 1.0)
    return to_img(lin2srgb(alb * 0.85)), packed(rough, ao, rust)


def shutter(n=512, seed=40):
    """Rolling shutter: 12 slats per metre."""
    yy, xx = np.mgrid[0:n, 0:n] / n
    f = (yy * 12) % 1.0
    prof = 0.55 + 0.35 * np.sin(f * math.pi) - 0.45 * (f > 0.9)
    n1 = periodic_noise(n, 4, seed, 5)
    st = streaks((n, n), seed + 1, 30)
    base = prof * (0.75 + 0.2 * n1) * (1 - 0.3 * st)
    alb = np.stack([base, base, base * 1.02], -1)
    rough = np.clip(0.5 + 0.2 * n1, 0, 1)
    ao = np.where(f > 0.88, 0.4, 0.95)
    return to_img(lin2srgb(alb * 0.75)), packed(rough, ao, st)


def wood(n=512, seed=50):
    """Vertical dark-stained boards, 10 per metre."""
    yy, xx = np.mgrid[0:n, 0:n] / n
    board = np.floor(xx * 10).astype(int)
    fb = (xx * 10) % 1.0
    r = rng(seed)
    bv = r.random(11)[board]
    grain = periodic_noise((n, n), 3, seed + 1, 5, aspect=(1, 12))
    base = 0.36 + (bv - 0.5) * 0.12 + (grain - 0.5) * 0.18
    gap = (fb < 0.03) | (fb > 0.97)
    alb = np.stack([base * 1.0, base * 0.66, base * 0.42], -1)
    alb[gap] *= 0.25
    rough = np.where(gap, 0.9, 0.55 + 0.2 * grain)
    ao = np.where(gap, 0.3, 1.0)
    return to_img(lin2srgb(alb * 0.7)), packed(rough, ao, grain * 0)


def canvas_stripe(n=512, seed=60):
    """Awning canvas: deep green / cream stripes, 8 per metre."""
    yy, xx = np.mgrid[0:n, 0:n] / n
    stripe = (np.floor(xx * 8) % 2).astype(bool)
    weave = 0.92 + 0.08 * np.sin(xx * n * 1.6) * np.sin(yy * n * 1.6)
    n1 = periodic_noise(n, 4, seed, 4)
    green = np.array([0.05, 0.22, 0.14])
    cream = np.array([0.80, 0.74, 0.58])
    alb = np.where(stripe[..., None], green, cream) * weave[..., None] * (0.85 + 0.15 * n1[..., None])
    st = streaks((n, n), seed + 1, 30)
    alb *= (1 - 0.3 * st[..., None])
    rough = np.full((n, n), 0.85)
    ao = np.ones((n, n))
    return to_img(lin2srgb(alb)), packed(rough, ao, st)


def asphalt(n=1024, seed=70):
    """Wet asphalt, 4.0 m repeat.  B = micro wetness variation."""
    r = rng(seed)
    n1 = periodic_noise(n, 6, seed, 6)
    agg = (r.random((n, n)) > 0.985).astype(float)
    agg = gaussian_filter(agg, 0.7, mode="wrap") * 3
    patch = periodic_noise(n, 2, seed + 1, 2)
    cracks = np.zeros((n, n))
    for _ in range(9):
        x, y = r.integers(0, n, 2)
        ang = r.uniform(0, 2 * math.pi)
        for _ in range(r.integers(100, 400)):
            ang += r.normal(0, 0.25)
            x = (x + math.cos(ang) * 1.5) % n
            y = (y + math.sin(ang) * 1.5) % n
            cracks[int(y), int(x)] = 1
    cracks = np.clip(gaussian_filter(cracks, 0.7, mode="wrap") * 3, 0, 1)
    base = 0.20 + (n1 - 0.5) * 0.08 + agg * 0.18 - 0.05 * (patch > 0.72) - 0.12 * cracks
    alb = np.stack([base, base, base * 1.03], -1)
    rough = np.clip(0.42 + 0.25 * n1 + 0.2 * agg - 0.1 * (patch > 0.72), 0, 1)
    ao = 1 - 0.5 * cracks
    wet = periodic_noise(n, 10, seed + 2, 4)
    return to_img(lin2srgb(alb)), packed(rough, ao, wet)


def puddle_map(n=512, seed=80):
    """Non-tiling puddle map covering x in [-9, 15], z in [0, -24] (24 m square).
    Puddles collect near the left gutter, along the right curb, around the
    manhole and in a low dip near the junction."""
    n1 = periodic_noise(n, 5, seed, 5)
    n2 = periodic_noise(n, 14, seed + 1, 3)
    yy, xx = np.mgrid[0:n, 0:n] / n
    X = -9 + xx * 24
    Z = -yy * 24
    m = n1 * 0.7 + n2 * 0.3
    bias = np.zeros_like(m)
    bias += 0.25 * np.exp(-((X + 1.1) ** 2) / 0.12) * (Z > -17.5)        # left gutter edge
    bias += 0.15 * np.exp(-((X - 1.4) ** 2) / 0.08) * (Z > -17.5)        # right curb
    bias += 0.30 * np.exp(-(((X - 0.3) ** 2) + (Z + 7.2) ** 2) / 0.6)    # manhole dip
    bias += 0.30 * np.exp(-(((X - 0.2) ** 2) / 4 + (Z + 18.6) ** 2 / 1.2))  # junction dip
    bias += 0.18 * np.exp(-(((X + 0.4) ** 2) / 0.5 + (Z + 3.2) ** 2 / 1.5))  # near puddle
    v = m + bias
    puddle = np.clip((v - 0.62) * 7, 0, 1)
    puddle = gaussian_filter(puddle, 1.2)
    return to_img(np.stack([puddle, puddle, puddle], -1))


def grate(n=256, seed=90):
    """Steel drain grate, 0.5 m repeat along the gutter (u), width in v."""
    yy, xx = np.mgrid[0:n, 0:n] / n
    slot = ((xx * 10) % 1.0 > 0.35) & (yy > 0.12) & (yy < 0.88)
    frame = (yy < 0.06) | (yy > 0.94)
    n1 = periodic_noise(n, 6, seed, 4)
    base = 0.30 + 0.12 * n1
    alb = np.stack([base * 0.9, base * 0.85, base * 0.8], -1)
    alb[slot] = 0.015
    alb[frame] *= 0.7
    rough = np.where(slot, 1.0, 0.35 + 0.3 * n1)
    ao = np.where(slot, 0.1, 1.0)
    return to_img(lin2srgb(alb)), packed(rough, ao, slot.astype(float))


def manhole(n=512, seed=95):
    """Cast-iron cover with an original radial + hexagon pattern."""
    yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n * 2 - 1
    r = np.hypot(xx, yy)
    th = np.arctan2(yy, xx)
    n1 = periodic_noise(n, 8, seed, 4)
    ring = (np.abs(r - 0.93) < 0.04) | (np.abs(r - 0.35) < 0.025)
    spokes = (np.abs(np.sin(th * 8)) < 0.12) & (r > 0.35) & (r < 0.9)
    # hex lattice inside the ring
    q = xx * 9
    s = yy * 9 / math.sqrt(3) * 2
    hexs = (np.abs(np.sin(q * math.pi) * np.sin(s * math.pi / 2)) < 0.18) & (r < 0.33)
    raised = ring | spokes | hexs
    base = 0.17 + 0.06 * n1 + 0.10 * raised
    alb = np.stack([base, base * 0.97, base * 0.95], -1)
    alb[r > 0.985] = 0.08
    rough = np.where(raised, 0.25, 0.55) + 0.1 * n1
    ao = np.where(raised, 1.0, 0.7)
    return to_img(lin2srgb(alb)), packed(rough, ao, (r < 0.97).astype(float))


def far_windows(n=512, seed=100):
    """Distant office/apartment facade: 16 x 12 windows, sparse warm/cool lit."""
    r = rng(seed)
    cols, rows = 16, 12
    yy, xx = np.mgrid[0:n, 0:n] / n
    c = np.floor(xx * cols).astype(int)
    rw = np.floor(yy * rows).astype(int)
    fu = (xx * cols) % 1
    fv = (yy * rows) % 1
    win = (fu > 0.18) & (fu < 0.82) & (fv > 0.25) & (fv < 0.8)
    lit = r.random((rows, cols))
    kind = r.random((rows, cols))
    col = np.zeros((n, n, 3))
    warm = np.array([1.0, 0.72, 0.42])
    cool = np.array([0.62, 0.8, 1.0])
    for i in range(rows):
        for j in range(cols):
            if lit[i, j] < 0.38:
                m = (rw == i) & (c == j) & win
                cc = warm if kind[i, j] < 0.7 else cool
                col[m] = cc * r.uniform(0.35, 1.0)
            else:
                m = (rw == i) & (c == j) & win
                col[m] = 0.025
    col[~win] = 0.012
    return to_img(lin2srgb(col))


def sky(w=1024, h=512, seed=110):
    """Night sky for the front hemisphere dome: u = azimuth (-84..84 deg),
    v (USD, up) = elevation (-5..85 deg).  Light-polluted magenta/amber
    horizon, low cloud deck lit from below, distant skyline silhouettes."""
    yy, xx = np.mgrid[0:h, 0:w]
    el = 85 - yy / (h - 1) * 90          # image row 0 = top = 85 deg
    az = -84 + xx / (w - 1) * 168
    t = np.clip((el + 5) / 90, 0, 1)
    zen = np.array([0.010, 0.014, 0.035])
    mid = np.array([0.040, 0.030, 0.075])
    hor = np.array([0.30, 0.10, 0.20])
    amber = np.array([0.40, 0.20, 0.10])
    k = np.clip(t * 3.2, 0, 1)[..., None]
    col = hor * (1 - k) + mid * k
    k2 = np.clip((t - 0.3) / 0.7, 0, 1)[..., None]
    col = col * (1 - k2) + zen * k2
    col += amber * np.exp(-((el - 1.0) / 4.5) ** 2)[..., None] * (0.6 + 0.4 * np.cos(np.radians(az) * 2.0)[..., None] ** 2)
    # clouds lit from below
    cl = periodic_noise((h, w), 5, seed, 6, aspect=(1, 2.5))
    cl = np.clip((cl - 0.42) * 2.4, 0, 1) * np.clip(1 - (el - 8) / 55, 0, 1)
    cloud_col = np.array([0.20, 0.09, 0.15]) * np.clip(1.3 - t * 1.5, 0.15, 1)[..., None]
    col = col * (1 - 0.55 * cl[..., None]) + cloud_col * cl[..., None] * 0.9
    # distant skyline silhouettes (background imagery only beyond ~150 m)
    r = rng(seed + 1)
    sil = np.full(w, -10.0)
    x = 0
    while x < w:
        bw = r.integers(6, 40)
        bh = r.uniform(0.5, 7.0) if r.random() < 0.85 else r.uniform(7, 13)
        sil[x:x + bw] = bh
        x += bw
    sil = np.maximum(sil, gaussian_filter(sil, 1))
    below = el[:, :] < sil[None, :]
    col[below] = np.array([0.012, 0.011, 0.02])
    # sparse lit windows / red aviation dots on the silhouettes
    dots = (r.random((h, w)) > 0.9965) & below
    col[dots] = np.array([0.9, 0.6, 0.35]) * 0.6
    tops = np.zeros((h, w), bool)
    for xi in range(0, w, 1):
        if sil[xi] > 6 and r.random() < 0.02:
            yi = int((85 - sil[xi]) / 90 * (h - 1)) + 1
            if 0 <= yi < h:
                tops[yi, xi] = True
    col[tops] = np.array([1.0, 0.08, 0.05])
    return to_img(lin2srgb(np.clip(col, 0, 1)))


def rain(w=256, h=1024, seed=120):
    """Tileable rain streak alpha (grey).  One repeat ~ 1.6 m wide x 6 m tall
    in a layer; streaks 6-20 cm long."""
    r = rng(seed)
    a = np.zeros((h, w))
    for _ in range(170):
        x = r.integers(0, w)
        y = r.integers(0, h)
        L = r.integers(14, 52)
        b = r.uniform(0.25, 1.0)
        ys = (y + np.arange(L)) % h
        prof = np.sin(np.linspace(0, math.pi, L)) ** 0.7 * b
        a[ys, x] = np.maximum(a[ys, x], prof)
    a = gaussian_filter(a, (1.0, 0.45), mode="wrap")
    a = np.clip(a / a.max() * 1.6, 0, 1)
    return to_img(np.stack([a, a, a], -1))


def steam(n=512, seed=130):
    n1 = periodic_noise(n, 3, seed, 5)
    n2 = periodic_noise(n, 7, seed + 1, 3)
    a = np.clip((n1 * 0.7 + n2 * 0.3 - 0.35) * 1.8, 0, 1)
    return to_img(np.stack([a, a, a], -1))


def contact_shadow(w=512, h=256):
    """Alpha for a 2.2 x 1.1 m quad centred on the doorway (u: x, v: z)."""
    yy, xx = np.mgrid[0:h, 0:w]
    X = (xx + 0.5) / w * 2.2 - 1.1
    Z = 0.55 - (yy + 0.5) / h * 1.1
    a = np.zeros((h, w))
    # L-shaped feet: x from 0.455 to 0.805 (mirrored), z from -0.118 to 0.215
    for sx in (-1, 1):
        cxf = sx * 0.63
        d = np.maximum(np.abs(X - cxf) - 0.165, 0) ** 2 / 0.0016 + np.maximum(np.abs(Z - 0.05) - 0.16, 0) ** 2 / 0.0016
        a = np.maximum(a, np.exp(-d) * 0.85)
    # sill and general ambient occlusion under the whole frame
    d = np.maximum(np.abs(X) - 0.62, 0) ** 2 / 0.02 + np.maximum(np.abs(Z) - 0.12, 0) ** 2 / 0.012
    a = np.maximum(a, np.exp(-d) * 0.55)
    d = np.maximum(np.abs(X) - 0.66, 0) ** 2 / 0.09 + np.maximum(np.abs(Z) - 0.16, 0) ** 2 / 0.06
    a = np.maximum(a, np.exp(-d) * 0.28)
    a = gaussian_filter(a, 2)
    return to_img(np.stack([a, a, a], -1))


def spill(w=256, h=256):
    """Light through the opening onto the floor in front (u: x -0.9..0.9,
    v: z 1.6 -> 0.05).  Trapezoid widening away from the door, mixed
    cyan/amber.  Stored as RGB; the shader uses luminance as alpha."""
    yy, xx = np.mgrid[0:h, 0:w]
    X = (xx + 0.5) / w * 1.8 - 0.9
    Zd = (yy + 0.5) / h * 1.55           # distance from the threshold (row 0 = near door)
    half = 0.40 + Zd * 0.22
    lat = np.clip(1 - (np.abs(X) - half + 0.12) / 0.25, 0, 1)
    fall = np.exp(-Zd * 1.9)
    a = gaussian_filter(lat * fall, 6)
    cyan = np.array([0.35, 0.85, 1.0])
    amber = np.array([1.0, 0.65, 0.35])
    mixc = cyan * (0.5 + 0.5 * np.clip(-X, 0, 1))[..., None] + amber * (0.5 + 0.5 * np.clip(X, 0, 1))[..., None]
    col = mixc * a[..., None]
    img = to_img(np.clip(col, 0, 1))
    return img.transpose(Image.FLIP_TOP_BOTTOM)   # USD v-up: v=1 near door (z=0.05)


# ---------------------------------------------------------------- frame (PBR)
def brushed(n=512, seed=200, base=(0.085, 0.09, 0.098), rough=(0.26, 0.40)):
    """Brushed metal: streaks along u (along the frame members)."""
    st = periodic_noise((n, n), 2, seed, 5, aspect=(30, 0.25))
    fine = periodic_noise((n, n), 4, seed + 1, 3, aspect=(60, 1))
    blot = periodic_noise(n, 3, seed + 2, 4)
    v = 0.85 + 0.25 * (st - 0.5) + 0.1 * (fine - 0.5) - 0.06 * blot
    alb = np.array(base)[None, None, :] * v[..., None]
    rgh = rough[0] + (rough[1] - rough[0]) * np.clip(0.5 * st + 0.5 * blot, 0, 1)
    return to_img(lin2srgb(alb)), to_img(rgh)


def ceramic(n=512, seed=210):
    n1 = periodic_noise(n, 30, seed, 3)
    n2 = periodic_noise(n, 4, seed + 1, 4)
    v = 0.92 + 0.08 * (n1 - 0.5) + 0.05 * (n2 - 0.5)
    alb = np.array([0.032, 0.034, 0.038])[None, None, :] * v[..., None]
    rgh = 0.52 + 0.12 * n1 + 0.06 * n2
    return to_img(lin2srgb(alb)), to_img(rgh)
