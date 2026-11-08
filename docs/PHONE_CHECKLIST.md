# Checks that need your physical iPhone

Open diagnostics with a three-finger tap. Do the tests in a normally lit room with some visual
texture (not a blank white wall/floor), in a clear area.

| # | Do this | Expect / record |
|---|---|---|
| 1 | Launch → Start | camera view, one instruction line, no hitch; "Loading…" turns into "Start" within a few seconds |
| 2 | Scan the floor slowly | cyan preview within ~5-15 s; amber with a reason on a table/sofa/too close/too far |
| 3 | Tap, drag, twist, Open | doorway stays exactly where pinned; 1.9 s opening; no flash |
| 4 | Stand still 30 s | doorway does not swim or jitter; note any drift (cm) |
| 5 | Step ~1 m left and right | near walls/props slide relative to far ones; nothing outside the opening |
| 6 | Reach the phone through the opening, then turn it left/right/up/down | approach stays clear; camera enters the alley; no room leaking around the scene |
| 7 | Crouch / raise the phone | signs, cables, upper floors, sky appear |
| 8 | Walk around the side and behind | edge-on: nothing leaks; behind: plain doorway, real room through it |
| 9 | Look away 10 s, look back | doorway in the same place; "corrections" count in diagnostics |
| 10 | Home button / lock phone, return | "Paused", then content returns after stable tracking; no jump; "Place again" offered only if needed |
| 11 | Cover the camera / shake / point at a blank wall | aperture closes with a short message; restores when tracking is good |
| 12 | LiDAR: hold your hand / a chair between phone and doorway | it hides the doorway; the wall behind the doorway never erases the alley |
| 13 | Mute, Reposition, Close | all work; Close returns to start |
| 14 | Leave it open 10+ min | copy report: fps mean/p95, % over budget, memory start vs end, thermal, corrections |
| 15 | Switch tier High/Low in diagnostics | Low visibly cheaper; art direction intact |
| 16 | While inside, turn back toward the doorway | textured wall surrounds the frame; live room appears only through its opening |
| 17 | Pull the phone back through the opening | original outside portal view returns; doorway stays anchored |
| 18 | From outside, move the phone around the side or above the frame | this does not enter the alley |
| 19 | Slowly cross back and forth near the threshold | no opaque haze, blank-view flash, or rapid mode flicker; record any near-plane artefacts |
| 20 | Interrupt tracking near or inside the threshold, then recover | no false crossing inferred across the interruption; Close remains available |

## v1.2.2 Easy placement (do these first)

| # | Do this | Expect / record |
|---|---|---|
| 21 | Fresh install → Start → point at an ordinary plain wall 1-3 m away | glowing cyan doorway outline on the wall within a few seconds; chip says "Wall found" or "Wall estimated"; record seconds until CREATE PORTAL is enabled |
| 22 | Tap CREATE PORTAL | doorway appears immediately where the outline was, standing on the floor; "Portal placed on the wall" banner |
| 23 | Point at open space or a wall >4.5 m away | chip "No wall - standing doorway"; CREATE places a freestanding doorway ~2.2 m ahead, facing you |
| 24 | Stand ~0.4 m from a wall | amber outline, "Step back about a metre from the wall"; button disabled until you step back |
| 25 | Turn fully away from the placed portal | "Find Portal" button appears; its arrow points the right way; tapping gives a turn instruction |
| 26 | MOVE PORTAL, aim elsewhere, CREATE | old doorway gone, new one placed, no full rescan needed |
| 27 | RESTART SCAN before and after placing | fresh scan, preview returns within seconds |
| 28 | Diagnostics → turn Easy Mode off | old pin/drag/Open flow still works |

Please report: phone model, iOS build, fps mean / p95 / % over budget, memory at launch and after
10 min, thermal state at the end, max correction (cm), and anything that looked wrong. A photo or
screen recording helps a lot for tuning exposure and rain brightness.

