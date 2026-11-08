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

## v1.3.0 realism and universal placement

| # | Do this | Expect / record |
|---|---|---|
| 29 | Start, aim at a wall 1-3 m away, CREATE PORTAL | a crosshair sits on the wall; the outline glides rather than jumps; the opening appears as a clean cut with a thin dark edge and a light reveal, and no cyan frame |
| 30 | Look through it from straight on and 1 m to each side | photographed walls, scanned AC units, bins and cabinets; dark contact shadows under the bins and vending machines; awning and eaves cast shade. Screenshot please |
| 31 | Look closely at the AC units | the fan grilles are see-through mesh (alpha cut-out), not solid black or white squares |
| 32 | Check texture orientation | shop signs, the 止まれ road marking and wall stains are the right way up (this tests the iOS 18 LowLevelMesh path) |
| 33 | Reposition, aim at the floor 1.5-3 m ahead, CREATE | chip "Floor - look down into the alley"; "Don't step onto it" banner; looking down shows the street ~7 m below with cables and signs between; **nothing pokes up into the room** (tests the shader clip) |
| 34 | Walk to the edge of the floor portal | "Watch your step" warning while over it or within ~35 cm |
| 35 | Reposition, aim at the ceiling, CREATE | chip "Ceiling - look up into the alley"; looking up shows the arch sign, wires and sky; no street or room-height objects hanging into the room |
| 36 | Aim at a sloped surface (ramp, propped board, sloped ceiling) | levelled portal with "Sloped surface" hint, or a standing doorway if too steep |
| 37 | Adjust → − / + and the rotate buttons | the opening grows and shrinks (50-160 %) and rotates in 15° steps; the alley does **not** scale or tilt; rotation is hidden for doorways standing on the floor |
| 38 | Diagnostics → "Classic doorway frame" on and off | swaps between the old frame and the cut edge on the placed portal |
| 39 | LiDAR on, floor portal placed, hand or chair over it | your hand hides the opening; the floor around the hole never erases it |
| 40 | Leave a wall portal and a floor portal open 10 min each | report fps mean / p95 / % over budget, memory and thermal (1.3 has 15× the geometry and 2× the texture memory of 1.2.2) |

Please report: phone model, iOS build, fps mean / p95 / % over budget, memory at launch and after
10 min, thermal state at the end, max correction (cm), and anything that looked wrong. A photo or
screen recording helps a lot for tuning exposure and rain brightness.

