# The capture packet

The capture packet is how a scan leaves the phone. It is specified by the server team's capture
packet spec, `formatVersion` 0.4, together with its intake API. The spec is
`docs/capture-packet-spec.md` in the private repository `huntertcarver/house-scanning-server`;
the API is its Appendix D (`/v1/captures`, `/files`, `/files:commit`, `/finalize`). That spec is
the one contract; this folder does not define a format of its own.

This folder holds the app side's proposals for the next revision (0.5): what the app records
that 0.4 has no field for, and three arrival checks for the server's validator
([validator-checks.md](validator-checks.md)). Packet 1.1, which this folder used to define, is
retired; it is still readable at `t3/packet` commit `d5439cf`.

## Proposals for 0.5

Each item is something the app knows at capture time and the server would otherwise have to
guess. All are additive, so 0.4 readers keep working.

1. **The meter anchor's orientation.** 0.4 records the meter tap's point, not the wall it sits
   on. Every placement distance is measured along that wall from the meter (C1's `s = 0`), and
   the app knows the wall at the tap: the vertical plane its raycast hit. Proposal: on the
   `meter` tap, a `meterAnchor` with `transform` (anchor to world in the tap's epoch: origin at
   the meter, +y up, +z the wall's outward normal, +x along the wall to the right seen from
   outside) and `normalSource`: `single_raycast` (one plane hit at the tap), `fitted` (fitted
   across the walk), `mesh` or `estimated`. The source matters: the signals lab (#59,
   `experiments/edge-geometry`) measured the yaw of the app's single-raycast plane at 2.2° median
   and 6.7° p90, which at 10 ft along the wall moves a point about 1 ft.
2. **The ground's height at the meter.** 0.4 notes that world y = 0 is the phone's height at
   session start, not the ground. The app measures the ground where it can: the horizontal plane
   below the meter. Proposal: `meterAnchor.groundY` (world meters) with `groundSource`
   (`plane`, `mesh`, `assumed`), so headroom and "ground under the battery" start from a
   measurement when there is one.
3. **What a marked end or feature is.** 0.4's tap labels name the point, not the answers the
   homeowner gave about it:
   - whether a wall end is a real end (something blocks it) or unexplored (it turns a corner,
     or no answer), which decides whether the server may reject for want of space;
   - whether a window opens, which decides whether the opening clearance applies;
   - which corner taps belong to the same door or window.

   Proposal: `taps[].attrs` with `endKind` (`limit`, `unexplored`) and `operable`, and
   `taps[].group` for taps that outline one object.
4. **The guidance log.** Every request the homeowner was shown (walk, tilt to the ground, mark
   an end, close-up, a gap the phone or the server asked for), when, and its outcome: `met`,
   `skipped`, `cannot_reach`, `superseded` or `unresolved`. Today "I can't get there" never
   reaches the server, so the server can ask for the same unreachable view again. Proposal:
   `guidance[]` with `id`, `kind`, `origin` (`phone`, `server`), `message`, optional `band` and
   `span`, `tShown`, `tResolved` and `outcome`.
5. **Depth between keyframes** (from S6's live map, draft PR #21). Keyframes are kept about every
   0.5 m, but the phone fuses depth at about 10 Hz to decide what was seen. With keyframe depth
   alone the server cannot rebuild that decision. Proposal: optional `depthFrames[]` with `t`,
   `epoch`, pose, intrinsics of the depth map's own grid, and the same depth and confidence files
   as a keyframe. At 256 × 192, one frame with confidence is about 246 KB, so a few hertz rather
   than ten.
6. **Estimated depth with its uncertainty** (S6). A phone without LiDAR can infer metric depth
   from the image, but used without its uncertainty it creates surfaces that are not there.
   Proposal: a depth `source` of `estimated`, which requires a `sigma` file (float32 meters, one
   standard deviation per depth pixel, the depth's layout).
7. **The frame of a plane's boundary.** 0.4 lists `planes[].boundary` without saying its frame.
   ARKit's `boundaryVertices` are relative to the anchor transform, not to `planeExtent`'s centre
   and `rotationOnYAxis`, and packet 1.1 found that mixing the two is an easy mistake. Proposal:
   state that `boundary` is `[x, z]` in the anchor's frame, and have the validator check it lies
   within `planeExtent` once the centre and rotation are applied.
8. **Photos that frame one span.** An along-wall edge is 0.9 in p90 when seen within 15° of
   face-on and 24 in beyond 45° (#59, `experiments/edge-geometry`), so a distance measured inside
   one face-on photo is far better than one chained across the walk. Proposal: a still or
   keyframe purpose `span` that names the marks the photo frames.
9. **Scale references in view.** One reference near the meter is not enough: ARKit's scale drifts
   1.8% (robust SD) within a walk (#59, `experiments/drift-anatomy`), so a reference helps where
   it appears. Proposal: `references[]` with `kind` (door, brick course, and hand-held ones such
   as an ID card or a Letter sheet), nominal size, and its corners in each photo that shows it.
   Hand-held references ask the homeowner to hold something; #59 rates them worth a device test
   (`experiments/sensor-budget`), and whether the flow may ask is Sam's and Hunter's call.
10. **The meter anchor's pose over time.** ARKit re-estimates an anchor as tracking corrects, so
    the anchor pose at tap time goes stale. Proposal: an optional stream of the meter anchor's
    world pose at each ARKit update, so the server can see how far the meter frame moved. There
    is no measurement of that movement yet.
11. **Distances from a second phone (low priority).** When a second phone with UWB is present,
    an optional stream of phone-to-phone distances. #59 (`experiments/drift-anatomy`) finds it
    cuts the p90 error at 20 ft from 10.4 in to 7.7 in at 10 cm ranging noise, and to 4.9 in at
    5 cm.

Already in 0.4, so not proposed: the kind and distance of each tap's hit, a keyframe for every
tap, and feature-point identifiers. Packet 1.1 also had a fixed sharpness score, distance walked
and a location-consent flag; 0.4's exposure and EXIF, `arkitPoses` and `locationAuthorization`
cover them.
