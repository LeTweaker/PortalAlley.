// AlleyShadingCore.h
//
// Shading model for the alley, written once in a neutral C-like subset that
// compiles both as Metal (included by AlleyShaders.metal) and as GLSL ES 3.0
// (concatenated by the desktop validation preview in Tools/preview).
//
// Dialect rules used here: float2/float3/float4 types (GLSL maps them with
// #define), float literals always have a decimal point, no pointers or
// references, no half, no address-space keywords, INLINE before functions.
//
// All positions/normals/view vectors are in PORTAL SPACE (metres, y = room
// floor, alley toward -z).  Lighting is computed analytically from a fixed
// table of authored lights (AlleyLights.h, generated) - the destination has its
// own night lighting and never receives light from the real room.

#ifndef ALLEY_SHADING_CORE
#define ALLEY_SHADING_CORE

#define A_PI 3.14159265
#define A_GROUND_Y (-0.12)

// Atmosphere / ambient (linear)
#define A_SKY_AMB    float3(0.012, 0.014, 0.030)
#define A_GROUND_AMB float3(0.007, 0.006, 0.008)
#define A_FOG_COL    float3(0.030, 0.034, 0.058)
#define A_SKY_REFL   float3(0.050, 0.034, 0.070)
// Bounce fill from the signage-lit street (ambient multiplier); baked AO is
// what gives this fill its shape.
#define A_FILL 2.2

INLINE float a_hash12(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Light amplitude modulation.  id: 0 steady, 1 neon stutter, 2 breathe,
// 3 car sweep (handled by a_light_position), 4 tv flicker, 5 aviation blink.
INLINE float a_flicker(float id, float t, float seed) {
    if (id < 0.5) { return 1.0; }
    if (id < 1.5) {
        // mostly steady; every few seconds a short burst of dropouts
        float burst = step(0.72, a_hash12(float2(floor(t * 0.55), seed + 3.0)));
        float r = a_hash12(float2(floor(t * 14.0), seed));
        return 1.0 - 0.8 * burst * step(0.5, r);
    }
    if (id < 2.5) { return 0.92 + 0.08 * sin(t * 1.3 + seed * 1.7); }
    if (id < 3.5) { return 1.0; }
    if (id < 4.5) { return 0.8 + 0.2 * a_hash12(float2(floor(t * 9.0), seed)); }
    return step(fract(t * 0.5 + seed * 0.37), 0.16) * 0.97 + 0.03;
}

// Car headlights pass along the cross lane every 17 s (3.2 s pass, +x to -x).
INLINE float4 a_light_position(float4 lp, float id, float t) {
    if (id > 2.5 && id < 3.5) {
        float u = t - floor(t / 17.0) * 17.0;
        float k = u / 3.2;
        float x = 14.0 - 22.0 * k;
        float on = step(u, 3.2) * smoothstep(0.0, 0.12, k) * smoothstep(1.0, 0.85, k);
        return float4(x, lp.y, lp.z, on);
    }
    return float4(lp.xyz, 1.0);
}

struct ALight {
    float3 diffuse;   // irradiance-like term (multiply by albedo)
    float3 spec;      // specular (already includes light colour)
    float3 glow;      // light near the point, for lit fog
};

// Sum the authored lights at p.  n, v unit (v toward the camera).
INLINE ALight a_lights(float3 p, float3 n, float3 v, float rough, float specK, float t, int count) {
    ALight o;
    o.diffuse = float3(0.0);
    o.spec = float3(0.0);
    o.glow = float3(0.0);
    float alpha = max(rough * rough, 0.015);
    float alpha2 = alpha * alpha;
    float ndv = max(dot(n, v), 0.025);
    float kGeom = (rough + 1.0) * (rough + 1.0) / 8.0;
    for (int i = 0; i < ALLEY_LIGHT_COUNT; i++) {
        if (i >= count) { break; }
        float4 lc = ALLEY_LIGHT_COL[i];
        float4 lp = a_light_position(ALLEY_LIGHT_POS[i], lc.w, t);
        float amp = lp.w * a_flicker(lc.w, t, float(i));
        float3 L = lp.xyz - p;
        float d2 = dot(L, L);
        float d = sqrt(d2);
        L = L / max(d, 0.0001);
        float rr = ALLEY_LIGHT_POS[i].w;
        float x = d / rr;
        float win = clamp(1.0 - x * x * x * x, 0.0, 1.0);
        win = win * win;
        float att = win / (d2 * 0.55 + 0.35);
        float ndl = clamp(dot(n, L), 0.0, 1.0);
        float wrap = clamp((dot(n, L) + 0.25) / 1.25, 0.0, 1.0);
        float3 c = lc.rgb * amp * att;
        o.diffuse += c * mix(ndl, wrap, 0.1) * 0.96;
        float3 h = normalize(L + v + float3(0.000001));
        float ndh = clamp(dot(n, h), 0.0, 1.0);
        float vdh = clamp(dot(v, h), 0.0, 1.0);
        float denom = ndh * ndh * (alpha2 - 1.0) + 1.0;
        float D = alpha2 / max(A_PI * denom * denom, 0.000001);
        float Gv = ndv / (ndv * (1.0 - kGeom) + kGeom);
        float Gl = ndl / max(ndl * (1.0 - kGeom) + kGeom, 0.0001);
        float F = 0.04 + 0.96 * pow(1.0 - vdh, 5.0);
        o.spec += c * D * Gv * Gl * F * specK / max(4.0 * ndv, 0.0001);
        o.glow += lc.rgb * amp * win * 0.6;
    }
    return o;
}

// Wet-ground reflection streaks: each light's mirror image smeared along the
// view direction (anisotropic microfacets of a rain-soaked surface).
INLINE float3 a_wet_streaks(float3 p, float3 n, float3 v, float sharp, float t, int count) {
    float3 R = reflect(-v, n);
    float3 acc = float3(0.0);
    float sl = mix(0.055, 0.009, sharp);         // lateral spread (radians-ish)
    float sv = sl * mix(6.0, 3.0, sharp);        // vertical (toward-viewer) spread
    for (int i = 0; i < ALLEY_LIGHT_COUNT; i++) {
        if (i >= count) { break; }
        float4 lc = ALLEY_LIGHT_COL[i];
        float4 lp = a_light_position(ALLEY_LIGHT_POS[i], lc.w, t);
        float amp = lp.w * a_flicker(lc.w, t, float(i));
        float3 L = lp.xyz - p;
        float d = length(L);
        L = L / max(d, 0.0001);
        if (L.y <= 0.0) { continue; }
        float3 side = normalize(cross(float3(0.0, 1.0, 0.0), L) + float3(0.0001, 0.0, 0.0));
        float3 dR = R - L;
        float lat = dot(dR, side);
        float ver = dR.y;
        float lobe = exp(-(lat * lat) / (sl * sl) - (ver * ver) / (sv * sv));
        acc += lc.rgb * amp * lobe / (1.0 + d * d * 0.02);
    }
    return acc;
}

// Rain ripples on puddles: returns a horizontal normal perturbation.
INLINE float2 a_ripple_cell(float2 xz, float t, float cellSize, float seed) {
    float2 q = xz / cellSize;
    float2 cell = floor(q);
    float2 f = q - cell - float2(0.5);
    float h = a_hash12(cell + seed);
    float2 off = float2(a_hash12(cell + float2(7.1, seed)), a_hash12(cell + float2(3.7, 1.0 + seed))) - float2(0.5);
    float2 d = f - off * 0.5;
    float r = length(d);
    float ph = fract(t * 0.85 + h);
    float radius = ph * 0.42;
    float k = (r - radius) * 26.0;
    float ring = exp(-k * k) * (1.0 - ph) * (1.0 - ph);
    return d / max(r, 0.001) * ring;
}

INLINE float2 a_ripples(float2 xz, float t) {
    return a_ripple_cell(xz, t, 0.28, 0.0) + a_ripple_cell(xz + float2(0.13, 0.07), t * 1.13, 0.21, 11.0) * 0.8;
}

// ---------------------------------------------------------- destination modes
// Floor / ceiling portals rotate the alley behind a horizontal aperture
// (PortalCore DestinationMode).  code = material roughness scale:
//   0 wall (no clip) | (0,0.5] floor: keep y < h, h = code*20 | (0.5,1] ceiling: keep y > h
INLINE float a_clip_keep(float code, float y) {
    if (code < 0.0005) { return 1.0; }
    if (code <= 0.5) { return step(y, code * 20.0 - 0.004); }
    return step((code - 0.5) * 20.0 + 0.004, y);
}

// Where fog distance is measured from: a typical viewer for each mode.
INLINE float3 a_fog_ref(float code) {
    if (code < 0.0005) { return float3(0.0, 1.3, 1.6); }
    if (code <= 0.5) { return float3(0.1, code * 20.0 + 1.3, -7.1); }
    return float3(0.1, (code - 0.5) * 20.0 - 1.5, -4.6);
}

INLINE float3 a_fog(float3 col, float3 p, float3 glow, float3 fogRef) {
    float dist = length(p - fogRef);
    float f = 1.0 - exp(-dist * 0.030);
    float low = exp(-max(p.y - A_GROUND_Y, 0.0) * 0.12);
    f = clamp(f * (0.65 + 0.35 * low), 0.0, 0.88);
    float3 fc = A_FOG_COL + glow * 0.035;
    return mix(col, fc, f);
}

// Soft-shoulder tonemap: ~linear below 0.6, compresses highlights to 1.0.
INLINE float3 a_tonemap(float3 c, float exposure) {
    float3 x = max(c * exposure, float3(0.0));
    float3 hi = float3(0.6) + float3(0.4) * (float3(1.0) - exp(-(x - float3(0.6)) / 0.4));
    return mix(x, hi, step(float3(0.6), x));
}

INLINE float3 a_ambient(float3 n, float ao) {
    return mix(A_GROUND_AMB, A_SKY_AMB, n.y * 0.5 + 0.5) * ao;
}

// Baked per-vertex lighting (uv1, written by Tools/assetgen/bake.py):
//   uv1.x = 3 - ao (in [2,3]),  uv1.y = 1 - visibility of the authored lights.
// A mesh without uv1 reads (0,0): use the pre-1.3 height approximation and
// treat every light as visible.  Returns float2(ao, vis).
INLINE float2 a_bake(float2 uv1, float heightAboveGround) {
    float baked = step(1.5, uv1.x);
    float aoH = mix(0.55, 1.0, smoothstep(0.0, 0.9, heightAboveGround));
    return float2(mix(aoH, clamp(3.0 - uv1.x, 0.0, 1.0), baked), mix(1.0, clamp(1.0 - uv1.y, 0.0, 1.0), baked));
}

// ------------------------------------------------------------------ surfaces

// Walls, props: albedo (linear, tinted), packed: r rough, g ao, b wet mask.
// bake: uv1 (see a_bake).  Direct light is scaled by baked light visibility
// (soft shadows of the authored lights); ambient and contact darkening by AO.
INLINE float3 shade_lit(float3 p, float3 n, float3 v, float3 albedo, float3 packed, float4 prm, float t, int count, float2 bake, float3 fogRef) {
    float wet = clamp(prm.x * (0.35 + 0.65 * packed.z), 0.0, 1.0);
    float rough = mix(packed.x, packed.x * 0.45, wet);
    float3 alb = albedo * mix(1.0, 0.62, wet);
    float2 b = a_bake(bake, p.y - A_GROUND_Y);
    float ao = packed.y * b.x;
    float direct = b.y * mix(1.0, ao, 0.45);
    ALight l = a_lights(p, n, v, rough, prm.y * (0.25 + 0.75 * wet), t, count);
    float3 col = alb * (l.diffuse * direct + a_ambient(n, ao) * A_FILL) + l.spec * direct;
    // faint sky sheen on wet upward-ish faces
    float fres = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 5.0);
    col += A_SKY_REFL * fres * wet * 0.6;
    return a_tonemap(a_fog(col, p, l.glow, fogRef), prm.w);
}

// Ground: puddle map (aux r), ripples, mirror-like streaks.
INLINE float3 shade_ground_detail(float3 p, float3 v, float3 albedo, float3 packed, float puddle, float4 prm, float t, int count, float3 detailNormal, float2 bake, float3 fogRef) {
    float wet = clamp(prm.x * (0.55 + 0.45 * packed.z), 0.0, 1.0);
    float pud = clamp(puddle * prm.x, 0.0, 1.0);
    float2 rp = a_ripples(float2(p.x, p.z), t) * prm.z;
    float3 baseN = normalize(mix(detailNormal, float3(0.0, 1.0, 0.0), pud * 0.9));
    float3 n = normalize(baseN + float3(rp.x * (0.04 + 0.55 * pud), 0.0, rp.y * (0.04 + 0.55 * pud)));
    float rough = mix(packed.x, 0.22, wet * 0.7);
    rough = mix(rough, 0.055, pud);
    float3 alb = albedo * mix(1.0, 0.55, wet);
    alb = mix(alb, alb * 0.32, pud);
    float2 b = a_bake(bake, 1.0);
    float ao = packed.y * b.x;
    float3 nflat = baseN;
    ALight l = a_lights(p, nflat, v, rough, 0.0, t, count);
    float3 col = alb * (l.diffuse * b.y * mix(1.0, ao, 0.45) + a_ambient(nflat, ao) * A_FILL);
    float sharp = clamp(1.0 - rough * 2.2, 0.0, 1.0);
    float fres = 0.02 + 0.98 * pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 5.0);
    float3 streak = a_wet_streaks(p, n, v, sharp, t, count);
    // reflections of the lights are not shadowed at the reflecting point;
    // only contact occlusion damps them
    col += streak * (0.06 + 0.94 * fres) * prm.y * (0.2 + 0.8 * max(wet, pud)) * sqrt(ao);
    float3 R = reflect(-v, n);
    col += A_SKY_REFL * clamp(R.y * 2.0, 0.0, 1.0) * fres * (0.3 + 0.7 * pud);
    return a_tonemap(a_fog(col, p, l.glow, fogRef), prm.w);
}

// Legacy/decal/desktop callers use an unperturbed normal unless they have maps.
INLINE float3 shade_ground(float3 p, float3 v, float3 albedo, float3 packed, float puddle, float4 prm, float t, int count, float3 fogRef) {
    return shade_ground_detail(p, v, albedo, packed, puddle, prm, t, count, float3(0.0, 1.0, 0.0), float2(0.0), fogRef);
}

// Emissive signage, lanterns, bulbs.  prm: gain, flicker id, scroll, exposure
INLINE float3 shade_emissive(float3 p, float3 n, float3 v, float3 emit, float4 prm, float t, float3 fogRef) {
    float f = a_flicker(prm.y, t, floor(p.x * 3.1 + p.z * 1.7));
    float3 col = emit * prm.x * f;
    // emissive surfaces still sit in the haze
    return a_tonemap(a_fog(col, p, float3(0.0), fogRef), prm.w);
}

// Shop windows: interior (already sampled with parallax) behind glass.
INLINE float3 shade_window(float3 p, float3 n, float3 v, float3 interior, float4 prm, float t, int count, float3 fogRef) {
    float f = a_flicker(prm.z, t, floor(p.z * 2.3));
    float ndv = clamp(dot(n, v), 0.0, 1.0);
    float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
    ALight l = a_lights(p, n, v, 0.04, 1.4, t, count);
    float3 col = interior * prm.x * f * (1.0 - fres) + (A_SKY_REFL * 1.4 + l.spec) * fres + l.spec * 0.25;
    return a_tonemap(a_fog(col, p, l.glow, fogRef), prm.w);
}

// Window interior parallax offset (USD uv units).  T = cross(up, n).
INLINE float2 window_parallax(float3 n, float3 v, float depth) {
    float3 T = normalize(cross(float3(0.0, 1.0, 0.0), n) + float3(0.0, 0.0, 0.00001));
    float3 vt = float3(dot(v, T), v.y, dot(v, n));
    float2 off = -float2(vt.x, vt.y) / max(vt.z, 0.3) * depth;
    return clamp(off, float2(-0.02), float2(0.02));
}

INLINE float3 shade_sky(float3 c, float4 prm) {
    return a_tonemap(c * prm.x, prm.w);
}

// Rain streak layer: returns rgb in .xyz, alpha in .w
INLINE float4 shade_rain(float3 p, float streak, float4 prm, float t, int count, float3 fogRef) {
    ALight l = a_lights(p, float3(0.0, 0.0, 1.0), float3(0.0, 0.0, 1.0), 1.0, 0.0, t, count);
    float3 lit = float3(0.10, 0.12, 0.16) + l.glow * 0.55;
    float hgt = p.y - A_GROUND_Y;
    float fade = smoothstep(0.0, 0.25, hgt) * (1.0 - smoothstep(4.5, 7.0, hgt));
    float a = clamp(streak * prm.z * fade, 0.0, 1.0);
    float3 col = a_tonemap(a_fog(lit, p, float3(0.0), fogRef), prm.w);
    return float4(col, a);
}

INLINE float4 shade_steam(float3 p, float density, float4 prm, float t, int count, float3 fogRef) {
    float2 c = float2(1.45, -10.4);
    float r = length(float2(p.x, p.z) - c);
    float hgt = p.y - (A_GROUND_Y + 3.35);
    float shape = exp(-r * r / (0.06 + hgt * 0.10)) * smoothstep(0.0, 0.25, hgt) * (1.0 - smoothstep(0.9, 1.8, hgt));
    ALight l = a_lights(p, float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0), 1.0, 0.0, t, count);
    float3 col = float3(0.08, 0.075, 0.08) + l.glow * 0.4;
    float a = clamp(density * shape * prm.y, 0.0, 1.0);
    return float4(a_tonemap(a_fog(col, p, float3(0.0), fogRef), prm.w), a);
}

#endif

