# Easy placement - v1.2.2 (build 5)

Goal: open the app, point at an ordinary wall, tap **CREATE PORTAL**, see a doorway.
No walking around the house and no AR troubleshooting.

## Why the portal could be impossible to create or find in v1.2.1

| Cause | Effect |
|---|---|
| Aiming only accepted an ARKit **detected vertical plane** under the screen centre (`.existingPlaneGeometry`, `.vertical`). There was no fallback. | On plain, evenly painted walls (very common) ARKit may take a long time to detect a plane, or never do so. No preview appeared and the instruction stayed on "Point at a wall…". |
| Placement was a hidden two-step: tap the camera view to pin, then press Open portal. | Nothing on screen said to tap the camera image. |
| The preview was eight 9 mm corner ticks. | Easy to miss even when placement was possible. |
| Without an ARKit-classified floor, the opening was centred on the aim point. | Aiming at eye level gave a door floating about 0.4 m above the floor, its top often outside the view. |
| A wall could be accepted from 0.45 m. | The camera ended up about 20 cm from the frame, which overfilled the screen. |
| No way back after turning away. | "It disappeared." |

## What changed

**Easy Mode (default).** The live preview always shows where the portal will appear. The app
picks the best method every frame:

1. **Wall found**: a detected vertical plane 0.7–4.5 m away with useful extent. The doorway is
   mounted flush and aligned with the wall.
2. **Wall estimated**: ARKit's estimated-plane raycast. It uses feature points, and LiDAR depth
   on Pro phones, and usually answers within a second on a plain wall. Same wall mounting.
3. **No wall – standing doorway**: a freestanding doorway on the floor 2.2 m straight ahead,
   facing you. This is the clearly labelled manual fallback. It looks through to the same alley
   but is not attached to a wall. The hint says "Point at a wall to mount it there instead".

The bottom of the doorway goes on the best floor estimate available: a classified floor, then
the lowest plane, then about 1.4 m below the phone.

**CREATE PORTAL** is enabled whenever tracking is normal and the pose is safe. One tap anchors
the doorway immediately, plays the opening, and shows **"Portal placed on the wall"** or
**"Portal placed - standing doorway (no wall found)"**.

**Safety rules for every proposal** (`PlacementSafety`):
- in front of the camera, within 40° of where it points;
- the camera on the viewing side and at least 35 cm from the frame;
- at most 6 m away;
- upright, at real scale, not mirrored;
- re-checked at the moment of the tap.

Too close to a wall (under 0.7 m), it says "Step back about a metre from the wall" instead of
spawning the doorway inside the wall.

**Controls after placement:**
- **MOVE PORTAL** returns to the live preview in the same tracked session, so walls already
  found are kept and the preview is instant.
- **RESTART SCAN** does a full tracking reset (the v1.2.1 behaviour).
- **Find Portal** appears when the doorway is off-screen. Its arrow points toward it, and
  tapping it gives "Turn left about 90° (3 m away)" style guidance.
- Look inside, Mute and Close are unchanged.

**Advanced controls** (tap to pin, drag on the wall, Open portal) are still available. Turn off
Easy Mode in the hidden diagnostics panel (three-finger tap).

Unchanged: the alley, wall-opening rendering, anchoring rules (one `ARAnchor`, never moved by
the app), tracking recovery, Look inside, perspective and peeking.

## Tests added (PortalCore, run in CI)

`EasyPlacementTests`:
- wall preferred, then estimate, then standing;
- tiny planes and non-vertical surfaces rejected;
- the user is never stuck while tracking works;
- far walls fall back with a hint; walls that are too close give "step back";
- no tracking and looking straight down are not ready;
- floor estimates; the eye-level floating-door regression;
- a 432-case sweep showing every ready proposal passes the visibility rules;
- each safety rejection;
- Find Portal directions;
- the CREATE → opening, Move → preview → create and tracking-loss recovery flows.

## Still needs a physical iPhone

- How quickly the estimated-plane raycast answers on your walls, and how stable a wall-mounted
  doorway is when only estimated.
- Whether the preview glow reads well in a bright and in a dim room.
- Find Portal arrow direction in portrait. It uses screen projection, which should be
  orientation-safe, but that has not been observed on a device.
- The standing fallback on carpet or rugs, where the floor estimate can be a few cm off.
