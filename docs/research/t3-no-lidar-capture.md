# Measuring clearances on an iPhone without LiDAR

ARKit world tracking, ground raycasts, and two-view triangulation are candidates for measuring visible boundaries on an iPhone without LiDAR. No device accuracy has been established. This proposal tests one straight wall and a visible rigid facing gap, with overhead triangulation only if that path works. Keep the B4 and B5 fallback in [01-feature-map.md](../01-feature-map.md) outside a tape-checked demonstration. Passing the one-hour experiment does not validate error bounds for automatic approval.

## Build in this order

1. A recorder. Per tap, save the frame ID, unrotated image, `camera.transform`, `camera.intrinsics`, tracking state, and tap pixel. `ARView.makeRaycastQuery(from:allowing:alignment:)` uses the live camera, so a tap on a frozen frame needs a ray rebuilt from that frame's pose.
2. One straight wall: its plane from ground contacts, with the meter and openings on it.
3. A visible rigid facing gap, such as a fence.
4. One overhead triangulation, only after step 2 works on a physical non-LiDAR phone.

Slope, hedges, and hidden boundaries stay in review.

## Method and fallback per quantity

| Quantity | Rule input | Method | Fallback |
| --- | --- | --- | --- |
| Wall line, corners | All checks | Ground-contact taps, one plane per straight facade | Shrub: triangulate two facade points |
| Meter | Within 20 ft (Base help page) | Tap the enclosure edges on the wall plane | Tape |
| Gas meter and piping | `gas_clearance_ft` | Triangulate the outer extents | Tape or review |
| Doors, windows | `opening_clearance_ft` | Tap edges, sill, and top | Window wells: review |
| Facing fence or wall | `facing_gap_ft` | Ground taps along the rigid base | Hedge or leaning fence: review or tape |
| Eaves, decks, stairs | `headroom_ft` | Two-view triangulation | Third view, then tape or review |
| Driveway, pool | `drive_clearance_ft`, `pool_clearance_ft` | Nearest visible edge as a ground polygon | Hidden edge: review |
| Ground slope | Set by Base | Review | Spirit-level rise over run |
| Cable route | `review_route_ft`, `max_route_ft` | Wall lengths plus vertical detours | Drift on return: review |

Measure obstacle separation from the battery boundary where the rule requires it. Record wall-to-facing-obstruction gap separately from free space beyond the battery, and match each rule to its specified measurement origin. Measure heights from local ground.

## Build the wall from the ground, so blank walls don't matter

ARKit's vertical plane detection needs wall texture, and blank stucco may never produce a plane. The wall's base usually has texture, and gravity supplies vertical.

1. With `worldAlignment = .gravity`, up is `g = (0, 1, 0)`.
2. Raycast two wall-ground contacts at least 6.5 ft apart. Prefer `.existingPlaneGeometry` on confirmed ground over `.estimatedPlane`.
3. Normalize the horizontal part of `p2 − p1` to get wall direction `u`.
4. Set `n = u × g`. The sign follows tap order, so flip `n` when `n · (o − p1) < 0`, with `o` the camera position.
5. Tap a third contact. `|n · (p3 − p1)|` validates the plane.

Each later tap is a ray `o + t·d` from its saved frame (`pixel_ray` in [02-implementation-plan.md](../02-implementation-plan.md)). It meets the wall at:

```
t = n · (p1 − o) / (n · d)        point = o + t·d
```

`hit_plane` in docs/02 does this. Reject `t ≤ 0`, grazing rays, and vertically stacked contacts. Wall texture never enters the math. Tracking still needs texture, so the prompt says "Aim lower to include the ground."

## Triangulate overhead points from two views

The user taps the same eave corner in two frozen frames taken 2.5 to 5 ft apart sideways. Take the rays' closest points:

```
w = o1 − o2   a = d1·d1   b = d1·d2   c = d2·d2   d = d1·w   e = d2·w
t1 = (b·e − c·d) / (a·c − b²)     t2 = (a·e − b·d) / (a·c − b²)
point = midpoint of (o1 + t1·d1) and (o2 + t2·d2)
```

Reject a negative `t`, an intersection angle under 15°, rays passing more than 2 in apart, or a third view off by more than 0.5°. Depth error grows as about `Z²·δθ / b` for distance `Z`, angular error `δθ`, and baseline `b`: about 3 in at 10 ft with a 3.3 ft baseline and 0.5° error, and 9 in at 16 ft. Taps on two different physical points can still nearly intersect, and no residual detects shared scale error.

## Accuracy hypotheses

At 3 to 10 ft, expect 2 to 4 in for accepted ground and wall taps and 4 to 8 in for triangulated points. The ±0.3 ft tap error in docs/02 fits that range but is unmeasured without LiDAR.

From 4.6 ft, with 0.8 in height error and 0.5° angle error, a ground tap's error is about 1.7 in at 45° look-down, 3.3 in at 30°, and 10 in at 15°.

Over 30 ft, a 2% scale error gives 7 in. The meter anchor doesn't bound it. Across the 22 in battery depth, 0.8 in errors at each end give about 2.9° of slope uncertainty, so slope stays in review.

## Acceptance gates

Accept a measurement only when every gate, each a hypothesis, holds.

- `ARCamera.TrackingState` is `.normal` and stable for 1 s. This alone proves no accuracy.
- Ground taps look down 30° or more.
- Wall rays are within 60° of the normal: `|n · d| ≥ 0.5`.
- Repeat taps, and the third wall contact, agree within 2 in.
- A missing hit or sparse `rawFeaturePoints` never counts as empty space.

## Decision rule

`error` is a bound covering both boundaries and shared bias, not a one-sigma value. For a minimum clearance `T`:

- PASS when `distance − error > T`.
- FAIL when `distance + error < T`.
- UNSURE otherwise.

Reverse the inequalities for maximums such as `max_route_ft`. An unobserved area returns UNSURE whatever the margin, because missing coverage is never a pass. Confirm the applicable installation requirements with Base before showing compliance results.

## Fallbacks

After one guided retry, the app offers:

- **Tape entry.** A typed value, stored with source `tape` and an error lane C sets.
- **Needs installer measurement.** The capture ends complete with a named review reason. That is not a pass.

## One-hour outdoor test

The test tries to break the method, not calibrate it. Bring a non-LiDAR iPhone running the step 1 recorder, a tape, a spirit level, and two people. One operator never saw the tape values and gets no coaching. Avoid gas fittings and climbing.

1. Minutes 0 to 5. Confirm `supportsSceneReconstruction(.mesh)` returns false. Check a tapped corner reprojects to the right pixel.
2. Minutes 5 to 15. Tape a 30 ft span, an opening, the meter height, a facing gap, the lowest overhead, and footprint rise over run.
3. Minutes 15 to 40. Make three captures, one by the uncoached operator. Measure a reference before and after a 30 ft walk and back.
4. Minutes 40 to 50. Try blank stucco, bright sun, a shrub-hidden contact, and low parallax. Tap different points in the two views. Build one wall from a planter's base.
5. Minutes 50 to 60. Record maximum and median error per method, abstentions, and capture time. Test decisions on both sides of a threshold.

The method passes when:

- Wall, opening, and rigid-ground distances within 4 in of the tape. Facing gap and overhead within 6 in.
- 30 ft span within 8 in. Return-to-reference gap within 4 in.
- Every accepted interval contains the taped value. No false PASS.
- Hidden, low-parallax, mismatched-tap, and wrong-plane cases abstain.
- The uncoached operator finishes in 8 minutes, with at most one corrective prompt per measurement.

On a failure, narrow the method's claim or send that quantity to review. Never widen error bars to pass. One house can admit a method to the demo, not prove it across homes.
