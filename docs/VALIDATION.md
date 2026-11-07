# Validation record

Nothing below is a claim about the iPhone app running. **The Swift/Metal code has not been
compiled** (the authoring environment was Linux without Xcode), and no device test was performed.

## Done here (actually performed)

| Check | Method | Result |
|---|---|---|
| Asset build | `python3 Tools/assetgen/build.py` | 40 textures, 3 mesh packs (frame 1,892 tris, alley 24,710 tris), 5 WAVs, 11.3 MiB total |
| Winding/normals | `MeshBuilder.check()` at export | every part 100 % consistent; degenerate triangles stripped |
| Portal invariant | build-time assert | frame min z −0.1243 > occluder −0.125 > alley max z −0.1300 |
| Depth bands | Python mirror of `ShippedAssetTests.testRequiredDepthBands` | 2,567 tris at 1–3 m, 8,311 at 4–12 m, 10,230 at 12–30 m |
| Dimension ordering | Python mirror of `PortalDimensions.isConsistent` | true (after fixing the seam depth) |
| Shading core compiles as GLSL ES 3.0 | WebGL2 preview in headless Chrome (SwiftShader) | compiles and renders |
| Rendering viewpoints | `Tools/preview/render_views.sh` → `docs/validation/*.png` | 18 views, see below |
| Policy test expectations | traced by hand against the implementation | consistent; not executed |

### Rendering views (WebGL preview, same meshes/textures/shading core, AR-style compositing)

`01` head-on · `02`/`03` 1 m left/right (opposite near walls revealed) · `04` high · `05` crouch
(arch, blade signs, buildings and sky revealed) · `06` oblique · `07` close 0.7 m (much wider
view) · `08` edge-on side (no leakage) · `09` rear (destination disabled; finished rear) · `10`
0.4 m · `11` 3.5 m · `12`/`17` aperture leaves 50 %/20 % (seam on leaf edges, room visible
through closed parts) · `13` low tier · `14` debug without occluder (shows what the mask hides) ·
`15` 0.30 m (veiled) · `16` car sweep moment · `18` far-left corner.
Contact sheet: `docs/validation/_contact_sheet.jpg`.

Defects found and fixed through these checks: sky dome extending to the room side (visible
edge-on), feet and rear bolts crossing the occluder plane, an AC unit overhanging the doorway
plane, the seam quad sitting inside the frame, a stretched lantern glyph, overly broad
reflections, and the cropped arch sign.

**What the preview cannot show:** RealityKit's tone mapping and transparency blending, the
ARKit environment lighting on the frame, real camera exposure/noise, tracking, performance.

## Done by CI (on every push; results not yet seen)

1. `swift test --package-path PortalCore` (8 suites: geometry/transforms incl. mirroring and
   parallax direction, placement rules, tracking policy, boundary policy, state machine,
   opening timeline, frame stats, shipped assets incl. the occluder invariant).
2. `xcodegen generate` → `xcodebuild` Release for `generic/platform=iOS`, unsigned. This compiles
   all Swift and Metal for the first time. The workflow then checks `default.metallib` and the
   asset folder are in the bundle and uploads `PortalAlley-unsigned.ipa`.

## Needs your phone

See [PHONE_CHECKLIST.md](PHONE_CHECKLIST.md). Please paste the developer panel's "Copy report +
soak log" text back to me after the 10-minute run.
