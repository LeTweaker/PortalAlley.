// PortalAlley desktop validation preview (WebGL2).
//
// Purpose: check composition, portal clipping and parallax from many
// viewpoints using the SAME meshes, textures, light table and shading core as
// the iOS app.  It is NOT a proof that iPhone AR works: there is no camera
// feed, no tracking and RealityKit's renderer is not involved.
//
// Compositing mirrors AR: (1) "camera image" = a synthetic room drawn with no
// depth, (2) depth-only occluders (OcclusionMaterial), (3) opaque frame + alley,
// (4) transparents back to front.
//
// URL params:
//   eye=x,y,z  look=x,y,z  t=seconds  fov=deg  w,h (canvas px)
//   quality=high|low   open=0..1 (aperture leaves)   room=1|0   veil=auto|0..1
//   noOccluder=1 (debug: shows what the occluder hides)

(function () {
  const Q = new URLSearchParams(location.search);
  const vec = (s, d) => (s ? s.split(",").map(Number) : d);
  const EYE = vec(Q.get("eye"), [0, 1.5, 2.2]);
  const LOOK = vec(Q.get("look"), [0, 1.1, 0]);
  const TIME = Number(Q.get("t") || 3.0);
  const FOV = Number(Q.get("fov") || 64);
  const QUALITY = Q.get("quality") || "high";
  const OPEN = Q.has("open") ? Number(Q.get("open")) : 1.0;
  const ROOM = Q.get("room") !== "0";
  const NO_OCC = Q.get("noOccluder") === "1";
  const NO_BAKE = Q.get("noBake") === "1";   // simulate the iOS 17 path (no uv1)
  // v1.3: mounting surface + boundary style + Resize/Rotate (mirror of PortalCore)
  const MODE = Q.get("mode") || "wall";           // wall | floor | ceiling
  const STYLE = Q.get("style") || "subtle";       // subtle | classic
  const ASCALE = Number(Q.get("scale") || 1), AROT = Number(Q.get("rot") || 0);
  const DEST = Q.get("dest");                    // destination id (manifest.destinations); default from manifest
  const AIM = vec(Q.get("aim"), MODE === "floor" ? [0, 0, -1.6] : (MODE === "ceiling" ? [0, 2.6, -1.4] : null));
  const W = Number(Q.get("w") || 540), H = Number(Q.get("h") || 1170);
  const BASE = "../../";
  const status = (s) => { document.getElementById("status").textContent = s; };

  const canvas = document.getElementById("c");
  canvas.width = W; canvas.height = H;
  canvas.style.width = W + "px"; canvas.style.height = H + "px";
  const gl = canvas.getContext("webgl2", { antialias: true, preserveDrawingBuffer: true });
  if (!gl) { status("WebGL2 unavailable"); return; }
  const aniso = gl.getExtension("EXT_texture_filter_anisotropic");

  // ---------------------------------------------------------------- math
  const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const normz = (a) => { const l = Math.hypot(...a); return a.map((x) => x / l); };
  function lookAt(e, c, up) {
    const f = normz(sub(c, e)), s = normz(cross(f, up)), u = cross(s, f);
    return [s[0], u[0], -f[0], 0, s[1], u[1], -f[1], 0, s[2], u[2], -f[2], 0, -dot(s, e), -dot(u, e), dot(f, e), 1];
  }
  function persp(fovy, asp, n, f) {
    const t = 1 / Math.tan(fovy / 2);
    return [t / asp, 0, 0, 0, 0, t, 0, 0, 0, 0, (f + n) / (n - f), -1, 0, 0, (2 * f * n) / (n - f), 0];
  }
  function mul(a, b) {
    const o = new Array(16).fill(0);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) for (let k = 0; k < 4; k++) o[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
    return o;
  }
  const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
  const I4 = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  const fromCols = (x, y, z, t) => [x[0], x[1], x[2], 0, y[0], y[1], y[2], 0, z[0], z[1], z[2], 0, t[0], t[1], t[2], 1];
  const xform = (m, p, w = 1) => [0, 1, 2].map((r) => m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r] * w);
  function inv4(m) {   // general 4x4 inverse (column-major)
    const a = m, o = new Array(16);
    o[0] = a[5]*a[10]*a[15]-a[5]*a[11]*a[14]-a[9]*a[6]*a[15]+a[9]*a[7]*a[14]+a[13]*a[6]*a[11]-a[13]*a[7]*a[10];
    o[4] = -a[4]*a[10]*a[15]+a[4]*a[11]*a[14]+a[8]*a[6]*a[15]-a[8]*a[7]*a[14]-a[12]*a[6]*a[11]+a[12]*a[7]*a[10];
    o[8] = a[4]*a[9]*a[15]-a[4]*a[11]*a[13]-a[8]*a[5]*a[15]+a[8]*a[7]*a[13]+a[12]*a[5]*a[11]-a[12]*a[7]*a[9];
    o[12] = -a[4]*a[9]*a[14]+a[4]*a[10]*a[13]+a[8]*a[5]*a[14]-a[8]*a[6]*a[13]-a[12]*a[5]*a[10]+a[12]*a[6]*a[9];
    o[1] = -a[1]*a[10]*a[15]+a[1]*a[11]*a[14]+a[9]*a[2]*a[15]-a[9]*a[3]*a[14]-a[13]*a[2]*a[11]+a[13]*a[3]*a[10];
    o[5] = a[0]*a[10]*a[15]-a[0]*a[11]*a[14]-a[8]*a[2]*a[15]+a[8]*a[3]*a[14]+a[12]*a[2]*a[11]-a[12]*a[3]*a[10];
    o[9] = -a[0]*a[9]*a[15]+a[0]*a[11]*a[13]+a[8]*a[1]*a[15]-a[8]*a[3]*a[13]-a[12]*a[1]*a[11]+a[12]*a[3]*a[9];
    o[13] = a[0]*a[9]*a[14]-a[0]*a[10]*a[13]-a[8]*a[1]*a[14]+a[8]*a[2]*a[13]+a[12]*a[1]*a[10]-a[12]*a[2]*a[9];
    o[2] = a[1]*a[6]*a[15]-a[1]*a[7]*a[14]-a[5]*a[2]*a[15]+a[5]*a[3]*a[14]+a[13]*a[2]*a[7]-a[13]*a[3]*a[6];
    o[6] = -a[0]*a[6]*a[15]+a[0]*a[7]*a[14]+a[4]*a[2]*a[15]-a[4]*a[3]*a[14]-a[12]*a[2]*a[7]+a[12]*a[3]*a[6];
    o[10] = a[0]*a[5]*a[15]-a[0]*a[7]*a[13]-a[4]*a[1]*a[15]+a[4]*a[3]*a[13]+a[12]*a[1]*a[7]-a[12]*a[3]*a[5];
    o[14] = -a[0]*a[5]*a[14]+a[0]*a[6]*a[13]+a[4]*a[1]*a[14]-a[4]*a[2]*a[13]-a[12]*a[1]*a[6]+a[12]*a[2]*a[5];
    o[3] = -a[1]*a[6]*a[11]+a[1]*a[7]*a[10]+a[5]*a[2]*a[11]-a[5]*a[3]*a[10]-a[9]*a[2]*a[7]+a[9]*a[3]*a[6];
    o[7] = a[0]*a[6]*a[11]-a[0]*a[7]*a[10]-a[4]*a[2]*a[11]+a[4]*a[3]*a[10]+a[8]*a[2]*a[7]-a[8]*a[3]*a[6];
    o[11] = -a[0]*a[5]*a[11]+a[0]*a[7]*a[9]+a[4]*a[1]*a[11]-a[4]*a[3]*a[9]-a[8]*a[1]*a[7]+a[8]*a[3]*a[5];
    o[15] = a[0]*a[5]*a[10]-a[0]*a[6]*a[9]-a[4]*a[1]*a[10]+a[4]*a[2]*a[9]+a[8]*a[1]*a[6]-a[8]*a[2]*a[5];
    const det = a[0] * o[0] + a[1] * o[4] + a[2] * o[8] + a[3] * o[12];
    return o.map((x) => x / det);
  }
  // PortalCore PortalPose.make / DestinationMode (keep in sync)
  function portalPose(dims) {
    if (MODE === "wall") return I4;
    let f = [AIM[0] - EYE[0], 0, AIM[2] - EYE[2]]; f = normz(f);
    const z = MODE === "floor" ? [0, 1, 0] : [0, -1, 0];
    const y = MODE === "floor" ? f : f.map((v) => -v);
    const x = cross(y, z);
    const c = (dims.openY0 + dims.openY1) / 2;
    const o = [0, 1, 2].map((i) => AIM[i] - z[i] * dims.occluderZ - y[i] * c);
    return fromCols(x, y, z, o);
  }
  const APERTURE = { floor: [0.1, 7.0, -8.0], ceiling: [0.1, 2.5, -5.2] };
  function worldXform(dims) {
    if (MODE === "wall") return I4;
    const R = MODE === "floor" ? [[1, 0, 0], [0, 0, 1], [0, -1, 0]] : [[1, 0, 0], [0, 0, -1], [0, 1, 0]];   // columns
    const a = APERTURE[MODE];
    const ra = [0, 1, 2].map((i) => R[0][i] * a[0] + R[1][i] * a[1] + R[2][i] * a[2]);
    const centre = [0, (dims.openY0 + dims.openY1) / 2, dims.occluderZ];
    return fromCols(R[0], R[1], R[2], centre.map((v, i) => v - ra[i]));
  }
  let CLIP = MODE === "floor" ? APERTURE.floor[1] / 20 : (MODE === "ceiling" ? 0.5 + APERTURE.ceiling[1] / 20 : 0);
  function apertureAdjust(dims) {
    const a = AROT * Math.PI / 180, c = Math.cos(a) * ASCALE, sn = Math.sin(a) * ASCALE;
    const pv = [0, MODE === "wall" ? 0 : (dims.openY0 + dims.openY1) / 2, 0];
    const m = [c, sn, 0, 0, -sn, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
    const p = xform(m, pv);
    m[12] = pv[0] - p[0]; m[13] = pv[1] - p[1];
    return m;
  }

  // ------------------------------------------------- boundary policy (mirror of PortalCore.BoundaryPolicy)
  function boundary(cam, dims) {
    const d = cam[2] - dims.frameBackZ;
    const behind = d < 0.02;
    const inFront = Math.abs(cam[0]) < dims.outerHalfWidth + 0.25 && cam[1] < dims.outerTop + 0.3;
    const open = behind ? 0 : (inFront ? smooth(0.30, 0.55, d) : 1);
    return { worldVisible: !behind, veil: behind ? 0 : 1 - open };
  }

  // ---------------------------------------------------------------- loaders
  async function fetchText(p) { const r = await fetch(BASE + p); if (!r.ok) throw new Error(p); return r.text(); }
  async function fetchBuf(p) { const r = await fetch(BASE + p); if (!r.ok) throw new Error(p); return r.arrayBuffer(); }

  function parsePMSH(buf) {
    const dv = new DataView(buf);
    const td = new TextDecoder();
    let o = 0;
    const magic = td.decode(new Uint8Array(buf, 0, 4)); o = 4;
    if (magic !== "PMSH") throw new Error("bad mesh");
    const version = dv.getUint32(o, true); o += 4; const n = dv.getUint32(o, true); o += 4;
    const parts = [];
    for (let i = 0; i < n; i++) {
      const nl = dv.getUint16(o, true); o += 2; const name = td.decode(new Uint8Array(buf, o, nl)); o += nl;
      const ml = dv.getUint16(o, true); o += 2; const mat = td.decode(new Uint8Array(buf, o, ml)); o += ml;
      const vc = dv.getUint32(o, true); o += 4; const ic = dv.getUint32(o, true); o += 4;
      let flags = 0; if (version >= 2) { flags = dv.getUint32(o, true); o += 4; }
      const take = (count, T, bytes) => { const a = new T(buf.slice(o, o + count * bytes)); o += count * bytes; return a; };
      const pos = take(vc * 3, Float32Array, 4), nrm = take(vc * 3, Float32Array, 4), uv = take(vc * 2, Float32Array, 4);
      // no baked lighting: (0,0) = "absent", like a RealityKit mesh without uv1
      const uv1 = (flags & 1) && !NO_BAKE ? take(vc * 2, Float32Array, 4) : ((flags & 1) ? (take(vc * 2, Float32Array, 4), new Float32Array(vc * 2)) : new Float32Array(vc * 2));
      const idx = take(ic, Uint32Array, 4);
      parts.push({ name, mat, pos, nrm, uv, uv1, idx });
    }
    return parts;
  }

  function loadImage(src) {
    return new Promise((res, rej) => { const im = new Image(); im.onload = () => res(im); im.onerror = rej; im.src = src; });
  }

  async function loadTexture(info, lowTier) {
    const im = await loadImage(BASE + "App/Resources/Portal/" + info.file);
    let src = im;
    if (lowTier && im.width > 64) {
      const c = document.createElement("canvas"); c.width = im.width / 2; c.height = im.height / 2;
      c.getContext("2d").drawImage(im, 0, 0, c.width, c.height); src = c;
    }
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    const srgb = info.semantic === "color";
    gl.texImage2D(gl.TEXTURE_2D, 0, srgb ? gl.SRGB8_ALPHA8 : gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, src);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    if (aniso) gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, 4);
    return t;
  }

  // ---------------------------------------------------------------- shaders
  const VS = `#version 300 es
  in vec3 aPos; in vec3 aNrm; in vec2 aUV; in vec2 aUV1;
  uniform mat4 uVP; uniform mat4 uModel;
  out vec3 vPos; out vec3 vNrm; out vec2 vUV; out vec2 vUV1;
  // shading happens in the mesh's own space (portal / alley space), exactly as
  // the Metal shaders do via model_to_world; uCam is given in that space
  void main(){ vPos = aPos; vNrm = aNrm; vUV = aUV; vUV1 = aUV1; gl_Position = uVP * uModel * vec4(aPos,1.0); }`;

  const PRE = `#version 300 es
  precision highp float; precision highp int;
  #define float2 vec2
  #define float3 vec3
  #define float4 vec4
  #define INLINE
  `;
  const COMMON = `
  uniform sampler2D uBase; uniform sampler2D uCustom; uniform sampler2D uAux; uniform sampler2D uNormal; uniform int uHasNormal;
  uniform vec3 uTint; uniform vec4 uPrm; uniform float uTime; uniform int uLightCount; uniform vec3 uCam; uniform float uClip;
  in vec3 vPos; in vec3 vNrm; in vec2 vUV; in vec2 vUV1;
  out vec4 frag;
  vec2 usd_uv(vec2 uv){ return vec2(uv.x, 1.0 - uv.y); }
  vec3 to_srgb(vec3 c){ c = clamp(c, 0.0, 1.0); return mix(c*12.92, 1.055*pow(c, vec3(1.0/2.4)) - 0.055, step(vec3(0.0031308), c)); }
  vec3 V(){ return normalize(uCam - vPos); }
  // same derivative cotangent frame as photographic_normal() in AlleyShaders.metal
  vec3 photo_normal(vec3 p, vec3 n, vec2 uv){
    if(uHasNormal==0) return n;
    vec3 dp1=dFdx(p), dp2=dFdy(p); vec2 duv1=dFdx(uv), duv2=dFdy(uv);
    vec3 a=cross(dp2,n), b=cross(n,dp1);
    vec3 T=a*duv1.x+b*duv2.x, B=a*duv1.y+b*duv2.y;
    float sc=inversesqrt(max(max(dot(T,T),dot(B,B)),1e-10));
    vec3 d=texture(uNormal,uv).rgb*2.0-1.0; d.xy*=0.7;
    return normalize(T*sc*d.x+B*sc*d.y+n*d.z);
  }
  vec3 lit_color(out float alpha){ vec3 v=V(); vec3 n=normalize(vNrm); if(dot(n,v)<0.0) n=-n;
    vec2 uv=usd_uv(vUV)*(uPrm.z>0.0?uPrm.z:1.0);
    vec4 base=texture(uBase,uv); alpha=base.a; vec3 alb=base.rgb*uTint; vec3 pk=texture(uCustom,uv).rgb;
    n=photo_normal(vPos,n,uv);
    return shade_lit(vPos,n,v,alb,pk,uPrm,uTime,uLightCount,vUV1,a_fog_ref(uClip)); }
  #define CLIP() if(a_clip_keep(uClip, vPos.y) < 0.5) discard
  `;
  const ENTRY = {
    alleyLit: `void main(){ CLIP(); float a; frag=vec4(to_srgb(lit_color(a)),1.0);} `,
    alleyLitCutout: `void main(){ CLIP(); float a; vec3 c=lit_color(a); if(a<0.5) discard; frag=vec4(to_srgb(c),1.0);} `,
    alleyGround: `void main(){ CLIP(); vec3 v=V(); vec2 uv=usd_uv(vUV);
      vec3 alb=texture(uBase,uv).rgb*uTint; vec3 pk=texture(uCustom,uv).rgb;
      float pud=texture(uAux, vec2((vPos.x+9.0)/24.0, -vPos.z/24.0)).r;
      vec3 dn=photo_normal(vPos,vec3(0.0,1.0,0.0),uv);
      frag=vec4(to_srgb(shade_ground_detail(vPos,v,alb,pk,pud,uPrm,uTime,uLightCount,dn,vUV1,a_fog_ref(uClip))),1.0);} `,
    alleyDecal: `void main(){ CLIP(); vec3 v=V(); vec2 uv=usd_uv(vUV); vec4 paint=texture(uBase,uv);
      float pud=texture(uAux, vec2((vPos.x+9.0)/24.0, -vPos.z/24.0)).r;
      vec3 c=shade_ground(vPos,v,paint.rgb*uTint,vec3(0.35,1.0,0.6),pud*0.6,vec4(uPrm.x,uPrm.y,0.6,uPrm.w),uTime,uLightCount,a_fog_ref(uClip));
      frag=vec4(to_srgb(c), clamp(paint.a*uPrm.z,0.0,1.0));} `,
    alleyEmissive: `void main(){ CLIP(); vec3 v=V(); vec2 uv=vUV; if(uPrm.z!=0.0) uv.x=fract(uv.x+uTime*uPrm.z);
      vec3 e=texture(uBase,usd_uv(uv)).rgb*uTint; frag=vec4(to_srgb(shade_emissive(vPos,normalize(vNrm),v,e,uPrm,uTime,a_fog_ref(uClip))),1.0);} `,
    alleyWindow: `void main(){ CLIP(); vec3 v=V(); vec3 n=normalize(vNrm); vec2 uv=vUV+window_parallax(n,v,uPrm.y);
      vec3 interior=texture(uBase,usd_uv(uv)).rgb; frag=vec4(to_srgb(shade_window(vPos,n,v,interior,uPrm,uTime,uLightCount,a_fog_ref(uClip))),1.0);} `,
    videoScreen: `void main(){ frag=vec4(to_srgb(texture(uBase,usd_uv(vUV)).rgb),1.0);} `,
    captureUnlit: `void main(){ CLIP(); vec3 c=texture(uBase,usd_uv(vUV)).rgb*uTint; frag=vec4(to_srgb(shade_capture(c,uPrm)),1.0);} `,
    captureSky: `void main(){ CLIP(); frag=vec4(to_srgb(shade_capture_sky(vPos,uTint,uPrm.xyz)),1.0);} `,
    captureRain: `void main(){ CLIP(); vec2 uv=vUV; uv.y=uv.y+uTime*uPrm.x/6.0+uPrm.y; float st=texture(uBase,usd_uv(uv)).r;
      vec4 c=shade_capture_rain(vPos,st,uTint,uPrm); frag=vec4(to_srgb(c.rgb),c.a);} `,
    alleySky: `void main(){ CLIP(); vec3 c=texture(uBase,usd_uv(vUV)).rgb; frag=vec4(to_srgb(shade_sky(c,uPrm)),1.0);} `,
    alleyRain: `void main(){ CLIP(); vec2 uv=vUV; uv.y=uv.y+uTime*uPrm.x/6.0+uPrm.y; float s=texture(uBase,usd_uv(uv)).r;
      vec4 c=shade_rain(vPos,s,uPrm,uTime,uLightCount,a_fog_ref(uClip)); frag=vec4(to_srgb(c.rgb),c.a);} `,
    alleySteam: `void main(){ CLIP(); vec2 uv=vUV; uv.y-=uTime*uPrm.x; uv.x+=sin(uTime*0.3+uv.y*2.0)*0.05; float d=texture(uBase,usd_uv(uv)).r;
      vec4 c=shade_steam(vPos,d,uPrm,uTime,uLightCount,a_fog_ref(uClip)); frag=vec4(to_srgb(c.rgb),c.a);} `,
    portalEdge: `void main(){ float u=vUV.x; float sw=0.0; if(uPrm.y>0.0&&uPrm.y<1.0){ float d=(u-uPrm.y*5.6)/0.35; sw=exp(-d*d)*1.6; }
      frag=vec4(to_srgb(a_tonemap(uTint*(uPrm.x+sw),1.0)),1.0);} `,
    portalVeil: `void main(){ frag=vec4(to_srgb(uTint), clamp(uPrm.x,0.0,1.0)); }`,
    portalSeam: `void main(){ float d=abs(abs(vUV.x-0.5)-uPrm.y)/0.006; float vf=smoothstep(0.0,0.08,vUV.y)*smoothstep(1.0,0.92,vUV.y);
      float a=exp(-d*d)*vf*uPrm.x; float halo=exp(-d*d*0.04)*vf*uPrm.x*0.25; frag=vec4(to_srgb(a_tonemap(uTint*(1.0+2.0*a),1.0)), clamp(a+halo,0.0,1.0)); }`,
    contactShadow: `void main(){ float a=texture(uBase,usd_uv(vUV)).r; frag=vec4(0.0,0.0,0.0,clamp(a*uPrm.x,0.0,1.0)); }`,
    floorSpill: `void main(){ vec3 c=texture(uBase,usd_uv(vUV)).rgb; float a=max(c.r,max(c.g,c.b)); frag=vec4(to_srgb(c/max(a,0.001)*0.8), clamp(a*uPrm.x,0.0,1.0)); }`,
    previewGhost: `void main(){ float ndv=abs(dot(normalize(vNrm),V())); frag=vec4(to_srgb(uTint), clamp(uPrm.x*(0.22+0.78*pow(1.0-ndv,2.0)),0.0,1.0)); }`,
    // RealityKit PBR stand-in for the frame: lit by a plausible indoor environment.
    pbr: `uniform float uMetal; uniform float uRough; uniform int uHasTex;
      vec3 env(vec3 r){ vec3 ceil=vec3(0.55,0.52,0.48); vec3 wall=vec3(0.30,0.28,0.26); vec3 flr=vec3(0.16,0.13,0.10);
        vec3 c = r.y>0.0 ? mix(wall,ceil,smoothstep(0.0,0.8,r.y)) : mix(wall,flr,smoothstep(0.0,0.5,-r.y));
        c += vec3(1.6,1.5,1.3)*pow(max(dot(r,normalize(vec3(-0.4,0.8,0.5))),0.0),40.0); return c; }
      void main(){ vec3 v=V(); vec3 n=normalize(vNrm); vec2 uv=usd_uv(vUV);
        vec3 alb = uHasTex==1 ? texture(uBase,uv).rgb : uTint; float rough = uHasTex==1 ? texture(uCustom,uv).r : uRough;
        vec3 L=normalize(vec3(-0.4,0.8,0.5)); float ndl=max(dot(n,L),0.0);
        vec3 F0=mix(vec3(0.04),alb,uMetal); float ndv=max(dot(n,v),0.0);
        vec3 F=F0+(1.0-F0)*pow(1.0-ndv,5.0)*(1.0-rough);
        vec3 R=reflect(-v,n); vec3 spec=F*env(R)*mix(1.0,0.35,rough);
        vec3 H=normalize(L+v); float a2=rough*rough*rough*rough; float d=max(dot(n,H),0.0); float D=a2/(3.14159*pow(d*d*(a2-1.0)+1.0,2.0));
        vec3 col = alb*(1.0-uMetal)*(vec3(0.22,0.21,0.20)+vec3(0.9,0.85,0.78)*ndl) + spec + F0*D*ndl*0.25;
        frag=vec4(to_srgb(col),1.0);} `,
    room: `void main(){ vec3 n=normalize(vNrm); vec3 c=uTint; vec2 g=vPos.xz;
        if(n.y>0.5){ float plank=step(0.97,fract(g.x*5.0)); float tone=0.9+0.1*sin(floor(g.x*5.0)*12.9); c*=tone*(1.0-0.25*plank); }
        else if(n.z>0.5 && vPos.z>-0.2){ c=vec3(0.80,0.77,0.71); }
        float l=0.55+0.45*max(dot(n,normalize(vec3(-0.3,0.9,0.4))),0.0); frag=vec4(c*l,1.0);} `,
  };

  function compile(type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(s);
      const lines = src.split("\n").map((l, i) => `${i + 1}: ${l}`).join("\n");
      console.error(log + "\n" + lines);
      throw new Error("shader compile failed: " + log);
    }
    return s;
  }

  // ---------------------------------------------------------------- main
  async function main() {
    const manifest = JSON.parse(await fetchText("App/Resources/Portal/manifest.json"));
    const lightsGLSL = await fetchText("Tools/preview/generated/alley_lights.glsl");
    const core = await fetchText("App/Shaders/AlleyShadingCore.h");
    const progs = {};
    const vs = compile(gl.VERTEX_SHADER, VS);
    for (const [name, body] of Object.entries(ENTRY)) {
      const fs = compile(gl.FRAGMENT_SHADER, PRE + lightsGLSL.replace(/^\/\/.*$/gm, "") + "\n" + core + COMMON + body);
      const p = gl.createProgram(); gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, "aPos"); gl.bindAttribLocation(p, 1, "aNrm"); gl.bindAttribLocation(p, 2, "aUV"); gl.bindAttribLocation(p, 3, "aUV1");
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error("link " + name + ": " + gl.getProgramInfoLog(p));
      const u = {};
      const nU = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
      for (let i = 0; i < nU; i++) { const info = gl.getActiveUniform(p, i); u[info.name] = gl.getUniformLocation(p, info.name); }
      progs[name] = { p, u };
    }
    status("shaders ok, loading textures…");
    const low = QUALITY === "low";
    const tex = {};
    await Promise.all(Object.entries(manifest.textures).map(async ([k, info]) => { tex[k] = await loadTexture(info, low); }));

    const destId = DEST || manifest.defaultDestination || "illustrated";
    const dest = (manifest.destinations || {})[destId] || { kind: "illustrated", mesh: "alley" };
    const worldMesh = QUALITY === "low" && dest.meshLow ? dest.meshLow : dest.mesh;
    const meshes = {};
    const meshKeys = ["frame", "portal_aux"].concat(worldMesh ? [worldMesh] : []);
    for (const k of meshKeys) meshes[k] = parsePMSH(await fetchBuf("App/Resources/Portal/" + manifest.meshes[k].file));
    // Cinematic: a decoded frame of the bundled H.264 clip (headless Chrome
    // under virtual time does not deliver <video> frames); frames are made by
    // ffmpeg from App/Resources/Portal/video into Tools/preview/generated/footage
    if (dest.kind === "video") {
      const stem = dest.file.split("/").pop().replace(".mp4", "");
      const t = TIME < 2.5 ? 1 : (TIME < 6 ? 4 : 8);
      tex.__video = await loadTexture({ file: `../../../Tools/preview/generated/footage/${stem}_t${t}.jpg`, semantic: "color" }, false);
    }
    const dims = manifest.dimensions;

    function upload(part) {
      const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
      const mk = (data, loc, size) => { const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, size, gl.FLOAT, false, 0, 0); };
      mk(part.pos, 0, 3); mk(part.nrm, 1, 3); mk(part.uv, 2, 2); mk(part.uv1 || new Float32Array(part.pos.length / 3 * 2), 3, 2);
      const ib = gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, part.idx, gl.STATIC_DRAW);
      gl.bindVertexArray(null);
      let cx = 0, cy = 0, cz = 0; const n = part.pos.length / 3;
      for (let i = 0; i < n; i++) { cx += part.pos[3 * i]; cy += part.pos[3 * i + 1]; cz += part.pos[3 * i + 2]; }
      return { vao, count: part.idx.length, centroid: [cx / n, cy / n, cz / n], ...part };
    }

    // synthetic room = "camera image" (drawn first, no depth)
    function roomMesh() {
      const P = [], N = [], UV = [], I = [];
      const quad = (o, u, v, n) => { const b = P.length / 3; for (const [a, c] of [[0, 0], [1, 0], [1, 1], [0, 1]]) { P.push(o[0] + u[0] * a + v[0] * c, o[1] + u[1] * a + v[1] * c, o[2] + u[2] * a + v[2] * c); N.push(...n); UV.push(a, c); } I.push(b, b + 1, b + 2, b, b + 2, b + 3); };
      quad([-4, 0, 5], [8, 0, 0], [0, 0, -9.2], [0, 1, 0]);          // floor (extends behind the doorway)
      quad([4, 0, -4.2], [-8, 0, 0], [0, 2.6, 0], [0, 0, 1]);        // back wall of the real room, 4.2 m behind
      quad([-4, 0, 5], [0, 0, -9.2], [0, 2.6, 0], [1, 0, 0]);        // left wall
      quad([4, 0, -4.2], [0, 0, 9.2], [0, 2.6, 0], [-1, 0, 0]);      // right wall
      quad([-1.6, 0, -4.18], [0.9, 0, 0], [0, 1.9, 0], [0, 0, 1]);   // a door in the back wall (reference)
      quad([2.6, 0.0, -1.5], [0.9, 0, 0], [0, 0.75, 0], [0, 0, 1]);  // a cabinet beside the doorway area
      if (MODE === "ceiling") quad([-4, 2.6, -4.2], [8, 0, 0], [0, 0, 9.2], [0, -1, 0]);   // ceiling
      if (MODE === "wall" && STYLE === "subtle") {
        // the real wall the opening is cut into (subtle style is for walls;
        // floating doorways use the classic frame), part of the camera image
        const hw = 0.48 * ASCALE, y0 = 0.03 * ASCALE, y1 = 2.05 * ASCALE, z = -0.125, n = [0, 0, 1];
        quad([-4, 0, z], [4 - hw, 0, 0], [0, 2.6, 0], n);
        quad([hw, 0, z], [4 - hw, 0, 0], [0, 2.6, 0], n);
        quad([-hw, 0, z], [2 * hw, 0, 0], [0, y0, 0], n);
        quad([-hw, y1, z], [2 * hw, 0, 0], [0, 2.6 - y1, 0], n);
      }
      return { pos: new Float32Array(P), nrm: new Float32Array(N), uv: new Float32Array(UV), idx: new Uint32Array(I), mat: "room" };
    }

    const P = portalPose(dims), Wm = worldXform(dims), A = apertureAdjust(dims);
    const PA = mul(P, A), PW = mul(P, Wm);
    const APERTURE_CHUNKS = new Set(["frame", "occluder", "occluder_exact", "leaf", "shadow", "spill", "veil", "veil_exact", "seam", "footprint", "trim", "reveal"]);
    const parts = [];
    for (const k of meshKeys) for (const p of meshes[k]) {
      const u = upload(p);
      u.world = !APERTURE_CHUNKS.has(p.name);
      u.model = u.world ? PW : PA;
      parts.push(u);
    }
    // floor / ceiling views see all around: close the sky (mirrors PortalRig full sky)
    if (MODE !== "wall" && dest.kind === "illustrated") {
      const Pp = [], Nn = [], Uu = [], Ii = [], na = 48, ne = 24, R = 110;
      for (let j = 0; j <= ne; j++) for (let i = 0; i <= na; i++) {
        const el = -Math.PI / 2 + Math.PI * j / ne, az = 2 * Math.PI * i / na;
        const d = [Math.sin(az) * Math.cos(el), Math.sin(el), -Math.cos(az) * Math.cos(el)];
        Pp.push(d[0] * R, d[1] * R - 0.12, d[2] * R); Nn.push(-d[0], -d[1], -d[2]); Uu.push(i / na, Math.max(0, Math.min(1, (el * 180 / Math.PI + 5) / 90)));
      }
      for (let j = 0; j < ne; j++) for (let i = 0; i < na; i++) { const q = j * (na + 1) + i, r = q + na + 1; Ii.push(q, r + 1, q + 1, q, r, r + 1); }
      const sky = upload({ name: "fullsky", mat: "sky", pos: new Float32Array(Pp), nrm: new Float32Array(Nn), uv: new Float32Array(Uu), idx: new Uint32Array(Ii) });
      sky.world = true; sky.model = PW; sky.cullNone = true;
      parts.push(sky);
    }
    if (dest.kind === "video") {
      const fit = (depth, aspect) => {
        const zP = dims.occluderZ - depth, a = 35 * Math.PI / 180; let lo = [1e9, 1e9], hi = [-1e9, -1e9];
        const cs = [[-dims.openHalfWidth, dims.openY0], [dims.openHalfWidth, dims.openY0], [-dims.openHalfWidth, dims.openY1], [dims.openHalfWidth, dims.openY1]];
        for (const d of [1.2, 4.0]) for (const ang of [-a, 0, a]) for (const h of [0.9, 2.0]) {
          const v = [Math.sin(ang) * d, h, Math.cos(ang) * d];
          for (const c of cs) { const k = (zP - v[2]) / (dims.occluderZ - v[2]); const x = v[0] + (c[0] - v[0]) * k, y = v[1] + (c[1] - v[1]) * k;
            lo = [Math.min(lo[0], x), Math.min(lo[1], y)]; hi = [Math.max(hi[0], x), Math.max(hi[1], y)]; }
        }
        let w = hi[0] - lo[0], h = hi[1] - lo[1]; if (w / h < aspect) w = h * aspect; else h = w / aspect;
        return { c: [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, zP], w, h };
      };
      const sc = fit(dest.screenDepth || 2.5, dest.aspect || 16 / 9);
      const quad = (name, mat, c, w, h, z) => upload({ name, mat, pos: new Float32Array([c[0] - w / 2, c[1] - h / 2, z, c[0] + w / 2, c[1] - h / 2, z, c[0] + w / 2, c[1] + h / 2, z, c[0] - w / 2, c[1] + h / 2, z]),
        nrm: new Float32Array([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]), uv: new Float32Array([0, 0, 1, 0, 1, 1, 0, 1]), idx: new Uint32Array([0, 1, 2, 0, 2, 3]) });
      manifest.materials.__screen = { shader: "videoScreen", textures: { baseColor: "__video" } };
      manifest.materials.__matte = { shader: "videoScreen", textures: { baseColor: "black" } };
      for (const [n, m, w, h, z] of [["screen", "__screen", sc.w, sc.h, sc.c[2]], ["matte", "__matte", sc.w * 6, sc.h * 6, sc.c[2] - 0.05]]) {
        const q = quad(n, m, sc.c, w, h, z); q.world = true; q.model = PW; parts.push(q);
      }
    }
    const room = upload(roomMesh());
    room.model = I4;

    // camera
    const view = lookAt(EYE, LOOK, Math.abs(normz(sub(LOOK, EYE))[1]) > 0.98 ? [0, 0, -1] : [0, 1, 0]);
    const proj = persp((FOV * Math.PI) / 180, W / H, 0.01, 300);
    const VP = mul(proj, view);
    const camPortal = xform(inv4(PA), EYE);
    const B = boundary(camPortal, dims);

    function setCommon(pr, mat, part) {
      gl.useProgram(pr.p);
      const M = part ? part.model : I4;
      gl.uniformMatrix4fv(pr.u.uVP, false, VP);
      if (pr.u.uModel) gl.uniformMatrix4fv(pr.u.uModel, false, M);
      if (pr.u.uTime) gl.uniform1f(pr.u.uTime, TIME);
      if (pr.u.uCam) gl.uniform3fv(pr.u.uCam, xform(inv4(M), EYE));
      if (pr.u.uClip) gl.uniform1f(pr.u.uClip, part && part.world ? CLIP : 0);
      if (pr.u.uLightCount) gl.uniform1i(pr.u.uLightCount, low ? manifest.lowTierLightCount : 16);
      if (pr.u.uTint) gl.uniform3fv(pr.u.uTint, mat.tint || mat.color || [1, 1, 1]);
      if (pr.u.uPrm) gl.uniform4fv(pr.u.uPrm, mat.params || [0, 0, 0, 1]);
      const t = mat.textures || {};
      const bind = (unit, name, uname) => { if (!pr.u[uname]) return; gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, tex[name] || tex.white); gl.uniform1i(pr.u[uname], unit); };
      bind(0, t.baseColor, "uBase"); bind(1, t.custom || t.roughness, "uCustom"); bind(2, t.emissiveColor, "uAux"); bind(3, t.normal, "uNormal");
      if (pr.u.uHasNormal) gl.uniform1i(pr.u.uHasNormal, t.normal ? 1 : 0);
      if (mat.shader === "pbr") {
        gl.uniform1f(pr.u.uMetal, mat.metallic ?? 0); gl.uniform1f(pr.u.uRough, mat.roughness ?? 0.5);
        gl.uniform1i(pr.u.uHasTex, t.baseColor ? 1 : 0);
      }
    }
    function draw(part) {
      gl.bindVertexArray(part.vao);
      gl.drawElements(gl.TRIANGLES, part.count, gl.UNSIGNED_INT, 0);
    }

    gl.viewport(0, 0, W, H);
    gl.clearColor(0.0, 0.0, 0.0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.enable(gl.CULL_FACE); gl.cullFace(gl.BACK); gl.frontFace(gl.CCW);

    // 1. camera image
    if (ROOM) {
      gl.disable(gl.DEPTH_TEST); gl.depthMask(false);
      gl.disable(gl.CULL_FACE);
      setCommon(progs.room, { tint: [0.62, 0.56, 0.48] }, room);
      draw(room);
      gl.enable(gl.CULL_FACE);
      gl.depthMask(true); gl.enable(gl.DEPTH_TEST);
    }
    gl.depthFunc(gl.LEQUAL);

    const subtle = STYLE === "subtle";
    const styleHides = subtle ? new Set(["frame", "occluder", "veil"]) : new Set(["trim", "reveal", "occluder_exact", "veil_exact"]);
    const visible = (p) => {
      if (["footprint", "spill", "leaf", "shadow"].includes(p.name) || styleHides.has(p.name)) return false;
      if (p.name === "backcap" && MODE === "wall") return false;
      if (p.name === "skyfull" && MODE === "wall") return false;
      if (p.name === "sky" && MODE !== "wall" && dest.kind === "capture") return false;
      if (p.name === "rain" && Q.get("rain") === "0") return false;
      if (p.world && !B.worldVisible) return false;
      if (low && p.mat.startsWith("rain_") && ["rain_1", "rain_3", "rain_5"].includes(p.mat)) return false;
      return true;
    };
    const occName = subtle ? "occluder_exact" : "occluder";

    // 2. occluders (depth only)
    if (!NO_OCC && B.worldVisible) {
      gl.colorMask(false, false, false, false);
      gl.disable(gl.CULL_FACE);
      for (const p of parts) if (p.name === occName) { setCommon(progs.previewGhost, { params: [0, 0, 0, 0] }, p); draw(p); }
      const closeAmt = 1 - OPEN;
      if (closeAmt > 0.001) {
        const leaf = parts.find((p) => p.name === "leaf");
        const hw = subtle ? dims.openHalfWidth : dims.holeHalfWidth, y0 = subtle ? dims.openY0 : dims.holeY0, y1 = subtle ? dims.openY1 : dims.holeY1, z = dims.apertureLeafZ;
        const covered = hw * closeAmt;
        for (const sgn of [-1, 1]) {
          const xa = sgn < 0 ? -hw : hw - covered, xb = sgn < 0 ? -hw + covered : hw;
          const M = [xb - xa, 0, 0, 0, 0, y1 - y0, 0, 0, 0, 0, 1, 0, xa, y0, z, 1];
          setCommon(progs.previewGhost, { params: [0, 0, 0, 0] }, { model: mul(PA, M), world: false });
          draw(leaf);
        }
      }
      gl.enable(gl.CULL_FACE);
      gl.colorMask(true, true, true, true);
    }

    // 3. opaque
    const transparentShaders = new Set(["captureRain", "alleyRain", "alleySteam", "alleyDecal", "portalVeil", "portalSeam", "contactShadow", "floorSpill", "previewGhost"]);
    let drawn = 0;
    for (const p of parts) {
      if (!visible(p) || p.name === "occluder" || p.name === "occluder_exact") continue;
      const mat = manifest.materials[p.mat];
      if (!mat || transparentShaders.has(mat.shader) || mat.shader === "occlusion") continue;
      const pr = progs[mat.shader];
      if (!pr) continue;
      if (mat.cull === "none" || p.cullNone) gl.disable(gl.CULL_FACE); else gl.enable(gl.CULL_FACE);
      setCommon(pr, mat, p); draw(p); drawn++;
    }
    gl.enable(gl.CULL_FACE);

    // 4. transparents back to front
    gl.enable(gl.BLEND); gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.depthMask(false);
    const trans = parts.filter((p) => visible(p) && manifest.materials[p.mat] && transparentShaders.has(manifest.materials[p.mat].shader));
    const worldEye = (p) => xform(p.model, p.centroid);
    trans.sort((a, b) => Math.hypot(...sub(worldEye(b), EYE)) - Math.hypot(...sub(worldEye(a), EYE)));
    for (const p of trans) {
      const mat = JSON.parse(JSON.stringify(manifest.materials[p.mat]));
      if (p.name === "veil" || p.name === "veil_exact") { if (!B.worldVisible) continue; mat.params[0] = Q.has("veil") ? Number(Q.get("veil")) : B.veil; }
      if (p.name === "seam") {
        if (OPEN >= 0.999 || OPEN <= 0.0) continue;
        mat.params[0] = subtle ? 0.5 : 1.0;
        mat.params[1] = 0.5 * OPEN * (2 * (subtle ? dims.openHalfWidth : dims.holeHalfWidth)) / 1.0;
        if (subtle) mat.tint = [1.0, 0.9, 0.78];
      }
      if (mat.shader === "alleyRain" || mat.shader === "alleySteam" || mat.shader === "captureRain") gl.disable(gl.CULL_FACE); else gl.enable(gl.CULL_FACE);
      setCommon(progs[mat.shader], mat, p); draw(p); drawn++;
    }
    gl.depthMask(true); gl.disable(gl.BLEND);
    gl.finish();
    status(`eye ${EYE.map((x) => x.toFixed(2))} ${MODE}/${STYLE} t=${TIME} draws=${drawn} world=${B.worldVisible} veil=${B.veil.toFixed(2)} quality=${QUALITY}`);
    document.title = "READY";
  }
  main().catch((e) => { status("ERROR " + e.message); document.title = "ERROR"; console.error(e); });
})();
