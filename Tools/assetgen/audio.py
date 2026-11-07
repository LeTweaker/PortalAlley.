"""
Generated soundscape (original, no samples).  Mono 16-bit PCM WAV so RealityKit
can spatialise each source at the doorway.

rain_loop.wav     24 s  steady rain: filtered noise bed + individual drops,
                        drips on metal (awnings / AC units), seamless loop
city_loop.wav     30 s  distant city: low rumble, slow traffic swells, a far
                        train passing, faint distant chatter-like texture
hum_loop.wav      12 s  low mechanical hum for the frame: 55 Hz + harmonics
                        with slow beating and a faint servo whine
portal_open.wav   2.2 s mechanical unlatch, rising air, soft resonant tone
portal_close.wav  0.9 s short descending close
"""
import math
import wave

import numpy as np
from scipy.signal import butter, sosfilt, sosfiltfilt

SR = 44100


def write_wav(path, x, sr=SR):
    x = np.clip(x, -1, 1)
    pcm = (x * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def bp(x, lo, hi, order=2):
    sos = butter(order, [lo, hi], btype="band", fs=SR, output="sos")
    return sosfilt(sos, x)


def lp(x, f, order=2):
    return sosfilt(butter(order, f, btype="low", fs=SR, output="sos"), x)


def hp(x, f, order=2):
    return sosfilt(butter(order, f, btype="high", fs=SR, output="sos"), x)


def loopify(x, fade_s=1.5):
    """Make a seamless loop by crossfading the tail into the head."""
    n = int(fade_s * SR)
    head, body, tail = x[:n], x[n:-n] if n else x, x[-n:]
    t = np.linspace(0, 1, n)
    mixed = tail * np.cos(t * math.pi / 2) + head * np.sin(t * math.pi / 2)
    return np.concatenate([mixed, x[n:-n]])


def normalize(x, peak=0.7):
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def rain(seconds=24, seed=1):
    r = np.random.default_rng(seed)
    n = int((seconds + 1.5) * SR)
    white = r.normal(0, 1, n)
    bed = bp(white, 400, 9000) * 0.35 + bp(white, 1500, 5000) * 0.25
    # slow intensity drift
    env = 1 + 0.12 * np.sin(np.linspace(0, 2 * math.pi * 3, n)) + 0.06 * np.sin(np.linspace(0, 2 * math.pi * 7.3, n))
    bed *= env
    drops = np.zeros(n)
    for _ in range(int(seconds * 140)):
        i = r.integers(0, n - 2000)
        L = r.integers(200, 900)
        f = r.uniform(1800, 6500)
        t = np.arange(L) / SR
        drops[i:i + L] += np.sin(2 * math.pi * f * t) * np.exp(-t * r.uniform(250, 600)) * r.uniform(0.05, 0.25)
    # metallic drips (awning / AC unit tops)
    for _ in range(int(seconds * 3)):
        i = r.integers(0, n - 6000)
        L = 5000
        t = np.arange(L) / SR
        f = r.uniform(700, 1400)
        drops[i:i + L] += (np.sin(2 * math.pi * f * t) + 0.4 * np.sin(2 * math.pi * f * 2.7 * t)) * np.exp(-t * 35) * r.uniform(0.08, 0.18)
    x = bed + drops
    x = hp(x, 120)
    return normalize(loopify(x), 0.55)


def city(seconds=30, seed=2):
    r = np.random.default_rng(seed)
    n = int((seconds + 1.5) * SR)
    white = r.normal(0, 1, n)
    brown = np.cumsum(white)
    brown = hp(brown, 20)
    brown = normalize(lp(brown, 180), 1.0) * 0.5
    swell = np.zeros(n)
    for _ in range(5):
        c = r.integers(0, n)
        w = r.uniform(3, 6) * SR
        idx = np.arange(n)
        swell += np.exp(-((idx - c) / w) ** 2) * r.uniform(0.5, 1.0)
    traffic = bp(white, 60, 700) * (0.15 + 0.6 * swell)
    # far train (doppler-ish rumble with rail clacks), once per loop
    t0 = int(seconds * 0.45 * SR)
    L = int(8 * SR)
    t = np.arange(L) / SR
    env = np.sin(np.pi * t / 8) ** 2
    train = lp(r.normal(0, 1, L), 300) * env * 0.6
    for k in range(int(8 / 0.42)):
        i = int(k * 0.42 * SR + (k % 2) * 0.09 * SR)
        if i + 1500 < L:
            tt = np.arange(1500) / SR
            train[i:i + 1500] += np.sin(2 * math.pi * 140 * tt) * np.exp(-tt * 60) * env[i] * 0.5
    x = brown + traffic
    x[t0:t0 + L] += train
    # faint chatter-like formant texture
    chat = bp(white, 300, 1200) * (0.5 + 0.5 * np.sin(np.cumsum(r.normal(0, 0.002, n)) * 40)) * 0.05
    x += chat
    return normalize(loopify(x), 0.5)


def hum(seconds=12, seed=3):
    n = int((seconds + 1.5) * SR)
    t = np.arange(n) / SR
    x = (np.sin(2 * math.pi * 55 * t) * 0.5 + np.sin(2 * math.pi * 110.3 * t) * 0.25 +
         np.sin(2 * math.pi * 165.2 * t) * 0.12 + np.sin(2 * math.pi * 220.7 * t) * 0.05)
    x *= 1 + 0.1 * np.sin(2 * math.pi * 0.25 * t)
    whine = np.sin(2 * math.pi * (2310 + 6 * np.sin(2 * math.pi * 0.1 * t)) * t) * 0.012
    r = np.random.default_rng(seed)
    air = bp(r.normal(0, 1, n), 200, 900) * 0.04
    return normalize(loopify(x + whine + air), 0.45)


def portal_open(seed=4):
    r = np.random.default_rng(seed)
    n = int(2.2 * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    # unlatch: two short mechanical clicks
    for tc, f in ((0.02, 900), (0.11, 1300)):
        i = int(tc * SR)
        L = 2200
        tt = np.arange(L) / SR
        x[i:i + L] += (r.normal(0, 1, L) * 0.6 + np.sin(2 * math.pi * f * tt)) * np.exp(-tt * 90) * 0.5
    # rising air
    air = bp(r.normal(0, 1, n), 300, 4000)
    env = np.clip((t - 0.15) / 1.0, 0, 1) ** 1.5 * np.exp(-np.clip(t - 1.3, 0, None) * 3)
    x += air * env * 0.35
    # soft resonant tone (fifth)
    tone = (np.sin(2 * math.pi * 196 * t) + 0.5 * np.sin(2 * math.pi * 294 * t) + 0.25 * np.sin(2 * math.pi * 392 * t))
    tenv = np.clip((t - 0.35) / 0.4, 0, 1) * np.exp(-np.clip(t - 0.75, 0, None) * 2.2)
    x += tone * tenv * 0.18
    fade = np.clip((2.2 - t) / 0.3, 0, 1)
    return normalize(x * fade, 0.6)


def portal_close(seed=5):
    r = np.random.default_rng(seed)
    n = int(0.9 * SR)
    t = np.arange(n) / SR
    air = bp(r.normal(0, 1, n), 250, 2500) * np.exp(-t * 5) * 0.3
    tone = np.sin(2 * math.pi * (260 - 90 * t) * t) * np.exp(-t * 6) * 0.2
    i = int(0.62 * SR)
    L = 2000
    tt = np.arange(L) / SR
    click = np.zeros(n)
    click[i:i + L] = r.normal(0, 1, L) * np.exp(-tt * 120) * 0.4
    return normalize(air + tone + click, 0.5)


def build(out_dir):
    files = {
        "rain_loop.wav": rain(),
        "city_loop.wav": city(),
        "hum_loop.wav": hum(),
        "portal_open.wav": portal_open(),
        "portal_close.wav": portal_close(),
    }
    sizes = {}
    for name, x in files.items():
        write_wav(f"{out_dir}/{name}", x.astype(np.float64))
        sizes[name] = round(len(x) / SR, 2)
    return sizes
