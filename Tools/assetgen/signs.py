"""
Sign / emissive atlas.  Every business name is original and fictional.
Text: Noto Sans / Serif CJK JP (SIL Open Font License 1.1) rasterised into
the texture at build time - no font ships with the app.

The atlas is emissive: the shader multiplies it by a per-material gain, so
the colours here are the "lit" colours at nominal brightness.
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT_DIR = "/usr/share/fonts/opentype/noto/"
W = H = 2048


def font(weight="Bold", size=40, serif=False):
    fam = "NotoSerifCJK" if serif else "NotoSansCJK"
    return ImageFont.truetype(f"{FONT_DIR}{fam}-{weight}.ttc", size, index=0)


class Atlas:
    def __init__(self, w=W, h=H):
        self.img = Image.new("RGB", (w, h), (0, 0, 0))
        self.w, self.h = w, h
        self.rects = {}
        self.x = 8
        self.y = 8
        self.row_h = 0

    def alloc(self, name, w, h):
        if self.x + w + 8 > self.w:
            self.x = 8
            self.y += self.row_h + 8
            self.row_h = 0
        assert self.y + h + 8 <= self.h, f"atlas full at {name}"
        r = (self.x, self.y, self.x + w, self.y + h)
        self.rects[name] = r
        self.x += w + 8
        self.row_h = max(self.row_h, h)
        return r

    def paste(self, name, tile: Image.Image):
        self.pending = getattr(self, "pending", [])
        self.pending.append((name, tile))

    def pack(self):
        """Shelf-pack pending tiles, tallest first."""
        for name, tile in sorted(self.pending, key=lambda t: -t[1].size[1]):
            r = self.alloc(name, *tile.size)
            self.img.paste(tile, r[:2])
        self.pending = []

    def uv(self, name, inset=0.5):
        """(u0, v0, u1, v1) in USD convention (v up), inset by half a pixel."""
        x0, y0, x1, y1 = self.rects[name]
        return ((x0 + inset) / self.w, 1 - (y1 - inset) / self.h,
                (x1 - inset) / self.w, 1 - (y0 + inset) / self.h)


def vertical_text(draw, text, cx, y0, size, fnt, fill, spacing=1.04):
    y = y0
    for ch in text:
        if ch == " ":
            y += size * 0.5
            continue
        bbox = draw.textbbox((0, 0), ch, font=fnt)
        w = bbox[2] - bbox[0]
        if ch in "ー":
            # rotate the long vowel mark for vertical writing
            tmp = Image.new("L", (size * 2, size * 2), 0)
            ImageDraw.Draw(tmp).text((size // 2, size // 2), ch, font=fnt, fill=255)
            tmp = tmp.rotate(-90)
            bb = tmp.getbbox()
            if bb:
                crop = tmp.crop(bb)
                draw.bitmap((cx - crop.size[0] // 2, y + (size - crop.size[1]) // 2), crop, fill=fill)
        else:
            draw.text((cx - w / 2 - bbox[0], y - bbox[1] * 0.6), ch, font=fnt, fill=fill)
        y += size * spacing
    return y


def glow(img: Image.Image, radius=6, strength=1.0):
    """Neon-like halo inside the sign face (never outside the geometry)."""
    blur = img.filter(ImageFilter.GaussianBlur(radius))
    a = np.asarray(img, np.float32)
    b = np.asarray(blur, np.float32)
    out = np.clip(a + b * strength, 0, 255).astype(np.uint8)
    return Image.fromarray(out)


def panel(w, h, bg, border=None, bw=0, grad=0.0, rounded=0):
    img = Image.new("RGB", (w, h), bg)
    if grad:
        a = np.asarray(img, np.float32)
        yy = np.linspace(0, 1, h)[:, None, None]
        xx = np.linspace(-1, 1, w)[None, :, None]
        # lit-box falloff: brighter in the middle (fluorescent tubes behind acrylic)
        f = 1.0 - grad * (0.55 * xx ** 2 + 0.35 * (yy - 0.5) ** 2 * 4)
        img = Image.fromarray(np.clip(a * f, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    if border and bw:
        d.rectangle([bw // 2, bw // 2, w - 1 - bw // 2, h - 1 - bw // 2], outline=border, width=bw)
    return img


def neon_text(w, h, bg, text_items, glow_r=7, glow_s=1.3):
    """text_items: (text, (x, y), font, color, vertical, size)."""
    base = Image.new("RGB", (w, h), bg)
    lay = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(lay)
    for text, (x, y), f, col, vert, size in text_items:
        if vert:
            vertical_text(d, text, x, y, size, f, col)
        else:
            bb = d.textbbox((0, 0), text, font=f)
            d.text((x - (bb[2] - bb[0]) / 2 - bb[0], y), text, font=f, fill=col)
    lay = glow(lay, glow_r, glow_s)
    out = np.clip(np.asarray(base, np.float32) + np.asarray(lay, np.float32), 0, 255).astype(np.uint8)
    return Image.fromarray(out)


def lantern(w, h, base_col, text, text_col, ribs=14):
    """Chochin texture: u wraps around, v bottom->top in USD space (image top = top)."""
    img = Image.new("RGB", (w, h), base_col)
    a = np.asarray(img, np.float32)
    yy = np.linspace(0, 1, h)[:, None, None]
    # vertical brightness: brighter mid (bulb inside), darker caps
    f = 0.55 + 0.6 * np.sin(np.pi * np.clip(yy, 0, 1)) ** 1.5
    a = a * f
    # rib lines (bamboo hoops)
    for i in range(ribs + 1):
        y = int(i / ribs * (h - 1))
        a[max(0, y - 1):y + 1] *= 0.55
    img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    # text twice around the circumference
    # The texture wraps a lantern whose circumference is ~2.3x its height, so
    # glyphs are drawn at normal proportions and then squeezed horizontally.
    squeeze = (w / 1.38) / (h / 0.60)          # texels per metre, u vs v
    fsz = int(min(h * 0.80 / max(1, len(text)), 140))
    fnt = font("Black", fsz, serif=True)
    tw = int(fsz * 1.2)
    th = int(fsz * len(text) * 1.06 + 8)
    tmp = Image.new("L", (tw, th), 0)
    vertical_text(ImageDraw.Draw(tmp), text, tw // 2, 4, fsz, fnt, 255)
    tmp = tmp.resize((max(4, int(tw * squeeze)), th), Image.LANCZOS)
    for cx in (w * 0.25, w * 0.75):
        img.paste(Image.new("RGB", tmp.size, text_col), (int(cx - tmp.size[0] / 2), int((h - th) / 2)), tmp)
    # black caps
    d.rectangle([0, 0, w, int(h * 0.05)], fill=(15, 10, 10))
    d.rectangle([0, int(h * 0.95), w, h], fill=(15, 10, 10))
    return img


def vending(w, h, seed, accent):
    rng = np.random.default_rng(seed)
    img = Image.new("RGB", (w, h), (30, 32, 36))
    d = ImageDraw.Draw(img)
    # bright display window with 4 shelves of bottles
    x0, y0, x1, y1 = 14, 40, w - 14, int(h * 0.62)
    d.rectangle([x0, y0, x1, y1], fill=(225, 232, 238))
    rows = 4
    for r in range(rows):
        ry0 = y0 + 8 + r * (y1 - y0 - 8) // rows
        ry1 = ry0 + (y1 - y0) // rows - 22
        n = 6
        for c in range(n):
            cx0 = x0 + 8 + c * (x1 - x0 - 16) // n
            cw = (x1 - x0 - 16) // n - 8
            col = tuple(int(v) for v in rng.choice([[200, 40, 40], [40, 110, 200], [240, 190, 40], [40, 160, 90],
                                                     [230, 230, 230], [120, 60, 30], [250, 120, 30], [80, 80, 90]]))
            # bottle silhouette
            d.rounded_rectangle([cx0 + cw * 0.2, ry0 + 10, cx0 + cw * 0.8, ry1], radius=4, fill=col)
            d.rectangle([cx0 + cw * 0.38, ry0 + 2, cx0 + cw * 0.62, ry0 + 12], fill=tuple(int(v * 0.8) for v in col))
            # price label + button
            d.rectangle([cx0 + 2, ry1 + 3, cx0 + cw - 2, ry1 + 10], fill=(30, 30, 30))
            d.ellipse([cx0 + cw / 2 - 3, ry1 + 12, cx0 + cw / 2 + 3, ry1 + 18], fill=(255, 140, 40) if rng.random() < 0.5 else (90, 220, 120))
        d.line([x0, ry1 + 20, x1, ry1 + 20], fill=(160, 165, 170), width=2)
    # header band
    d.rectangle([0, 0, w, 36], fill=accent)
    f = font("Black", 22)
    d.text((w // 2 - 50, 4), "つめた〜い", font=f, fill=(255, 255, 255))
    # coin panel and pickup slot
    d.rectangle([w - 70, int(h * 0.66), w - 20, int(h * 0.80)], fill=(70, 74, 80))
    d.rectangle([w - 60, int(h * 0.68), w - 30, int(h * 0.70)], fill=(20, 20, 20))
    d.rectangle([20, int(h * 0.86), w - 20, int(h * 0.94)], fill=(12, 12, 14))
    d.rectangle([20, int(h * 0.66), w - 90, int(h * 0.80)], fill=accent)
    f2 = font("Bold", 18)
    d.text((32, int(h * 0.70)), "100円〜", font=f2, fill=(255, 255, 255))
    return glow(img, 3, 0.25)


def build_atlas():
    A = Atlas()
    jp_black = lambda s: font("Black", s)
    jp_bold = lambda s: font("Bold", s)
    serif = lambda s: font("Black", s, serif=True)

    # ------------------------------------------------ blade signs (vertical)
    t = panel(160, 520, (246, 214, 150), border=(120, 70, 30), bw=8, grad=0.5)
    d = ImageDraw.Draw(t)
    vertical_text(d, "喫茶", 80, 40, 92, serif(92), (70, 35, 15))
    vertical_text(d, "ミナト", 80, 250, 70, jp_black(70), (120, 40, 20))
    d.text((32, 478), "COFFEE", font=font("Bold", 26), fill=(110, 60, 30))
    A.paste("cafe_blade", t)

    t = neon_text(160, 640, (8, 14, 28), [
        ("BAR", (80, 20), font("Black", 54), (60, 230, 255), False, 54),
        ("夜霧", (80, 120), serif(108), (90, 240, 255), True, 108),
        ("YOGIRI", (80, 560), font("Bold", 30), (255, 90, 200), False, 30),
    ], glow_r=9, glow_s=1.6)
    d = ImageDraw.Draw(t)
    d.rectangle([4, 4, 155, 635], outline=(40, 120, 170), width=3)
    A.paste("bar_blade", t)

    t = panel(150, 560, (238, 244, 250), border=(30, 90, 190), bw=8, grad=0.4)
    d = ImageDraw.Draw(t)
    d.text((22, 18), "24H", font=font("Black", 50), fill=(220, 30, 40))
    vertical_text(d, "コインランドリー", 75, 92, 54, jp_black(54), (20, 70, 170), spacing=0.98)
    A.paste("laundry_blade", t)

    t = panel(160, 560, (150, 20, 22), border=(240, 190, 120), bw=6, grad=0.45)
    d = ImageDraw.Draw(t)
    vertical_text(d, "居酒屋", 80, 26, 76, serif(76), (255, 238, 210))
    vertical_text(d, "しずく", 80, 300, 70, serif(70), (255, 215, 120))
    A.paste("izakaya_blade", t)

    t = panel(160, 420, (24, 150, 110), border=(230, 255, 240), bw=6, grad=0.4)
    d = ImageDraw.Draw(t)
    d.text((22, 24), "薬", font=serif(118), fill=(255, 255, 255))
    vertical_text(d, "ひかり", 80, 196, 62, jp_black(62), (230, 255, 245))
    A.paste("pharmacy_blade", t)

    # ------------------------------------------------ stacked sign tower boxes
    stack = [
        ("stack_1", (200, 20, 120), "スナック", "月影", (255, 240, 250)),
        ("stack_2", (245, 245, 240), "麻雀", "白梅", (20, 120, 60)),
        ("stack_3", (250, 210, 40), "カラオケ", "星", (200, 20, 30)),
        ("stack_4", (190, 30, 30), "焼鳥", "とり吉", (255, 250, 240)),
        ("stack_5", (16, 30, 90), "JAZZ", "青", (90, 220, 255)),
    ]
    for name, bg, a, b, col in stack:
        t = panel(300, 120, bg, grad=0.5)
        d = ImageDraw.Draw(t)
        d.text((14, 36), a, font=jp_black(32 if len(a) >= 4 else 36), fill=col)
        fb = serif(64 if len(b) <= 2 else 54)
        bb = d.textbbox((0, 0), b, font=fb)
        d.text((290 - (bb[2] - bb[0]) - bb[0], 60 - (bb[3] + bb[1]) / 2), b, font=fb, fill=col)
        d.rectangle([2, 2, 297, 117], outline=tuple(int(c * 0.6) for c in bg), width=4)
        if name == "stack_5":
            t = glow(t, 6, 0.8)
        A.paste(name, t)

    # ------------------------------------------------ horizontal boards
    t = panel(1024, 168, (250, 236, 200), border=(150, 40, 30), bw=10, grad=0.35)
    d = ImageDraw.Draw(t)
    f = serif(96)
    bb = d.textbbox((0, 0), "ほたる横丁", font=f)
    d.text((512 - (bb[2] - bb[0]) / 2 - bb[0], 2), "ほたる横丁", font=f, fill=(150, 30, 20))
    d.text((40, 122), "HOTARU YOKOCHO", font=font("Bold", 26), fill=(120, 60, 30))
    d.text((800, 122), "since 1962", font=font("Medium", 24), fill=(120, 60, 30))
    A.paste("arch", t)

    t = neon_text(1024, 200, (14, 10, 8), [
        ("らーめん 灯", (430, 14), serif(130), (255, 236, 200), False, 130),
        ("AKARI", (880, 40), font("Black", 54), (255, 170, 60), False, 54),
        ("深夜二時まで", (880, 120), font("Bold", 34), (255, 210, 150), False, 34),
    ], glow_r=5, glow_s=0.5)
    A.paste("ramen_board", t)

    t = panel(180, 720, (200, 24, 26), border=(255, 210, 60), bw=10, grad=0.35)
    d = ImageDraw.Draw(t)
    vertical_text(d, "らーめん", 90, 40, 120, serif(120), (255, 255, 250), spacing=1.1)
    vertical_text(d, "灯", 90, 590, 100, serif(100), (255, 220, 80))
    A.paste("ramen_vertical", t)

    t = panel(768, 128, (120, 80, 45), border=(60, 35, 20), bw=8)
    a = np.asarray(t, np.float32)
    rng = np.random.default_rng(3)
    grain = np.cumsum(rng.normal(0, 1, (128, 1)), 0) * 2 + rng.normal(0, 4, (128, 768))
    t = Image.fromarray(np.clip(a + grain[..., None], 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(t)
    d.text((70, 8), "古書 ふくろう堂", font=serif(92), fill=(30, 18, 10))
    A.paste("book_board", t)

    t = panel(768, 128, (246, 248, 250), grad=0.2)
    d = ImageDraw.Draw(t)
    d.rectangle([0, 0, 768, 18], fill=(20, 140, 200))
    d.rectangle([0, 110, 768, 128], fill=(240, 120, 30))
    d.text((40, 22), "ヨルマート", font=jp_black(80), fill=(20, 90, 160))
    d.text((520, 30), "24H", font=font("Black", 72), fill=(240, 100, 20))
    A.paste("conv_store", t)

    t = panel(128, 64, (250, 250, 245))
    d = ImageDraw.Draw(t)
    d.text((10, 4), "営業中", font=jp_black(36), fill=(210, 20, 30))
    A.paste("eigyo", t)

    t = panel(220, 300, (20, 26, 22), border=(150, 110, 60), bw=10)
    d = ImageDraw.Draw(t)
    d.text((26, 24), "本日の", font=jp_bold(36), fill=(240, 240, 230))
    d.text((26, 66), "おすすめ", font=jp_bold(36), fill=(240, 240, 230))
    for i, (s, c) in enumerate([("ブレンド 480", (255, 220, 120)), ("ナポリタン", (255, 160, 160)), ("プリン", (200, 240, 255))]):
        d.text((26, 130 + i * 46), s, font=jp_bold(30), fill=c)
    A.paste("menu_board", t)

    # lanterns, noren, vending, posters
    A.paste("lantern_izakaya", lantern(256, 320, (225, 40, 30), "酒", (20, 10, 10)))
    A.paste("lantern_ramen", lantern(256, 320, (235, 60, 28), "らーめん", (25, 10, 5)))
    A.paste("lantern_white", lantern(192, 256, (246, 236, 214), "やきとり", (170, 25, 20)))

    for name, bg, txt, col in (("noren_izakaya", (28, 40, 90), "しずく", (240, 240, 235)),
                               ("noren_ramen", (190, 25, 25), "灯", (255, 250, 245))):
        t = Image.new("RGB", (512, 256), bg)
        d = ImageDraw.Draw(t)
        f = serif(150 if len(txt) == 1 else 120)
        bb = d.textbbox((0, 0), txt, font=f)
        d.text((256 - (bb[2] - bb[0]) / 2 - bb[0], 40), txt, font=f, fill=col)
        a = np.asarray(t, np.float32)
        a *= (0.9 + 0.1 * np.sin(np.arange(512) / 3.0))[None, :, None]   # weave
        A.paste(name, Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)))

    A.paste("vending_a", vending(256, 512, 11, (200, 30, 40)))
    A.paste("vending_b", vending(256, 512, 12, (30, 90, 190)))

    for i, (bg, t1, t2) in enumerate((((240, 220, 60), "夏祭り", "8/14 SAT"), ((30, 30, 40), "LIVE", "地下一階"))):
        t = Image.new("RGB", (128, 180), bg)
        d = ImageDraw.Draw(t)
        fg = (20, 20, 20) if i == 0 else (240, 80, 160)
        d.text((10, 10), t1, font=jp_black(34), fill=fg)
        d.ellipse([20, 60, 108, 148], outline=fg, width=6)
        d.text((10, 150), t2, font=jp_bold(22), fill=fg)
        A.paste(f"poster_{i}", t)

    # tiger-stripe guard sleeve for the utility pole (not emissive in use)
    t = Image.new("RGB", (128, 128), (235, 190, 20))
    d = ImageDraw.Draw(t)
    for k in range(-4, 8):
        d.polygon([(k * 32, 0), (k * 32 + 16, 0), (k * 32 + 16 + 128, 128), (k * 32 + 128, 128)], fill=(20, 20, 20))
    A.paste("tiger", t)
    # flat emissive swatches (bulbs, tubes, lamp lenses)
    for name, col in (("bulb_warm", (255, 210, 140)), ("tube_cool", (220, 245, 255)),
                      ("lamp_led", (235, 245, 255)), ("red_dot", (255, 40, 30)),
                      ("signal_amber", (255, 170, 40))):
        A.paste(name, Image.new("RGB", (32, 32), col))
    A.pack()
    return A


def road_marking():
    """'止まれ' + stop line, white paint, alpha in A (for the decal)."""
    w, h = 512, 1024
    img = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(img)
    f = font("Black", 230)
    # painted upright characters elongated along the road (stretched 2.0x in v)
    y = 110
    for ch in "止まれ":
        tmp = Image.new("L", (300, 300), 0)
        ImageDraw.Draw(tmp).text((20, -20), ch, font=f, fill=255)
        bb = tmp.getbbox()
        crop = tmp.crop(bb).resize((330, 260))
        img.paste(crop, ((w - 330) // 2, y))
        y += 285
    d.rectangle([0, 24, w, 64], fill=255)          # stop line (far end)
    a = np.asarray(img, np.float32) / 255
    rng = np.random.default_rng(7)
    wear = np.clip(0.75 + 0.35 * rng.random((h, w)), 0, 1)
    from scipy.ndimage import gaussian_filter
    wear = gaussian_filter(wear, 1.2)
    a = np.clip(a * wear * 1.1, 0, 1)
    rgba = np.zeros((h, w, 4), np.uint8)
    rgba[..., :3] = 235
    rgba[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def ticker():
    """LED ticker strip (own texture so the shader can wrap-scroll it)."""
    tick = Image.new("RGB", (768, 64), (10, 2, 2))
    d = ImageDraw.Draw(tick)
    d.text((10, 6), "いらっしゃいませ ・ 24時間営業 ・ 洗濯 乾燥 ・", font=font("Bold", 40), fill=(255, 60, 30))
    a = np.asarray(tick, np.float32)
    yy, xx = np.mgrid[0:64, 0:768]
    dots = ((yy % 4) < 3) & ((xx % 4) < 3)
    a = a * dots[..., None]
    return Image.fromarray(a.astype(np.uint8))
