// AlleyShaders.metal
//
// RealityKit CustomMaterial surface shaders for the portal destination and
// the portal's own effects.  Every material uses the .unlit lighting model,
// which renders ONLY what set_emissive_color() writes (RealityKit docs), so
// the shading in AlleyShadingCore.h is the complete look of the alley.
//
// Shared conventions
//   custom_parameter()      float4 per material (see Tools/assetgen/build.py)
//   metallic_scale()        alley light count / 16 (quality tier)
//   base_color texture      albedo / emissive atlas (sRGB, sampled as linear)
//   custom texture          packed r rough, g ao, b mask (linear)
//   emissive_color texture  aux (puddle map for ground materials)
//   Positions are converted to portal space via model_to_world(): every alley
//   mesh is authored in portal space and parented with identity transforms.

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

#define INLINE inline
#include "AlleyLights.h"
#include "AlleyShadingCore.h"

constexpr sampler kRepeat(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(4));
constexpr sampler kClamp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

struct PortalSpace {
    float3 p;
    float3 n;
    float3 v;
};

static PortalSpace portal_space(thread realitykit::surface_parameters &params) {
    float4x4 m2w = params.uniforms().model_to_world();
    float3x3 R = float3x3(m2w[0].xyz, m2w[1].xyz, m2w[2].xyz);
    float3x3 Rt = transpose(R);
    PortalSpace s;
    s.p = Rt * (params.geometry().world_position() - m2w[3].xyz);
    s.n = normalize(Rt * params.geometry().normal());
    s.v = normalize(Rt * params.geometry().view_direction());
    return s;
}

static int light_count(thread realitykit::surface_parameters &params) {
    float k = float(params.material_constants().metallic_scale());
    return clamp(int(k * 16.0 + 0.5), 1, ALLEY_LIGHT_COUNT);
}

static float2 usd_uv(float2 uv) { return float2(uv.x, 1.0 - uv.y); }

// Writes go straight to params inside each entry point (never through a copy).
#define EMIT(c) params.surface().set_emissive_color(half3(c))

// ------------------------------------------------------------------ alley

[[visible]]
void alleyLit(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float2 uv = usd_uv(params.geometry().uv0());
    auto tex = params.textures();
    float3 tint = float3(params.material_constants().base_color_tint());
    float3 alb = float3(tex.base_color().sample(kRepeat, uv).rgb) * tint;
    float3 pk = float3(tex.custom().sample(kRepeat, uv).rgb);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    // geometry is two-sided in a few places (awnings, noren): face the viewer
    float3 n = dot(s.n, s.v) < 0.0 ? -s.n : s.n;
    EMIT(shade_lit(s.p, n, s.v, alb, pk, prm, t, light_count(params)));
}

[[visible]]
void alleyGround(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float2 uv = usd_uv(params.geometry().uv0());
    auto tex = params.textures();
    float3 tint = float3(params.material_constants().base_color_tint());
    float3 alb = float3(tex.base_color().sample(kRepeat, uv).rgb) * tint;
    float3 pk = float3(tex.custom().sample(kRepeat, uv).rgb);
    float2 puv = float2((s.p.x + 9.0) / 24.0, -s.p.z / 24.0);     // image space, row 0 = doorway
    float pud = float(tex.emissive_color().sample(kClamp, puv).r);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    EMIT(shade_ground(s.p, s.v, alb, pk, pud, prm, t, light_count(params)));
}

[[visible]]
void alleyDecal(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float2 uv = usd_uv(params.geometry().uv0());
    auto tex = params.textures();
    float4 paint = float4(tex.base_color().sample(kClamp, uv));
    float3 tint = float3(params.material_constants().base_color_tint());
    float2 puv = float2((s.p.x + 9.0) / 24.0, -s.p.z / 24.0);
    float pud = float(tex.emissive_color().sample(kClamp, puv).r);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    float4 gp = float4(prm.x, prm.y, 0.6, prm.w);
    float3 c = shade_ground(s.p, s.v, paint.rgb * tint, float3(0.35, 1.0, 0.6), pud * 0.6, gp, t, light_count(params));
    EMIT(c);
    params.surface().set_opacity(half(clamp(paint.a * prm.z, 0.0, 1.0)));
}

[[visible]]
void alleyEmissive(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    float2 uv = params.geometry().uv0();
    if (prm.z != 0.0) { uv.x = fract(uv.x + t * prm.z); }
    uv = usd_uv(uv);
    auto tex = params.textures();
    float3 tint = float3(params.material_constants().base_color_tint());
    float3 e = float3(tex.base_color().sample(kClamp, uv).rgb) * tint;
    EMIT(shade_emissive(s.p, s.n, s.v, e, prm, t));
}

[[visible]]
void alleyWindow(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    float2 uv = params.geometry().uv0() + window_parallax(s.n, s.v, prm.y);
    auto tex = params.textures();
    float3 interior = float3(tex.base_color().sample(kClamp, usd_uv(uv)).rgb);
    EMIT(shade_window(s.p, s.n, s.v, interior, prm, t, light_count(params)));
}

[[visible]]
void alleySky(realitykit::surface_parameters params)
{
    float2 uv = usd_uv(params.geometry().uv0());
    auto tex = params.textures();
    float3 c = float3(tex.base_color().sample(kClamp, uv).rgb);
    EMIT(shade_sky(c, params.uniforms().custom_parameter()));
}

[[visible]]
void alleyRain(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    float2 uv = params.geometry().uv0();
    uv.y = uv.y + t * prm.x / 6.0 + prm.y;
    auto tex = params.textures();
    float streak = float(tex.base_color().sample(kRepeat, usd_uv(uv)).r);
    float4 c = shade_rain(s.p, streak, prm, t, light_count(params));
    EMIT(c.rgb);
    params.surface().set_opacity(half(c.a));
}

[[visible]]
void alleySteam(realitykit::surface_parameters params)
{
    PortalSpace s = portal_space(params);
    float4 prm = params.uniforms().custom_parameter();
    float t = params.uniforms().time();
    float2 uv = params.geometry().uv0();
    uv.y -= t * prm.x;
    uv.x += sin(t * 0.3 + uv.y * 2.0) * 0.05;
    auto tex = params.textures();
    float d = float(tex.base_color().sample(kRepeat, usd_uv(uv)).r);
    float4 c = shade_steam(s.p, d, prm, t, light_count(params));
    EMIT(c.rgb);
    params.surface().set_opacity(half(c.a));
}

// ------------------------------------------------------------------ portal

// Cyan light channel / status LED.  prm.x intensity, prm.y opening sweep 0..1
[[visible]]
void portalEdge(realitykit::surface_parameters params)
{
    float4 prm = params.uniforms().custom_parameter();
    float3 tint = float3(params.material_constants().base_color_tint());
    float u = params.geometry().uv0().x;              // metres along the U path (0 .. ~5.4)
    float sweep = 0.0;
    if (prm.y > 0.0 && prm.y < 1.0) {
        float d = (u - prm.y * 5.6) / 0.35;
        sweep = exp(-d * d) * 1.6;
    }
    float3 c = tint * (prm.x + sweep);
    EMIT(a_tonemap(c, 1.0));
}

[[visible]]
void portalVeil(realitykit::surface_parameters params)
{
    float4 prm = params.uniforms().custom_parameter();
    float3 tint = float3(params.material_constants().base_color_tint());
    EMIT(tint);
    params.surface().set_opacity(half(clamp(prm.x, 0.0, 1.0)));
}

// Opening seam: two vertical light lines at 0.5 +/- prm.y (uv.x across the hole)
[[visible]]
void portalSeam(realitykit::surface_parameters params)
{
    float4 prm = params.uniforms().custom_parameter();
    float3 tint = float3(params.material_constants().base_color_tint());
    float2 uv = params.geometry().uv0();
    float d = abs(abs(uv.x - 0.5) - prm.y) / 0.006;
    float vfade = smoothstep(0.0, 0.08, uv.y) * smoothstep(1.0, 0.92, uv.y);
    float a = exp(-d * d) * vfade * prm.x;
    float halo = exp(-d * d * 0.04) * vfade * prm.x * 0.25;
    EMIT(a_tonemap(tint * (1.0 + 2.0 * a), 1.0));
    params.surface().set_opacity(half(clamp(a + halo, 0.0, 1.0)));
}

[[visible]]
void contactShadow(realitykit::surface_parameters params)
{
    float4 prm = params.uniforms().custom_parameter();
    auto tex = params.textures();
    float a = float(tex.base_color().sample(kClamp, usd_uv(params.geometry().uv0())).r);
    EMIT(float3(0.0));
    params.surface().set_opacity(half(clamp(a * prm.x, 0.0, 1.0)));
}

[[visible]]
void floorSpill(realitykit::surface_parameters params)
{
    float4 prm = params.uniforms().custom_parameter();
    auto tex = params.textures();
    float3 c = float3(tex.base_color().sample(kClamp, usd_uv(params.geometry().uv0())).rgb);
    float a = max(c.r, max(c.g, c.b));
    EMIT(c / max(a, 0.001) * 0.8);
    params.surface().set_opacity(half(clamp(a * prm.x, 0.0, 1.0)));
}

// Placement preview (ghost doorway + footprint): fresnel-weighted tint.
[[visible]]
void previewGhost(realitykit::surface_parameters params)
{
    float4 prm = params.uniforms().custom_parameter();
    float3 tint = float3(params.material_constants().base_color_tint());
    float ndv = abs(dot(params.geometry().normal(), params.geometry().view_direction()));
    float a = prm.x * (0.22 + 0.78 * pow(1.0 - ndv, 2.0));
    EMIT(tint);
    params.surface().set_opacity(half(clamp(a, 0.0, 1.0)));
}
