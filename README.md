# PortalAlley

A native iPhone AR portal: open a window in a wall, the floor or the ceiling and look through it
into another place. Since 1.4 the default destination is a real photogrammetry capture of an
alley (London, used as the proof scene until a Tokyo capture is fetched), with a Cinematic mode
showing genuine licensed Tokyo rain footage. The v1.3 illustrated Tokyo alley remains as a fallback. ARKit 6-DoF world
tracking, RealityKit rendering, custom Metal surface shaders, bundled assets, no network.

**Status (1.4.0):** see [docs/V1_4.md](docs/V1_4.md) for the architecture, sources and limitations.

**Status (1.3.0):**
- Compiles and packages on GitHub Actions (macOS runner) into an unsigned IPA.
- 112 PortalCore unit tests pass on CI.
- Not yet verified on a physical iPhone by the author. The checks to run are in
  [docs/PHONE_CHECKLIST.md](docs/PHONE_CHECKLIST.md), and exactly what was and was not verified is
  in [docs/V1_3.md](docs/V1_3.md#5-validation-actually-performed).

## Your setup (as confirmed)

| | |
|---|---|
| Phone | iPhone 15/16/17 Pro (LiDAR) on iOS 27.2 |
| Computer | Windows 11, no Mac assumed |
| Build | GitHub Actions macOS runner (free) produces an unsigned `.ipa` |
| Install | Sideloadly on Windows, signed with your own free Apple ID (re-sign every 7 days) |

Install guide: **[docs/INSTALL_WINDOWS.md](docs/INSTALL_WINDOWS.md)**. If you do get a Mac:
`brew install xcodegen && xcodegen generate`, open `PortalAlley.xcodeproj`, choose your team, Run.

## Requirements

- iPhone with A12 or newer and iOS 17.0+ (ARKit world tracking, RealityKit custom materials).
  On iOS 17 the doorway appears/disappears without its fade (`OpacityComponent` is iOS 18+). Performance baseline and "high" tier: **iPhone 15 Pro (A17 Pro)**.
- LiDAR is optional. On LiDAR models it enables: room-side real-world occlusion and the
  "clear area" placement check. Everything else works without it.
- Camera permission. Sound respects the silent switch.

## What's new in 1.4.0

A **Spatial / Cinematic** picker:
- **Spatial** is a 3D photogrammetry capture with real parallax.
- **Cinematic** is real Tokyo footage on a screen set behind the opening, and it says so when
  you get too close.

The 1.3 alley is still available in diagnostics. Renders, sources and the honest limitations are
in **[docs/V1_4.md](docs/V1_4.md)**.

## What's new in 1.3.0

Photographed CC0 surfaces and scanned props, plus baked contact shadows. Portals can open in
walls, floors and ceilings; the opening is a subtle cut, and it can be resized and rotated.
Before/after comparison, budgets, limitations and the phone checks: **[docs/V1_3.md](docs/V1_3.md)**.

## Using it

Start, then point the camera at a wall, the floor or the ceiling. A glowing outline and a small
crosshair show where the portal will appear. They are cyan when ready and amber with a short
reason when not. Tap **CREATE PORTAL**. If no surface can be used, the outline becomes a standing
doorway 2.2 m ahead, clearly labelled.

After placing:
- **Reposition**
- **Adjust**: resize and rotate the opening
- **Close Portal**
- **Restart Scan**
- **Find Portal**, when it's off-screen
- Look inside (wall portals)
- Mute Advanced pin, drag and Open placement: diagnostics (three-finger
tap) → Easy Mode off. Details: [docs/EASY_PLACEMENT.md](docs/EASY_PLACEMENT.md).

## Repository map

```
App/Sources/            SwiftUI app, AR controller, RealityKit rig, LiDAR occlusion, audio, diagnostics
App/Shaders/            AlleyShaders.metal + AlleyShadingCore.h (shared with the preview) + AlleyLights.h (generated)
App/Resources/Portal/   manifest.json, meshes (.pmsh), textures (.png), audio (.wav)   <- generated, committed
PortalCore/             platform-independent logic + unit tests (swift test)
Tools/assetgen/         Python generator for every asset (python3 Tools/assetgen/build.py)
Tools/preview/          WebGL validation preview (same meshes, textures and shading core)
docs/                   install, rendering/anchoring, validation, phone checklist, licenses
project.yml             XcodeGen project spec
.github/workflows/      CI: unit tests + unsigned IPA
```

## Known limitations

- **Never compiled.** API names were checked against Apple documentation where it could be
  reached, but expect possibly a few compile fixes on the first CI run. Send me the `build-log`
  artifact if it fails.
- **Visuals were judged only in a WebGL stand-in.** RealityKit's own tone mapping, the
  transparency blending mode for unlit custom materials, and how ARKit environment lighting
  looks on the frame may differ from the preview. Exposure and rain brightness may need
  one tuning pass on the phone (the diagnostics panel shows what is happening).
- **Signing.** Free Apple ID signing expires after 7 days and allows 3 sideloaded apps.
- **Performance is unmeasured.** 60 fps on iPhone 15 Pro is the target, not a result. The
  diagnostics panel measures it, and a "low" tier exists. Textures are PNG decoded to RGBA8
  (about 95 MB of GPU memory with mipmaps on high, the 2048² sign atlas being the largest, and about 24 MB on low); ASTC compression is not used.
- **Look-through only.** Walking through is out of scope. The view veils at 30 cm from the
  aperture, and the destination switches off behind the doorway.
- **Tracking** is ARKit's: drift, relocalisation and textureless or dark rooms behave as ARKit
  does. The app hides the view rather than moving the doorway, and asks before re-placing.
- **No persistence** across launches (out of scope).
- The floor-light spill is simulated and **off by default** (developer panel). Virtual lights do
  not light your real room.
