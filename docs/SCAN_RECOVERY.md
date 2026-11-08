# Scan recovery fix — v1.2.1 (build 4)

Phone testing showed a scanning screen stuck on “Look around where you placed
the doorway” with only a Close control. That text is emitted for ARKit's
relocalizing state. The app reused a paused session for a fresh placement and
always opted into relocalization, even without an anchored doorway; the scan
screen had no reset path.

Each Start, Reposition, or Restart scan now explicitly resets tracking and
removes stale AR anchors with no initial world map. Preview/pinned placement,
old occlusion meshes and cached placement input are cleared before scanning.
Restart scan is always available before placement. Returning from an
interruption before placement also starts a fresh scan. Recovery of an
already placed doorway remains enabled and never automatically resets it.

A scan stuck continuously relocalizing for three seconds gets one automatic
fresh start. Further recovery is manual to avoid a reset loop in difficult
conditions. The scan screen uses placement-appropriate text rather than
asking the user to find a nonexistent doorway. Pending renderer-warmup tasks
also check their anchor identity before cleanup, so an old task cannot remove
a newer scan's warmup anchor.

Validation: regression coverage verifies the unplaced recovery timeout,
one-restart budget, normal-state timer reset, preservation of placed doorways,
and no automatic resets for other limited tracking states. Native iPhone
recovery remains a physical-device check. The start card shows Version 1.2.1
so the installed candidate can be identified.

Device check: Start, place a wall portal, Close then Start again, Reposition,
and background/resume before and after placement. Before placement, verify
Restart scan returns to a fresh scan instead of waiting for the old room.
