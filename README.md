# PortalAlley

A native iPhone AR portal: place a full-size freestanding doorway on your floor and look
through it into a rainy, neon-lit night alley ("ほたる横丁", fictional). ARKit 6-DoF world
tracking, RealityKit rendering, custom Metal surface shaders, bundled assets, no network.

**Status: source-complete, not yet compiled.** No Mac or Xcode was available while this was
written, so the Swift and Metal code has never been compiled or run on a device. The first
compile happens in the included GitHub Actions workflow. See [docs/VALIDATION.md](docs/VALIDATION.md)
for exactly what was and was not verified.

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

## Using it

Start, then move the phone slowly over the floor. Aim at a clear spot 1-4.5 m away. The preview
shows cyan when the spot is credible, amber with a reason otherwise. **Tap** to pin it, **drag**
to move, **twist** with two fingers to turn, then **Open portal**. After that the doorway is
locked to a world anchor. Buttons: Reposition, Mute, Close. Diagnostics: three-finger tap, or
long-press the instruction text.

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
