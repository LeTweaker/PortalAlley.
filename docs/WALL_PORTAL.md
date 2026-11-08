# Wall portal v1.2 (build 3)

Aim at a detected vertical wall. Tap to pin the aperture, drag it vertically
or horizontally on that wall, then Open portal. The wall normal fixes its
orientation; twisting cannot rotate it away from the wall. A known floor is
used to set the bottom height when available; no floor scan is required.

The back aperture is flush to the wall. The confirmed AR anchor is not changed
by aiming rays or drag gestures. Real-room mesh occlusion still excludes the
wall behind the opening. This does not guarantee zero ARKit tracking drift.

A solid wall cannot be crossed physically. Look inside translates only the
destination rendering to the equivalent of a camera 0.8 m inside the alley.
Phone rotation and position changes are preserved one-to-one. The physical
doorway anchor stays put, and Back to room restores the normal wall view.
The return frame is rendered with the offset destination while the physical
frame is hidden in inside mode, avoiding overlapping doorways.

This remains an authored Tokyo-inspired scene, not a recording or scan of an
identified Tokyo street. It now imports photographed CC0 asphalt, concrete,
and worn plaster with roughness/AO/normal maps, uses microfacet highlights,
reduces opaque rain sheets, and varies pavement roughness and puddle sheen.
The build fails if the photographic resources cannot be downloaded/validated;
it never silently ships the older procedural textures as the new visual pass.

Validation: wall alignment, missing-floor placement, plane-constrained drag,
inside-view translation and return logic have automated coverage. The build
also checks imported checksums and runs the asset parser tests on the imported
bundle. Native visual quality, wall tracking stability, inside-view behavior,
and performance require a physical iPhone test; no such result is claimed here.

Device check: place on a wall, pan sideways then hold still, enter Look inside,
turn left/right/up/back, return, close, and reposition. Record any drift or
masking holes. Keep the earlier phone-tested build available as a rollback.
