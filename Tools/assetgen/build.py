#!/usr/bin/env python3
"""
Builds every runtime asset for PortalAlley from source.

    python3 Tools/assetgen/build.py            # full build
    python3 Tools/assetgen/build.py --no-audio # skip audio (faster)

Outputs (all committed to the repo so the iOS build needs no Python):
    App/Resources/Portal/manifest.json
    App/Resources/Portal/meshes/*.pmsh
    App/Resources/Portal/textures/*.png
    App/Resources/Portal/audio/*.wav
    App/Shaders/AlleyLights.h                 (Metal light table)
    Tools/preview/generated/alley_lights.glsl (same table for the preview)
"""
import json
import os
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

import alley  # noqa: E402
import audio  # noqa: E402
import bake  # noqa: E402
import frame  # noqa: E402
import interiors  # noqa: E402
import photo  # noqa: E402
import props  # noqa: E402
import signs  # noqa: E402
import texkit as tk  # noqa: E402
from meshkit import MeshBuilder  # noqa: E402

RES = os.path.join(ROOT, "App", "Resources", "Portal")
TEX = os.path.join(RES, "textures")
MESH = os.path.join(RES, "meshes")
AUD = os.path.join(RES, "audio")
GEN_PREVIEW = os.path.join(ROOT, "Tools", "preview", "generated")
for d in (TEX, MESH, AUD, GEN_PREVIEW):
    os.makedirs(d, exist_ok=True)

EXPOSURE = 1.0
PHOTO_STATS = {}
PROP_STATS = {}
BAKE_STATS = {}

# --------------------------------------------------------------------------
# Textures: name -> (semantic, generator).  semantic: color (sRGB) | raw (linear)
# --------------------------------------------------------------------------
def build_textures():
    out = {}

    def save(name, img, semantic):
        path = os.path.join(TEX, f"{name}.png")
        img.save(path, optimize=True)
        out[name] = dict(file=f"textures/{name}.png", semantic=semantic, size=list(img.size))

    def save_jpg(name, img, semantic):
        path = os.path.join(TEX, f"{name}.jpg")
        img.convert("RGB").save(path, quality=90, optimize=True, subsampling=0 if semantic == "raw" else 2)
        out[name] = dict(file=f"textures/{name}.jpg", semantic=semantic, size=list(img.size))

    # stale outputs from earlier pipelines (procedural / v1.2 CI import) must not ship
    for f in os.listdir(TEX):
        os.remove(os.path.join(TEX, f))

    # photographed CC0 scans (Vendor/polyhaven): walls, shutters, wood, ground
    PHOTO_STATS.update(photo.build(save, save_jpg))
    # scanned CC0 props: their own albedo/packed/normal sets
    PROP_STATS.update(props.build_textures(save, save_jpg))

    # procedural where no scan fits (small painted metal parts, awning canvas,
    # gutter grates, manhole lid)
    pairs = [
        ("metal", tk.metal_panel), ("canvas", tk.canvas_stripe), ("grate", tk.grate),
        ("manhole", tk.manhole),
    ]
    for name, fn in pairs:
        a, p = fn()
        save(f"{name}_albedo", a, "color")
        save(f"{name}_packed", p, "raw")
    save("puddles", tk.puddle_map(), "raw")
    save("far_windows", tk.far_windows(), "color")
    save("sky", tk.sky(), "color")
    save("rain", tk.rain(), "raw")
    save("steam", tk.steam(), "raw")
    save("contact_shadow", tk.contact_shadow(), "raw")
    save("spill", tk.spill(), "color")
    save("white", Image.new("RGB", (4, 4), (255, 255, 255)), "color")
    save("black", Image.new("RGB", (4, 4), (0, 0, 0)), "raw")
    save("neutral_packed", Image.new("RGB", (4, 4), (200, 255, 0)), "raw")
    a, r = tk.brushed()
    save("frame_brushed_albedo", a, "color")
    save("frame_brushed_rough", r, "raw")
    a, r = tk.brushed(seed=220, base=(0.24, 0.245, 0.255), rough=(0.18, 0.30))
    save("frame_trim_albedo", a, "color")
    save("frame_trim_rough", r, "raw")
    a, r = tk.ceramic()
    save("frame_ceramic_albedo", a, "color")
    save("frame_ceramic_rough", r, "raw")

    A = signs.build_atlas()
    save("signs", A.img, "color")
    save("road_paint", signs.road_marking(), "color")
    save("ticker", signs.ticker(), "color")
    I = interiors.build()
    save("interiors", I.img, "color")
    return out, A, I


# --------------------------------------------------------------------------
# Materials
# --------------------------------------------------------------------------
def lit(albedo, packed, tint, wet=0.35, spec=0.6, normal=None, uvmul=0.0):
    t = dict(baseColor=albedo, custom=packed)
    if normal:
        t["normal"] = normal
    # params.z: UV multiplier (0 = 1) so scans show at photographed size
    return dict(shader="alleyLit", textures=t, tint=list(tint), params=[wet, spec, float(uvmul), EXPOSURE])


def plit(fam, tint, wet=0.35, spec=0.6, authored=None, uvmul=None):
    """Lit material from a photographed family."""
    m = uvmul if uvmul is not None else (photo.uv_mul(fam, authored) if authored else 1.0)
    return lit(f"{fam}_albedo", f"{fam}_packed", tint, wet, spec, normal=f"{fam}_normal", uvmul=m)


def ground(fam, tint, prm, aux="puddles"):
    return dict(shader="alleyGround", textures=dict(baseColor=f"{fam}_albedo", custom=f"{fam}_packed", emissiveColor=aux,
                                                     normal=f"{fam}_normal"), tint=list(tint), params=prm)


def emissive(tex, gain, flicker=0, scroll=0.0, tint=(1, 1, 1)):
    return dict(shader="alleyEmissive", textures=dict(baseColor=tex, custom="neutral_packed"),
                tint=list(tint), params=[gain, float(flicker), scroll, EXPOSURE])


def materials():
    M = {}
    # photographed facades; tints are per-building paint on one scan
    M["tile_beige"] = plit("tile", (1.00, 0.86, 0.66), wet=0.45, spec=0.9, authored=2.0)
    M["tile_grey"] = plit("tile", (0.62, 0.66, 0.70), wet=0.45, spec=0.9, authored=2.0)
    M["concrete"] = plit("concrete", (1.0, 1.0, 1.0), wet=0.4, spec=0.4, authored=3.0)
    M["concrete_dark"] = plit("concrete2", (0.72, 0.72, 0.75), wet=0.4, spec=0.4, authored=3.0)
    M["plaster_cream"] = plit("plaster", (1.00, 0.90, 0.74), wet=0.3, spec=0.3, authored=2.0)
    M["plaster_green"] = plit("plaster", (0.70, 0.86, 0.78), wet=0.3, spec=0.3, authored=2.0)
    M["plaster_rust"] = plit("redplaster", (1.0, 1.0, 1.0), wet=0.3, spec=0.3, authored=2.0)
    M["brick"] = plit("brick", (0.9, 0.9, 0.9), wet=0.45, spec=0.4, authored=2.0)
    M["metal_grey"] = lit("metal_albedo", "metal_packed", (0.55, 0.57, 0.60), wet=0.5, spec=1.0)
    M["metal_dark"] = lit("metal_albedo", "metal_packed", (0.16, 0.16, 0.18), wet=0.5, spec=1.0)
    M["metal_white"] = lit("metal_albedo", "metal_packed", (0.90, 0.90, 0.88), wet=0.5, spec=1.0)
    M["rust_metal"] = plit("rust", (0.8, 0.8, 0.8), wet=0.5, spec=0.6, uvmul=1.0)
    # roller shutters: slats ~7.7 cm (scan rotated so ridges run horizontally)
    M["shutter"] = plit("shutter", (0.80, 0.83, 0.86), wet=0.5, spec=0.9, uvmul=1.0)
    M["corrugated"] = plit("corrugated", (0.70, 0.72, 0.72), wet=0.6, spec=0.9, uvmul=1.4)
    M["wood_dark"] = plit("wood", (1.0, 0.72, 0.52), wet=0.3, spec=0.5, uvmul=1.0)
    M["canvas"] = lit("canvas_albedo", "canvas_packed", (1, 1, 1), wet=0.6, spec=0.6)
    M["crate_blue"] = lit("metal_albedo", "metal_packed", (0.08, 0.28, 0.75), wet=0.6, spec=1.0)
    M["crate_yellow"] = lit("metal_albedo", "metal_packed", (0.95, 0.72, 0.08), wet=0.6, spec=1.0)
    M["rubber_black"] = lit("concrete2_albedo", "concrete2_packed", (0.10, 0.10, 0.10), wet=0.2, spec=0.3)
    M["cable"] = lit("metal_albedo", "metal_packed", (0.06, 0.06, 0.07), wet=0.5, spec=0.8)
    M["cone"] = lit("metal_albedo", "metal_packed", (1.0, 0.32, 0.06), wet=0.6, spec=1.0)
    M["pole_sleeve"] = lit("signs", "neutral_packed", (0.8, 0.8, 0.8), wet=0.5, spec=0.8)
    M["concrete_ground"] = ground("pavement", (0.80, 0.80, 0.82), [0.75, 1.0, 0.6, EXPOSURE])
    M["concrete_stoop"] = ground("pavement", (0.62, 0.62, 0.64), [0.45, 0.45, 0.2, EXPOSURE], aux="black")
    M["asphalt"] = ground("asphalt", (1, 1, 1), [1.0, 1.0, 1.0, EXPOSURE])
    M["grate"] = dict(shader="alleyGround", textures=dict(baseColor="grate_albedo", custom="grate_packed", emissiveColor="puddles"),
                      tint=[1, 1, 1], params=[0.9, 1.0, 0.0, EXPOSURE])
    M["manhole"] = dict(shader="alleyGround", textures=dict(baseColor="manhole_albedo", custom="manhole_packed", emissiveColor="puddles"),
                        tint=[1, 1, 1], params=[0.9, 1.0, 0.3, EXPOSURE])
    M["road_paint"] = dict(shader="alleyDecal", textures=dict(baseColor="road_paint", custom="neutral_packed", emissiveColor="puddles"),
                           tint=[0.85, 0.85, 0.82], params=[0.9, 1.0, 0.85, EXPOSURE], blend="transparent")
    M["sign_static"] = emissive("signs", 1.55)
    M["sign_flicker"] = emissive("signs", 1.75, flicker=1)
    M["sign_soft"] = emissive("signs", 0.85)
    M["sign_dim"] = emissive("signs", 0.55)
    M["sign_ticker"] = emissive("ticker", 1.6, scroll=0.045)
    M["vending"] = emissive("signs", 0.95)
    M["lantern"] = emissive("signs", 1.7, flicker=2)
    M["bulb"] = emissive("white", 2.6, tint=(1.0, 0.78, 0.5))
    M["aviation"] = emissive("white", 3.0, flicker=5, tint=(1.0, 0.06, 0.04))
    M["lamp_lens"] = emissive("white", 3.0, tint=(0.85, 0.93, 1.0))
    M["passage_red"] = emissive("white", 1.8, tint=(1.0, 0.12, 0.08))
    M["far_windows"] = emissive("far_windows", 0.85)
    M["windows"] = dict(shader="alleyWindow", textures=dict(baseColor="interiors", custom="neutral_packed"),
                        tint=[1, 1, 1], params=[1.25, 0.05, 0.0, EXPOSURE])
    M["windows_upper"] = dict(shader="alleyWindow", textures=dict(baseColor="interiors", custom="neutral_packed"),
                              tint=[1, 1, 1], params=[0.8, 0.035, 0.0, EXPOSURE])
    M["sky"] = dict(shader="alleySky", textures=dict(baseColor="sky", custom="neutral_packed"), tint=[1, 1, 1], params=[1.0, 0, 0, EXPOSURE])
    for k, (speed, opac) in enumerate(((5.2, 0.42), (5.0, 0.40), (4.8, 0.36), (4.6, 0.33), (4.4, 0.30), (4.4, 0.30))):
        M[f"rain_{k}"] = dict(shader="alleyRain", textures=dict(baseColor="rain", custom="neutral_packed"), tint=[1, 1, 1],
                              params=[speed, 0.137 * k, opac, EXPOSURE], blend="transparent", cull="none")
    M["steam"] = dict(shader="alleySteam", textures=dict(baseColor="steam", custom="neutral_packed"), tint=[1, 0.95, 0.9],
                      params=[0.18, 0.32, 0, EXPOSURE], blend="transparent", cull="none")

    M.update(props.materials(lit, EXPOSURE))

    # ---- portal / room side
    M["frame_body"] = dict(shader="pbr", textures=dict(baseColor="frame_brushed_albedo", roughness="frame_brushed_rough"), metallic=0.85, tint=[1, 1, 1])
    M["frame_trim"] = dict(shader="pbr", textures=dict(baseColor="frame_trim_albedo", roughness="frame_trim_rough"), metallic=1.0, tint=[1, 1, 1])
    M["frame_ceramic"] = dict(shader="pbr", textures=dict(baseColor="frame_ceramic_albedo", roughness="frame_ceramic_rough"), metallic=0.0, tint=[1, 1, 1])
    M["frame_bolt"] = dict(shader="pbr", color=[0.42, 0.42, 0.44], roughness=0.3, metallic=1.0)
    M["frame_detail"] = dict(shader="pbr", color=[0.02, 0.02, 0.022], roughness=0.75, metallic=0.0)
    M["frame_light"] = dict(shader="portalEdge", textures=dict(baseColor="white", custom="neutral_packed"), tint=[0.30, 0.86, 1.0], params=[0.6, 0.0, 0.0, 0.0])
    M["frame_led"] = dict(shader="portalEdge", textures=dict(baseColor="white", custom="neutral_packed"), tint=[1.0, 0.55, 0.12], params=[0.8, 0.0, 0.0, 0.0])
    M["occluder"] = dict(shader="occlusion")
    M["contact_shadow"] = dict(shader="contactShadow", textures=dict(baseColor="contact_shadow", custom="neutral_packed"), tint=[0, 0, 0],
                               params=[0.75, 0, 0, 0], blend="transparent")
    M["spill"] = dict(shader="floorSpill", textures=dict(baseColor="spill", custom="neutral_packed"), tint=[1, 1, 1],
                      params=[0.10, 0, 0, 0], blend="transparent")
    M["veil"] = dict(shader="portalVeil", textures=dict(baseColor="white", custom="neutral_packed"), tint=[0.05, 0.07, 0.12],
                     params=[0.0, 0, 0, EXPOSURE], blend="transparent", cull="none")
    M["seam"] = dict(shader="portalSeam", textures=dict(baseColor="white", custom="neutral_packed"), tint=[0.45, 0.92, 1.0],
                     params=[0.0, 0.01, 0, 0], blend="transparent", cull="none")
    M["footprint"] = dict(shader="previewGhost", textures=dict(baseColor="white", custom="neutral_packed"), tint=[0.45, 0.92, 1.0],
                          params=[0.9, 0, 0, 0], blend="transparent", cull="none")
    return M


# importance order for the light table (low tier uses the first LOW_TIER_LIGHTS)
LIGHT_ORDER = ["ramen_front", "near_lamp", "vending", "cafe_window", "lanterns", "laundromat", "bar_neon",
               "sign_stack", "arch_bulbs", "street_lamp", "pharmacy", "izakaya", "bookshop", "ramen_sign",
               "store", "car_sweep"]
LOW_TIER_LIGHTS = 10


def light_table():
    by = {l[0]: l for l in alley.LIGHTS}
    rows = [by[n] for n in LIGHT_ORDER]
    assert len(rows) == len(alley.LIGHTS)
    return rows


def emit_light_headers(rows):
    n = len(rows)
    def f(x):
        return f"{x:.4f}"
    metal = ["// GENERATED by Tools/assetgen/build.py - do not edit.",
             "// Alley point lights in portal space: pos.xyz, radius | colour*intensity.rgb, flicker id",
             f"#define ALLEY_LIGHT_COUNT {n}", f"#define ALLEY_LIGHT_COUNT_LOW {LOW_TIER_LIGHTS}",
             f"constant float4 ALLEY_LIGHT_POS[{n}] = {{"]
    glsl = ["// GENERATED by Tools/assetgen/build.py - do not edit.",
            f"#define ALLEY_LIGHT_COUNT {n}", f"#define ALLEY_LIGHT_COUNT_LOW {LOW_TIER_LIGHTS}",
            f"const vec4 ALLEY_LIGHT_POS[{n}] = vec4[{n}]("]
    pos = [f"    float4({f(p[0])}, {f(p[1])}, {f(p[2])}, {f(rad)})" for (_, p, c, i, rad, fl) in rows]
    col = [f"    float4({f(c[0] * i)}, {f(c[1] * i)}, {f(c[2] * i)}, {fl:.1f})" for (_, p, c, i, rad, fl) in rows]
    metal += [",\n".join(pos), "};", f"constant float4 ALLEY_LIGHT_COL[{n}] = {{", ",\n".join(col), "};", ""]
    glsl += [",\n".join(p.replace("float4", "vec4") for p in pos), ");",
             f"const vec4 ALLEY_LIGHT_COL[{n}] = vec4[{n}](", ",\n".join(c.replace("float4", "vec4") for c in col), ");", ""]
    names = "// order: " + ", ".join(r[0] for r in rows)
    metal.insert(1, names)
    glsl.insert(1, names)
    with open(os.path.join(ROOT, "App", "Shaders", "AlleyLights.h"), "w") as fh:
        fh.write("\n".join(metal))
    with open(os.path.join(GEN_PREVIEW, "alley_lights.glsl"), "w") as fh:
        fh.write("\n".join(glsl))


def main():
    t0 = time.time()
    tex, A, I = build_textures()
    print(f"textures: {len(tex)} ({time.time() - t0:.1f}s)")

    fr = frame.build_frame()
    aux = MeshBuilder()
    for b in (frame.build_occluders(), frame.build_aperture_leaf(), frame.build_contact_shadow(), frame.build_spill(),
              frame.build_veil(), frame.build_seam(), frame.build_preview_footprint()):
        aux.merge(b)
    world = alley.build(A, I)
    if "--no-bake" not in sys.argv:
        BAKE_STATS.update(bake.bake(world, materials(), light_table()))
    meshes = {}
    for name, mb in (("frame", fr), ("portal_aux", aux), ("alley", world)):
        rep = mb.check()
        # authored geometry must be exact; scanned props carry a few smoothing
        # seams where interpolated normals disagree with face winding
        bad = {k: v for k, v in rep.items() if v[1] < (0.97 if k[1].startswith("prop_") else 0.999)}
        assert not bad, f"winding/normal mismatch in {name}: {bad}"
        size = mb.write(os.path.join(MESH, f"{name}.pmsh"))
        v, t = mb.stats()
        meshes[name] = dict(file=f"meshes/{name}.pmsh", vertices=v, triangles=t, bytes=size)
        print(f"mesh {name}: {v} verts, {t} tris, {size / 1024:.0f} KiB")

    # Portal invariants: the doorway is entirely on the room side of the
    # occluder plane, the destination entirely behind it.
    zocc = frame.OCCLUDER_Z
    fz = min(p.arrays()[0][:, 2].min() for p in fr.parts.values())
    wz = max(p.arrays()[0][:, 2].max() for p in world.parts.values())
    assert fz > zocc + 0.0003, f"frame geometry behind the occluder plane: {fz}"
    assert wz < zocc - 0.004, f"destination geometry in front of the occluder plane: {wz}"
    print(f"invariants ok: frame min z {fz:.4f} > occluder {zocc} > alley max z {wz:.4f}")

    rows = light_table()
    emit_light_headers(rows)

    mats = materials()
    used = {m for (_, m) in list(fr.parts) + list(aux.parts) + list(world.parts)}
    missing = used - set(mats)
    assert not missing, f"materials missing definitions: {missing}"
    for m, d in mats.items():
        for t in d.get("textures", {}).values():
            assert t in tex, f"{m}: texture {t} missing"

    if "--no-audio" not in sys.argv:
        aud = audio.build(AUD)
    else:
        aud = json.load(open(os.path.join(RES, "manifest.json")))["audio"]
    manifest = dict(
        version=1,
        generatedBy="Tools/assetgen/build.py",
        sources=dict(photographedSurfaces=PHOTO_STATS, scannedProps=PROP_STATS, bakedLighting=BAKE_STATS,
                     license="CC0 (Poly Haven); see Vendor/polyhaven/provenance.json"),
        dimensions=frame.DIMENSIONS,
        alley=dict(groundY=alley.G, leftFacadeX=alley.XL, rightFacadeX=alley.XR, junctionZ=alley.Z_END),
        textures=tex,
        materials=mats,
        meshes=meshes,
        lights=[dict(name=r[0], position=list(r[1]), color=list(r[2]), intensity=r[3], radius=r[4], flicker=r[5]) for r in rows],
        lowTierLightCount=LOW_TIER_LIGHTS,
        audio=aud,
    )
    with open(os.path.join(RES, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1)
    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(RES) for f in fs)
    print(f"done in {time.time() - t0:.1f}s, bundle assets {total / 1024 / 1024:.1f} MiB")


if __name__ == "__main__":
    main()
