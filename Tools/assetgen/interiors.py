"""
Painted shop / window interiors (emissive-ish, seen through glass with a small
parallax offset in the shader).  Each region is padded by edge extension so
the parallax offset never samples a neighbouring region.
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from signs import font, vertical_text

W = H = 1024
PAD = 24


class InteriorAtlas:
    def __init__(self):
        self.img = Image.new("RGB", (W, H), (0, 0, 0))
        self.rects = {}

    def put(self, name, x, y, w, h, painter):
        """Region (x, y, w, h) includes padding; painter fills (w-2P, h-2P)."""
        iw, ih = w - 2 * PAD, h - 2 * PAD
        tile = painter(iw, ih)
        a = np.asarray(tile)
        a = np.pad(a, ((PAD, PAD), (PAD, PAD), (0, 0)), mode="edge")
        self.img.paste(Image.fromarray(a), (x, y))
        self.rects[name] = (x + PAD, y + PAD, x + PAD + iw, y + PAD + ih)

    def uv(self, name, inset=0.5):
        x0, y0, x1, y1 = self.rects[name]
        return ((x0 + inset) / W, 1 - (y1 - inset) / H, (x1 - inset) / W, 1 - (y0 + inset) / H)


def grad(w, h, top, bottom):
    t = np.linspace(0, 1, h)[:, None, None]
    return (np.array(top)[None, None] * (1 - t) + np.array(bottom)[None, None] * t) * np.ones((1, w, 1))


def to_im(a):
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def light_pool(a, cx, cy, r, col, k=1.0):
    h, w = a.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.exp(-((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * r * r))
    a += d[..., None] * np.array(col)[None, None] * k
    return a


def cafe(w, h):
    a = grad(w, h, (95, 60, 30), (150, 95, 50))
    for cx in (w * 0.2, w * 0.5, w * 0.8):
        a = light_pool(a, cx, h * 0.12, h * 0.35, (120, 80, 40))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    # shelves with cups / jars
    for row, y in enumerate((h * 0.30, h * 0.48)):
        d.rectangle([w * 0.05, y, w * 0.95, y + 5], fill=(60, 35, 20))
        for i in range(18):
            x = w * 0.07 + i * w * 0.05
            c = [(230, 220, 200), (180, 90, 60), (90, 120, 110), (200, 170, 120)][(i + row) % 4]
            d.rectangle([x, y - 18 - (i % 3) * 4, x + w * 0.03, y], fill=c)
    # pendant lamps
    for cx in (w * 0.2, w * 0.5, w * 0.8):
        d.line([cx, 0, cx, h * 0.10], fill=(30, 20, 10), width=2)
        d.pieslice([cx - 22, h * 0.07, cx + 22, h * 0.17], 180, 360, fill=(255, 220, 150))
    # counter and stools
    d.rectangle([0, h * 0.70, w, h * 0.76], fill=(80, 45, 25))
    d.rectangle([0, h * 0.76, w, h], fill=(55, 32, 20))
    for i in range(6):
        x = w * 0.1 + i * w * 0.16
        d.ellipse([x - 16, h * 0.78, x + 16, h * 0.83], fill=(40, 25, 15))
        d.rectangle([x - 3, h * 0.83, x + 3, h], fill=(30, 20, 12))
    # plant silhouette
    d.ellipse([w * 0.88, h * 0.55, w * 0.99, h * 0.72], fill=(25, 45, 25))
    return im.filter(ImageFilter.GaussianBlur(1.0))


def laundry(w, h):
    a = grad(w, h, (200, 225, 235), (150, 170, 175))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w, h * 0.08], fill=(250, 255, 255))   # tube light
    for row, (y0, y1) in enumerate(((h * 0.22, h * 0.52), (h * 0.55, h * 0.85))):
        n = 6
        for i in range(n):
            x0 = w * 0.03 + i * w * 0.16
            d.rectangle([x0, y0, x0 + w * 0.15, y1], fill=(230, 235, 238), outline=(150, 160, 165), width=2)
            cx, cy = x0 + w * 0.075, (y0 + y1) / 2 + 4
            r = (y1 - y0) * 0.32
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(60, 70, 80), outline=(120, 130, 140), width=4)
            d.ellipse([cx - r * 0.6, cy - r * 0.6, cx + r * 0.6, cy + r * 0.6], fill=(90, 110, 130))
            d.rectangle([x0 + 6, y0 + 4, x0 + 30, y0 + 10], fill=(40, 200, 120) if (i + row) % 3 else (230, 80, 60))
    d.rectangle([0, h * 0.88, w, h], fill=(120, 130, 135))
    return im.filter(ImageFilter.GaussianBlur(0.8))


def izakaya(w, h):
    a = grad(w, h, (110, 55, 25), (170, 90, 40))
    a = light_pool(a, w * 0.5, h * 0.2, h * 0.6, (110, 60, 20))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    # menu tags (vertical paper strips)
    f = font("Bold", 18, serif=True)
    items = ["焼鳥", "枝豆", "刺身", "熱燗", "冷奴", "唐揚", "生麦酒", "おでん"]
    for i, t in enumerate(items):
        x = w * 0.05 + i * w * 0.11
        d.rectangle([x, h * 0.06, x + 30, h * 0.40], fill=(240, 232, 210))
        vertical_text(d, t, int(x + 15), int(h * 0.08), 18, f, (40, 20, 10))
    # bottles shelf
    d.rectangle([0, h * 0.46, w, h * 0.49], fill=(60, 30, 15))
    for i in range(26):
        x = w * 0.02 + i * w * 0.037
        c = [(40, 90, 50), (120, 60, 20), (210, 200, 180), (30, 30, 60)][i % 4]
        d.rectangle([x, h * 0.36, x + 12, h * 0.46], fill=c)
    # counter + stools
    d.rectangle([0, h * 0.62, w, h * 0.68], fill=(150, 100, 55))
    d.rectangle([0, h * 0.68, w, h], fill=(70, 35, 18))
    for i in range(7):
        x = w * 0.08 + i * w * 0.14
        d.ellipse([x - 15, h * 0.73, x + 15, h * 0.78], fill=(45, 25, 15))
    return im.filter(ImageFilter.GaussianBlur(0.9))


def books(w, h):
    a = grad(w, h, (90, 60, 35), (60, 40, 25))
    a = light_pool(a, w * 0.3, h * 0.1, h * 0.7, (120, 80, 40))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    r = np.random.default_rng(5)
    for y0 in np.linspace(h * 0.05, h * 0.85, 5):
        d.rectangle([0, y0 + h * 0.15, w, y0 + h * 0.165], fill=(50, 30, 18))
        x = 4
        while x < w - 4:
            bw = r.integers(6, 16)
            bh = h * r.uniform(0.10, 0.15)
            c = tuple(int(v) for v in r.choice([[120, 40, 30], [40, 60, 90], [150, 130, 90], [70, 90, 60], [180, 160, 120], [90, 50, 70]]))
            d.rectangle([x, y0 + h * 0.15 - bh, x + bw - 1, y0 + h * 0.15], fill=c)
            x += bw
    return im.filter(ImageFilter.GaussianBlur(0.7))


def ramen(w, h):
    a = grad(w, h, (170, 110, 55), (210, 150, 80))
    a = light_pool(a, w * 0.5, h * 0.15, h * 0.7, (90, 70, 40))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    f = font("Bold", 20, serif=True)
    for i, t in enumerate(["醤油", "味噌", "塩", "餃子", "炒飯", "替玉"]):
        x = w * 0.06 + i * w * 0.15
        d.rectangle([x, h * 0.05, x + 34, h * 0.36], fill=(245, 236, 215))
        vertical_text(d, t, int(x + 17), int(h * 0.08), 20, f, (150, 20, 10))
    # steam haze above counter
    hz = Image.new("L", (w, h), 0)
    hd = ImageDraw.Draw(hz)
    for i in range(6):
        hd.ellipse([w * (0.2 + i * 0.1) - 40, h * 0.30, w * (0.2 + i * 0.1) + 40, h * 0.55], fill=70)
    hz = hz.filter(ImageFilter.GaussianBlur(18))
    im = Image.composite(Image.new("RGB", (w, h), (255, 240, 220)), im, hz)
    d = ImageDraw.Draw(im)
    d.rectangle([0, h * 0.56, w, h * 0.62], fill=(200, 160, 110))
    d.rectangle([0, h * 0.62, w, h], fill=(90, 40, 20))
    for i in range(8):
        x = w * 0.07 + i * w * 0.12
        d.ellipse([x - 14, h * 0.66, x + 14, h * 0.71], fill=(150, 25, 20))
    return im.filter(ImageFilter.GaussianBlur(0.8))


def store(w, h):
    a = grad(w, h, (240, 245, 248), (200, 205, 210))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    r = np.random.default_rng(9)
    for y in np.linspace(h * 0.18, h * 0.72, 5):
        d.rectangle([w * 0.03, y + 18, w * 0.97, y + 22], fill=(160, 165, 170))
        x = w * 0.04
        while x < w * 0.95:
            bw = r.integers(8, 20)
            c = tuple(int(v) for v in r.choice([[220, 60, 50], [50, 120, 200], [250, 200, 60], [60, 170, 90], [240, 240, 240], [240, 130, 40]]))
            d.rectangle([x, y, x + bw - 2, y + 18], fill=c)
            x += bw
    d.rectangle([0, 0, w, h * 0.06], fill=(255, 255, 255))
    d.rectangle([0, h * 0.85, w, h], fill=(180, 185, 190))
    return im.filter(ImageFilter.GaussianBlur(0.6))


def pharmacy(w, h):
    a = grad(w, h, (225, 245, 238), (190, 215, 205))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    for y in np.linspace(h * 0.15, h * 0.75, 4):
        d.rectangle([0, y + 26, w, y + 30], fill=(150, 170, 160))
        for i in range(12):
            x = 6 + i * w / 12
            c = [(255, 255, 255), (90, 180, 140), (240, 120, 120), (120, 160, 230)][i % 4]
            d.rectangle([x, y + 4, x + w / 12 - 6, y + 26], fill=c)
    return im.filter(ImageFilter.GaussianBlur(0.6))


def upper(kind):
    def paint(w, h):
        r = np.random.default_rng(hash(kind) % 1000)
        if kind == "warm_curtain":
            a = grad(w, h, (200, 130, 70), (150, 90, 45))
            a[:, : w // 2] *= 0.9
            im = to_im(a)
            d = ImageDraw.Draw(im)
            for x in range(0, w, 7):
                d.line([x, 0, x, h], fill=(170, 110, 60), width=2)
        elif kind == "cool_blinds":
            a = grad(w, h, (120, 150, 175), (90, 110, 130))
            im = to_im(a)
            d = ImageDraw.Draw(im)
            for y in range(0, h, 6):
                d.line([0, y, w, y], fill=(70, 85, 100), width=2)
        elif kind == "dark":
            im = to_im(grad(w, h, (14, 14, 18), (8, 8, 10)))
            d = ImageDraw.Draw(im)
            d.rectangle([w * 0.1, h * 0.55, w * 0.5, h], fill=(20, 18, 22))
        elif kind == "tv":
            a = grad(w, h, (40, 60, 110), (25, 35, 70))
            a = light_pool(a, w * 0.65, h * 0.55, h * 0.35, (80, 110, 160))
            im = to_im(a)
            d = ImageDraw.Draw(im)
            d.rectangle([w * 0.1, h * 0.7, w * 0.55, h], fill=(20, 25, 45))
        elif kind == "lamp":
            a = grad(w, h, (120, 80, 45), (70, 45, 28))
            a = light_pool(a, w * 0.3, h * 0.45, h * 0.3, (200, 140, 70))
            im = to_im(a)
            d = ImageDraw.Draw(im)
            d.rectangle([w * 0.55, h * 0.3, w * 0.9, h * 0.75], fill=(60, 40, 30))
            d.ellipse([w * 0.22, h * 0.38, w * 0.38, h * 0.5], fill=(255, 220, 160))
        else:  # stairwell
            a = grad(w, h, (200, 215, 205), (150, 160, 150))
            im = to_im(a)
            d = ImageDraw.Draw(im)
            for i in range(6):
                d.line([0, h * (0.3 + i * 0.12), w, h * (0.1 + i * 0.12)], fill=(120, 130, 120), width=3)
            d.rectangle([w * 0.4, 0, w * 0.6, h * 0.05], fill=(255, 255, 255))
        return im.filter(ImageFilter.GaussianBlur(0.8))
    return paint


def shutter_gap(w, h):
    a = grad(w, h, (180, 120, 60), (120, 75, 40))
    im = to_im(a)
    d = ImageDraw.Draw(im)
    r = np.random.default_rng(13)
    x = 0
    while x < w:
        bw = r.integers(20, 60)
        bh = h * r.uniform(0.3, 0.9)
        d.rectangle([x, h - bh, x + bw - 4, h], fill=tuple(int(v) for v in r.choice([[90, 60, 40], [140, 110, 70], [60, 50, 45]])))
        x += bw
    return im


def build():
    A = InteriorAtlas()
    A.put("cafe", 0, 0, 512, 256, cafe)
    A.put("laundry", 512, 0, 512, 256, laundry)
    A.put("izakaya", 0, 256, 512, 256, izakaya)
    A.put("books", 512, 256, 512, 256, books)
    A.put("ramen", 0, 512, 512, 256, ramen)
    A.put("store", 512, 512, 512, 256, store)
    A.put("pharmacy", 0, 768, 256, 256, pharmacy)
    for i, k in enumerate(["warm_curtain", "cool_blinds", "dark", "tv", "lamp", "stair"]):
        x = 256 + (i % 3) * 176
        y = 768 + (i // 3) * 128
        A.put(f"upper_{k}", x, y, 176, 128, upper(k))
    A.put("shutter_gap", 784, 768, 240, 128, shutter_gap)
    return A
