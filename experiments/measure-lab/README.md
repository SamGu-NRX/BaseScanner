# Measure lab

## Question

Can an ordinary iPhone without LiDAR measure what the battery placement checks need, outdoors, on the first try? The checks need a straight wall's line, points on that wall (meter, door and window edges), a facing gap to a fence or wall, and an overhead height. The method comes from the no-LiDAR capture research note (`docs/research/t3-no-lidar-capture.md`, in review). This folder is the rig that tests it, not the product capture app in `ios/`.

The rig also records every session in a documented format, so the server, a depth model or a later reconstruction pipeline can replay the same frames and taps.

## What the app does

The app runs ARKit world tracking with `worldAlignment = .gravity` (y is up) and horizontal and vertical plane detection. It never turns on scene reconstruction. On a LiDAR phone, the Session sheet has a switch that records scene depth maps for comparison runs; it is off by default and locked after the first tap.

A tap counts only after tracking has been normal for 1 s. Tapping the camera image marks that spot. **Mark** marks the spot under the center ring, which keeps a finger off the target. **Freeze** holds one frame still for precise tapping. Every tap rebuilds its ray from the saved frame's pose and intrinsics, never from the live camera.

| Tool | What a tap does | Refused when |
| --- | --- | --- |
| Ground | ARKit raycast to a horizontal plane: a found plane, else its extension, else ARKit's estimate. The last two are flagged, and so is a ray looking down less than 30°. | ARKit finds no ground along the ray |
| Wall | First and second taps are ground contacts at the wall's base. Direction `u` is the horizontal part of `p2 − p1`; normal `n = u × g`, flipped to face the camera. Later taps are optional validation contacts, reported as distance from the plane. | Contacts under 2 m apart horizontally; camera within 0.1 m of the wall's plane |
| On wall | `t = n·(p1 − o) / (n·d)`, point `= o + t·d`. Reports along-wall distance from the first contact and signed height above the ground line through both contacts. Hits beyond the contacts are flagged, and every point inherits its wall's warnings: a flagged contact, no check contact yet, or a failed check. | `t ≤ 0`; ray more than 60° from the normal (`|n·d| < 0.5`) |
| Two-view | Tap a feature, step sideways, tap it again in a new frame. The point is the midpoint of the rays' closest approach. Frozen second views show the first ray as a dashed line. | Ray angle under 15°; closest approach behind a camera; rays more than 2 in apart; both taps on one frame |
| Measure | Point to point: straight, horizontal, height difference, and along-wall distance against a chosen wall. Point to wall: facing gap (perpendicular distance to the wall line from above) and height above the wall's ground line. Takes a tape reading in feet and inches (`6`, `3 1/4`) and shows app minus tape. | |

The geometry lives in `Geometry/`, a Swift package that uses the standard library's `SIMD3<Double>` and Foundation only, so it builds and tests on macOS and Linux. Each formula above has a test against a hand-computed answer, as do pixel rays, projection, the portrait screen mapping, tape parsing and keyframe spacing.

The thresholds are the research note's gates. Each one is a hypothesis this run tests, not a calibrated value. The 2 m contact spacing is the note's 6.5 ft rounded to the figure the experiment brief uses. The 0.1 m camera offset is this rig's own guard: closer than that, the side of the wall the camera is on, which sets the normal's sign, is within tracking noise.

## Pass criteria

Set before the run, from the research note. The method passes when all of these hold:

- Wall, opening and rigid-ground distances are within 4 in of the tape. Facing gap and overhead height are within 6 in.
- The 30 ft span is within 8 in. The return-to-reference gap is within 4 in.
- Every accepted measurement's interval contains the taped value, using the bounds above as the interval (app value ± bound). A measurement with `accepted: false` counts as an abstention. It inherits every warning of the points and walls it depends on: a flagged ground hit, a wall whose contact was flagged, a wall with no check or a failed one, and a negative height above ground. Its error is still recorded, to show whether each warning was needed.
- The hidden-contact, low-parallax, mismatched-tap and wrong-plane cases abstain: a refusal, a flag, or a failed wall check.
- On both sides of a threshold, the decision rule never gives a false PASS. Use the public 3 ft fence clearance from Base's help page as `T`: PASS when `distance − bound ≥ T`, FAIL when `distance + bound < T`, UNSURE otherwise.
- The uncoached operator finishes one capture in 8 minutes, with at most one corrective prompt per measurement.

On a failure, narrow the method's claim or send that quantity to review. Never widen the bounds to pass. One house can admit a method to the demo; it cannot prove it across homes.

## One-hour outdoor protocol

Bring an iPhone without LiDAR running this app, a 50 ft tape, a spirit level, chalk or painter's tape, and two people. One of them, the uncoached operator, has not seen the tape values and gets no coaching. Stay on the ground: no ladders, and keep clear of gas fittings.

1. **Minutes 0 to 5: check the phone and the pixel mapping.** Open the Session sheet and confirm LiDAR shows No and Mesh reconstruction shows Not supported. With Ground, mark a sharp paving joint, walk 2 m away, and check the yellow dot still sits on the joint. Freeze a frame, tap the same joint, and check the tap ring sits on it.
2. **Minutes 5 to 15: tape the ground truth.** Chalk two marks at the base of one straight wall, 30 ft apart. Tape and write down, out of the uncoached operator's sight:
   - the 30 ft span between the marks;
   - one door or window: the width and the sill height above the ground at the wall;
   - the electric meter's bottom edge height above the ground;
   - the facing gap from the wall to a rigid fence or wall across from it, perpendicular to the wall, with chalk at both ends;
   - the lowest overhead near the wall (an eave corner or porch beam), height above the ground below it;
   - a reference X chalked on paving 2 m from the wall.
3. **Minutes 15 to 40: three captures.** Two by the coached operator, one by the uncoached operator. Start each with Session › New session. In each:
   1. Ground: mark the reference X.
   2. Wall: mark the two chalk marks as contacts, then one more point on the wall's base as a validation contact.
   3. On wall: mark both sides of the opening, its sill, and the meter's bottom edge.
   4. Ground: mark the chalk at the fence base.
   5. Two-view: mark the overhead corner, step about 1 m sideways, and mark it again.
   6. Walk to the far end of the wall and back, then mark the reference X again with Ground.
   7. Measure each taped quantity and type the tape value. The 30 ft span is contact to contact along the wall. The opening width is along the wall. The sill and meter are height above ground against the wall. The facing gap is the fence point against the wall. The overhead is the two-view point's height above ground against the wall. The return gap is the straight distance between the two reference X points, with the tape value 0 and error read directly.
   8. Note the capture time, from New session to the last measurement.
4. **Minutes 40 to 50: try to break it.** In a fourth session, try wall points on blank stucco, a capture in direct sun, a wall contact hidden by a shrub, a two-view pair with a 20 cm step, and a two-view pair where the second tap is on a different feature. Build one wall from a planter's base instead of the wall's, then validate it against the real wall base. Each of these should end in a refusal, a flag, or a failed check.
5. **Minutes 50 to 60: export and score.** Share each session's zip to a laptop and put it in `experiments/measure-lab/data/` (git ignores it). Fill in the results table from `measurements` and `refusals` in each session.json: maximum and median absolute error per method, abstentions, capture time, and the decision check on both sides of the 3 ft threshold.

## Build and run

Requires Xcode 26 or newer. The deployment target is iOS 26.0. XcodeGen 2.46.0 is needed only to change `project.yml`.

From this folder:

```sh
make test      # geometry package: swift test (runs on macOS and Linux)
make build     # app, unsigned: xcodebuild ... -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build
make project   # regenerate MeasureLab.xcodeproj after editing project.yml, then commit it
```

To run on a phone:

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig`.
2. Set `DEVELOPMENT_TEAM` to your Team ID and `BUNDLE_ID_PREFIX` to a prefix your team can register. The app id becomes `<prefix>.measurelab`.
3. Open `MeasureLab.xcodeproj`, pick the iPhone, and run.

Git ignores `Local.xcconfig`. Leave the team field in Xcode's Signing & Capabilities tab empty; setting it there writes your team into `project.pbxproj`, and CI's drift check fails.

`.github/workflows/measure-lab.yml` runs only when this folder or the workflow changes. It runs the geometry tests on Linux (Swift 6.2), regenerates the project and fails on drift, runs the tests on macOS, and builds the app unsigned.

## Session format

Each session is a folder, `Documents/Sessions/<id>/` on the phone, also visible in the Files app under On My iPhone › Measure Lab. **Share session** in the Session sheet sends it as one zip.

```
<id>/
  session.json
  keyframes/
    k00001.jpg              unrotated landscape sensor image
    k00001.depth.f32        only with LiDAR depth on: Float32 meters, row-major
    k00001.confidence.u8    only with LiDAR depth on: UInt8 0 low, 1 medium, 2 high
```

Units and frames, also written into `units` and `conventions` in every session.json:

- Lengths are meters, angles degrees. Times are seconds of device uptime, the clock of `ARFrame.timestamp`. `session.startedAt` (ISO 8601) and `session.startedAtUptime` line that clock up with wall time.
- World: ARKit's frame with `.gravity` alignment. Right-handed, y up, origin and heading wherever the session started. Each session has its own world; points from two sessions can't be compared.
- Camera: +x right and +y up in the unrotated sensor image, looking along −z.
- `pose`: camera-to-world 4×4, 16 numbers column by column (the `simd_float4x4` layout).
- `intrinsics`: `[fx, fy, cx, cy]` in pixels of that keyframe's JPEG.
- Pixels: `[u, v]`, with (0, 0) the top-left corner of the JPEG and v growing down. The ray through a pixel has camera-space direction `((u − cx)/fx, −(v − cy)/fy, −1)`, the same as `pixel_ray` in docs/02.
- Vectors are `[x, y, z]` arrays.

Top-level fields of session.json (`format` is `"measure-lab-session"`, `formatVersion` is 2):

| Field | Contents |
| --- | --- |
| `session` | `id`, `startedAt`, `startedAtUptime`, `appVersion`, `deviceModel` (for example `iPhone15,4`), `systemVersion`, `lidarAvailable`, `meshReconstructionSupported`, `sceneDepthEnabled` |
| `gates` | Every threshold the session ran with, so a replay can apply the same ones |
| `keyframes` | `id`, `img` (path), `w`, `h`, `intrinsics`, `pose`, `timestamp`, `tracking` (`normal`, `limited.excessiveMotion`, ...), `reason` (`motion`, `tap` or `freeze`), `depth` (`file`, `confidenceFile`, `w`, `h`) or null. The field names match the `keyframes` entries in docs/01's `scene.json`. |
| `taps` | `id`, `time`, `tool`, `step` (`firstContact`, `secondView`, ...), `keyframe`, `frozen`, `pixel`, `rayOrigin`, `rayDirection`, `displayMappingCheck`, and the `point` and/or `refusal` it produced |
| `points` | `id`, `kind` (`ground`, `wall`, `twoView`), `position`, `taps`, then per kind `ground` (`surface`, `planeAnchor`, `lookDown`), `onWall` (`wall`, `range`, `angleFromNormal`) or `twoView` (`firstTap`, `secondTap`, `rayAngle`, `gap`, `baseline`, `t1`, `t2`); `wallCoordinates` against the newest wall at the time (`along`, `heightAboveGround`, `offset`, `withinContacts`); `flags`, the point's own warnings (`estimatedPlane`, `extendedPlane`, `shallowLookDown`, `outsideWallContacts`); `wallWarnings`, for a point on a wall, that wall's warnings when the point was made |
| `walls` | `id`, `contacts` (point ids), `start`, `end`, `direction`, `normal`, `length`, `cameraPosition`, `validations` (`point`, `residual`, `tolerance`, `passes`), `warnings` as of the last check (`wallContactWarning`, `wallNotValidated`, `wallValidationFailed`) |
| `measurements` | `id`, `time`, `from`, `to` (point or wall id), `referenceWall`, `values` (every quantity that applies, keyed `straight`, `horizontal`, `vertical`, `alongWall`, `gapToWall`, `heightAboveGround`), `compared`, `tape` (`feet`, `inches`, `meters`) or null, `errorMeters` and `errorInches` (app minus tape), `warnings` (inherited as above, plus `belowGround`), and `accepted`, true only with no warnings. `heightAboveGround` is signed; the other values are non-negative. |
| `refusals` | `id`, `time`, `tool`, `tap` (null when no frame was resolved), `reason` (for example `grazingRay`, `rayAngleTooSmall`, `noGround`, `trackingNotReady`), `message` as shown, `values` behind it |
| `tracking` | `time`, `state`, one entry per tracking change |

Keyframes are saved when the camera moves 0.5 m or turns 15° since the last saved one, and at every live tap and freeze. They are listed in arrival order; sort by `id` or `timestamp` if order matters. A JPEG that was still being written when the zip was made can be in the folder without an entry; use only listed keyframes. `displayMappingCheck` on live taps is the pixel distance between ARKit's display transform and the app's own portrait mapping for the same screen point. It should stay under a pixel or two; a larger value means frozen-frame taps land on the wrong pixel.

To replay a tap: read the keyframe's `pose` and `intrinsics`, build the ray through `pixel`, and compare it with `rayOrigin` and `rayDirection`. `Geometry/` does exactly this in `CameraFrame.ray(throughPixel:)`.

## Results

Not run yet. The outdoor run on a physical iPhone without LiDAR is still to do.

| Quantity | Method | Tape | Captures (error, in) | Max | Median | Abstentions | Within bound |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 30 ft span | Wall contacts | | | | | | |
| Opening width | On wall | | | | | | |
| Sill height | On wall | | | | | | |
| Meter bottom height | On wall | | | | | | |
| Facing gap | Ground to wall | | | | | | |
| Overhead height | Two-view | | | | | | |
| Return to reference | Ground | | | | | | |

Break-it cases (expected result: refusal, flag or failed check):

| Case | Result |
| --- | --- |
| Blank stucco wall point | |
| Direct sun | |
| Shrub-hidden contact | |
| Two-view with a 20 cm step | |
| Two-view on different features | |
| Wall from a planter's base | |

Capture time, uncoached operator:

Decision check at 3 ft, both sides:

What this changes:
