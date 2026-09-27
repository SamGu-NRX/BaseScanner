# Measure lab

## Question

Can an ordinary iPhone without LiDAR measure what the battery placement checks need, outdoors, on the first try? The checks need a straight wall's line, points on that wall (meter, door and window edges), a facing gap to a fence or wall, and an overhead height. The method comes from the no-LiDAR capture research note (`docs/research/t3-no-lidar-capture.md`).

Every session is also recorded in the format below, so other pipelines can replay the same frames and taps.

## Using the app

The app tracks with ARKit and never uses LiDAR scene reconstruction. On a LiDAR phone, the Session sheet can record depth maps for comparison runs; the switch is off by default and locked after the first tap.

Taps count only after tracking has been normal for 1 s. Tap the camera image to mark a spot, or press **Mark** to mark under the center ring. **Freeze** holds one frame still for precise tapping.

| Tool | A tap | Refused when |
| --- | --- | --- |
| Ground | Finds the ground under the tap. Hits past the edge of a found plane, on ARKit's estimated surface, or looking down less than 30° are flagged. | ARKit finds no ground there |
| Wall | The first two taps mark where the wall meets the ground, and the wall is the vertical plane through them. Later taps on the wall's base check that plane. | The two contacts are under 2 m apart; the camera stands in line with the wall |
| On wall | Finds where the tap meets the newest wall. Reports the distance along the wall from the first contact and the height above the ground line. Points beyond the contacts are flagged. A point also carries its wall's warnings: a flagged contact, no check yet, or a failed check. | The ray is more than 60° from straight on, or the wall is behind the camera |
| Two-view | Tap a feature, step sideways, and tap it again in a new frame. On a frozen second view, a dashed line shows where the feature must lie. | The views are under 15° apart, the rays miss by more than 2 in, or both taps are on one frame |
| Measure | Point to point: straight, horizontal, height difference, and distance along a chosen wall. Point to wall: facing gap and height above ground. Type the tape reading in feet and inches (`6`, `3 1/4`) to record app minus tape. | |

The limits are the research note's gates. Each is a hypothesis this run tests, not a calibrated value, and every session records the ones it used.

## Pass criteria

Set before the run, from the research note. The method passes when all of these hold:

- Wall, opening and rigid-ground distances are within 4 in of the tape. Facing gap and overhead height are within 6 in.
- The 30 ft span is within 8 in. The return-to-reference gap is within 4 in.
- Every accepted measurement's interval contains the taped value, using the bounds above as the interval (app value ± bound). A measurement with `accepted: false` is an abstention; record its error anyway, to show whether its warnings were needed.
- The hidden-contact, low-parallax, mismatched-tap and wrong-plane cases abstain: a refusal, a flag, or a failed wall check.
- On both sides of a threshold, the decision rule never gives a false PASS. Use the public 3 ft fence clearance from Base's help page as `T`: PASS when `distance − bound > T`, FAIL when `distance + bound < T`, UNSURE otherwise. Equality is UNSURE, matching the Lane C decision rule.
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

Requires Xcode 26 or newer and an iPhone on iOS 26. XcodeGen 2.46.0 is needed only to change `project.yml`.

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

To replay a tap, build the ray through `pixel` from its keyframe's `pose` and `intrinsics`; it should match `rayOrigin` and `rayDirection`. `CameraFrame.ray(throughPixel:)` in `Geometry/` does this.

## Results

Not run yet.

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
