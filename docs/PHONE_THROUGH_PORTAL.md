# Phone-through portal (v1.1, build 2)

The camera can now cross the aperture and turn around inside the alley. Pull
the phone back through the same opening to return. Going around a jamb, above
the lintel, or starting behind the doorway does not count as entry.

The anchored world and tracked camera are never moved for this transition.
Crossings use the intersection of consecutive reliable camera samples with
the aperture plane, within the clear opening. A 2 cm hysteresis band keeps a
stable side while rendering the eligible physical side at the threshold.
Tracking interruptions discard the crossing segment, and large pose jumps
cannot trigger entry. The previous 30–55 cm approach veil is removed.

Inside rendering disables the front-facing aperture mask and room-side LiDAR
occluders. A full sky enclosure fills directions the original front-view sky
did not cover. A textured return wall surrounds the frame. A depth-only
rectangle behind the frame reveals the real camera image through its opening.
The original destination meshes and textures remain in use. This is a first
inside view of the existing alley, not a newly scanned or live destination.

The existing AR session continues tracking the physical room. Close, tracking
recovery, repositioning, and the floor-placement fixes are preserved.

Validation: automated tests cover entering/exiting, aperture intersection,
side/above/below rejection, hysteresis, tracking gaps and pose discontinuities.
CI compiles the Swift/Metal app and runs those tests. The authoring environment
has no physical iPhone, so inside rendering, return-window compositing,
near-plane behavior, and performance remain subject to phone testing. See
PHONE_CHECKLIST.md, especially rows 16–20. The older desktop contact sheet does
not validate this feature.
