# Rendering and anchoring

## Coordinate space

Everything is authored in **portal space**: origin on the floor at the centre of the opening,
+y up, +z toward the viewer (room side), the destination toward −z. The doorway rig is
parented to the ARKit anchor with identity transforms, so portal space equals anchor space.
Every alley mesh is baked in portal space too (no per-object transforms). The shaders recover
portal-space positions with `model_to_world()`, which keeps them correct if ARKit refines the
anchor.

Key depths (from `manifest.json → dimensions`, enforced by build-time and unit tests):

| z (m) | what |
|---|---|
| +0.12 … −0.12 | doorway frame (0.24 m deep); clear opening 0.96 × 2.02 m, outer 1.30 × 2.22 m |
| −0.1210 | opening seam (light lines) |
| −0.1225 | animated aperture leaves (depth-only) |
| −0.1235 | veil (haze), hidden by closed leaves |
| −0.125 | occluder wall, 440 × 166 m, with a hole slightly larger than the opening |
| < −0.129 | the whole destination |

**Invariant:** every frame vertex is in front of −0.125 and every destination vertex is behind
it. `build.py` refuses to export otherwise, and `ShippedAssetTests` re-checks the shipped
files. The asset build caught two real violations this way (feet and an AC unit).

## Why a depth-only occluder rather than a portal component

RealityKit's `PortalComponent`/`WorldComponent` were designed on visionOS. Their iOS
availability and their clipping, lighting and near-plane behaviour couldn't be verified here,
and the brief asked not to assume a library feature solves everything. The technique used
instead is plain and checkable:

1. The camera image is the background.
2. `OcclusionMaterial` geometry writes depth only. A large wall at z = −0.125 with a hole the
   size of the aperture hides any virtual content behind it, except where you look through the
   hole. The camera image stays visible.
3. Every ray from the room to the alley must cross that plane, so the alley appears only through
   the hole, with correct perspective and depth. Parallax is real: it is 3D geometry rendered
   from the tracked camera.
4. The hole is 1.5–3.5 cm larger than anything a ray can reach past the frame, and its edge sits
   behind the frame's opaque back face. The mask edge is therefore never visible: no halos, no
   z-fighting, and the frame naturally hides parts of the view.

### Behaviour at the edges (deliberate)

- **Close**: inside the doorway footprint, the view clears fully at 55 cm from the aperture
  plane and is fully veiled at 30 cm (`BoundaryPolicy`). A short "step back" message appears.
  The camera's near plane can never reach the occluder.
- **Side / edge-on**: no special handling is needed; the occluder plane already seals the view.
- **Behind** the aperture plane (with hysteresis 2/8 cm): the occluder can't work from behind, so
  the destination, occluder, leaves and veil are disabled. The doorway reads as a finished object
  from the back, with rear plates and bolts.
- **Walk-through**: out of scope by design.

### Opening animation (1.9 s)

The frame fades in, then the cyan channel powers up with one travelling highlight. A thin seam
appears in the aperture, the depth-only leaves part from the centre while the seam follows their
edges, and the destination haze clears. With the leaves closed you see the real room through the
doorway, not a haze.

## Shading the destination

All alley materials are `CustomMaterial` with the **unlit** model. RealityKit renders only
`set_emissive_color()` for that model, so the shader is the whole look. `AlleyShadingCore.h`
is written in a neutral C subset and compiled both as Metal (app) and as GLSL (preview), so the
preview shows the same maths:

- 16 authored point lights (`AlleyLights.h`, generated): shop windows, signs, lanterns, a street
  lamp, and a car sweep every 17 s. The low tier uses the first 10. This is baked-style analytic
  lighting: no real-time RealityKit lights and no shadows maps.
- Wet ground: puddle map, rain ripples, and anisotropic reflection streaks of every light (the
  coloured vertical streaks). There are no screen-space or full-scene reflections.
- Window interiors with parallax, glass fresnel and reflection.
- Height-weighted fog lit by nearby lights; neon flicker and an LED ticker.
- Rain: 6 (high) or 3 (low) transparent streak layers lit by nearby lights, plus one steam plume.
- A soft-shoulder tonemap in the shader.

## Integration with the room

- The doorway uses `PhysicallyBasedMaterial`, lit by ARKit `environmentTexturing = .automatic`,
  so its brushed metal and bevels pick up your room's light and reflections.
- Contact shadow: a soft alpha decal under the threshold and feet. RealityKit's grounding shadows
  are disabled.
- Optional, off by default: a faint simulated light spill on the floor in front of the opening.
  It is a decal, not lighting.
- **LiDAR** (capability-checked): RealityKit scene occlusion stays **off**, because it would let
  the real wall behind the doorway erase the alley. Instead, `SceneOcclusion` turns ARKit mesh
  anchors into occluders after filtering in portal space. It keeps only triangles on the room
  side of the aperture, drops floor-level triangles and anything inside the doorway's own volume,
  and rebuilds at most one anchor every 0.25 s. People occlusion is disabled for the same reason.

## Anchoring

1. Before confirmation, the preview follows `ARView.raycast(…, .existingPlaneGeometry, .horizontal)`
   at the screen centre. That is display-smoothed, but it is UI.
2. Placement must be credible (`PlacementRules`): tracking normal; plane classified floor (or
   unclassified but the lowest horizontal plane); camera 0.6–2.4 m above it; 1–4.5 m away; enough
   plane extent; on LiDAR, no reconstructed points inside the doorway volume.
3. Tap pins it. Drag moves it along the pinned floor plane, and twist rotates it. It always stays
   upright, gravity-aligned, and faces you initially.
4. **Open** adds one `ARAnchor` and parents the rig to `AnchorEntity(anchor:)`. From then on the
   app never writes the doorway's transform. ARKit's own refinements of that anchor are counted
   and shown as "corrections" in diagnostics, separately from app positioning, which is
   "app writes after lock" and always 0. The camera pose is used as ARKit reports it, with no
   smoothing or delay.
5. Tracking (`TrackingPolicy`):
   - Hiccups under 0.35 s are ignored.
   - Sustained limited tracking closes the aperture but keeps the frame.
   - Relocalising or an interruption hides everything until tracking has been normal for 0.6 s.
   - After 8 s it offers "Place again" alongside "Keep waiting".
   - It never moves the doorway silently.
   - Low light (<120 lux) gets its own message.
6. Session reruns (toggling LiDAR) don't reset tracking or remove anchors. Close pauses the
   session; Reposition removes the anchor.
