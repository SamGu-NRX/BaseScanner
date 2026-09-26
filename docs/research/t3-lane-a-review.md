# Lane A review: what fails on a real house

This note reviews [docs/01 section A](../01-feature-map.md#a-capture-app-swift-arkitrealitykit) and [docs/02 "Lane A"](../02-implementation-plan.md#lane-a-capture-app) against the criteria Base shared. No app code was reviewed; each item is a plan gap, not an observed failure. The biggest gap is that capture ends when both wall ends are walked, not when the rules have their evidence.

Items 1 to 5 are the highest-priority planning gaps. Items 6 to 12 cover additional reliability risks and acceptance gaps; their effect on a demo has not been tested. Items 1 and 12 challenge the LiDAR demo scope in [docs/00](../00-overview.md) itself.

1. **Ordinary iPhones can't get an automatic pass.** "Risks and fallbacks" makes passage width and headroom UNSURE without LiDAR, and Lane C passes a spot only if every check passes. A borrowed Pro fixes only the demo.
   **Change.** Make the non-LiDAR walk the acceptance case. Photograph the facing obstruction and overhead space, and ask for a measurement only where `facing_gap_ft` or `headroom_ft` decides the spot; otherwise send complete evidence to manual review and say so before the walk.

2. **Reaching both ends doesn't prove the deciding areas were photographed.** A2 says end taps mean "nothing goes unphotographed", but step 3 saves frames by motion, not by what the camera saw. Ground behind an AC unit can go unseen.
   **Change.** Track what frames show for each candidate spot (ground, wall, route, facing and overhead space), one instruction at a time: "Show the ground behind the air conditioner." One well-supported spot is enough.

3. **Photo checks aren't consistently immediate, and the slots miss views.** Step 5 runs photo checks in the P0 flow, but A7 lists them as P1. A6 asks for a disconnect close-up, yet `stills` has no disconnect slot and one panel only.
   **Change.** Make the checks P0 and replace `stills` with records of equipment, view purpose, image and check result. Show "Retake now" apart from "Saved; a specialist will review". Confirm the required evidence checklist with Base before freezing this list.

4. **The tap fallback doesn't capture extents.** A5 lists six buttons, but objects need `span_ft`, `bottom_ft`, `top_ft` and ground polygons, and windows (B3) and pools (B7) have no P0 tap flow.
   **Change.** Specify per type: two edges plus heights for openings, a ground outline for AC units and gas meters, a traced driveway edge. Add "not visible" and "not sure", and store each tap's plus or minus 0.3 ft error and source frame.

5. **"Open panel" has no safety boundary.** A novice may read A6 as "unscrew the cover".
   **Change.** Say "Open only the normal hinged door if it is safe. Don't remove screws or covers, touch wiring, or switch breakers." Add "Can't safely open" and "Equipment looks damaged" exits to review.

6. **The meter-to-panel session has no tracking-loss plan.** A8 claims one session answers "same wall?" "exactly", and relocalizing is P2. Walking indoors can break tracking, which `scene.json` doesn't record.
   **Change.** Record session ID and tracking state per frame and tap, and pause measured taps with "Return to the meter". If recovery fails, mark the meter-to-panel relationship unknown. Confirm `ARCamera.trackingState` and interruption callbacks in Apple's docs first.

7. **The first tap assumes the raycast hits a wall.** Step 1 raycasts to a vertical surface, and step 2 doesn't say which point is the wall end. A projecting meter can, blank siding, shrubs or a pole mount can misplace the zero point.
   **Change.** Confirm the hit before accepting a tap, name the point, allow undo, and add "Move back and show more wall" and "Meter isn't on this wall". Specify how capture measures ground height per segment.

8. **Upload has no durable retry.** Step 7 uses a foreground `URLSession` while AR keeps running, so a weak signal or screen lock can force a second walk. An illustrative 100 MB at 5 Mb/s takes about 160 s; the real size is unmeasured.
   **Change.** Save files to disk first, with a stable capture ID, safe retries and a server acknowledgement, and keep the D2 site plan usable without live AR. App Clips can't use background upload ([capture surfaces](t3-capture-surfaces.md)).

9. **Image orientation instructions conflict.** docs/01 and docs/02 save keyframes unrotated; [docs/03](../03-stack-research.md) applies EXIF rotation before inference and casting, with no pixel mapping. An unmapped rotated box lands in the wrong place.
   **Change.** Pick one pixel frame and store any transform to an upright copy. Extend the hour-2 round-trip test to portrait, both landscapes, resized inputs and `captureHighResolutionFrame` stills, using off-center points.

10. **One compass reading doesn't align AR with the map.** Step 8 stores only heading and accuracy, while docs/03 limits yaw to 20° either side of it and snaps walls to 90°. Without a camera pose, the search can miss the alignment. B8 is P2; settle this with lane B.
    **Change.** Store the heading's timestamp and camera pose, and treat accuracy as uncertainty, not a search bound. When registration is ambiguous, ask the homeowner to tap the street side on a sketch.

11. **Requiring both ends is too rigid.** A2 has no exit for a locked gate or unsafe path. The completion rule should depend on the placement decision being made.
    **Change.** Check the nearest spots first; walk further only when needed. Call the result "a suitable spot" unless the rest of the wall can't beat it, and add "I can't safely reach this area". Confirm the evidence required for each placement outcome with Base before defining when endpoint capture is mandatory.

12. **Nothing tests whether a novice finishes in one try.** The first full run is at hours 10 to 14, and D3 measures distance accuracy, not completion. If the flow ends back at the meter, a wall L ft left and R ft right costs 2L + 2R ft of walking.
    **Change.** Run a novice, non-LiDAR walk early with glare, a closed gate, an indoor panel and a network drop. Record time, distance, taps and retakes; have a second person list missing deciding views. Pass only with zero later requests for evidence the homeowner could safely reach.
