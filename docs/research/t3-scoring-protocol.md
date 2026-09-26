# Scoring protocol for capture pipelines

For lane D and the reconstruction team.

A comparison is fair when every pipeline processes the same recording, at the same three marked spots, under one frozen `rules.yaml`, scored against a tape survey no pipeline sees. The honest claim is a case series: at these spots, each pipeline missed these distances by this much and made this many unsafe calls. It is not an accuracy rate or a safety result.

## Fix the inputs first

- **One recording per house**, from a non-LiDAR iPhone running [Measure Lab](https://github.com/SamGu-NRX/house-scanning/pull/7) (`experiments/measure-lab`) until the lane A app in the [feature map](../01-feature-map.md) records sessions. LiDAR is a separate labeled condition.
- **Three candidate spots per house.** Mark each 31 in x 22 in footprint with chalk or painter's tape before recording. Pick a clear-looking spot, one near a rule boundary, and one between. Pipelines see the marks in images, never distances. Score spot placement error separately.
- **One policy.** Every pipeline is scored under one complete set of `rules.yaml` parameters that does not change during the study. Unpublished values read "set by Base".
- **One frame list** for every row, plus the close-ups. About 50 frames is a compute guess, not a tested optimum.

Freeze the frame list, model versions, extraction code, timeouts and the `rules.yaml` hash before anyone opens the survey.

## Rows to run

The required rows are AR taps, where a failed raycast counts as missing, and plain photos: Depth Anything 3 metric with intrinsics but no poses, taps or tape ([stack research](../03-stack-research.md)).

Reconstruction rows such as MapAnything or OOOSplat join only if their predictions arrive before a deadline the team sets before fieldwork. The demo never depends on them. Each declares one scale source: native metric output, the scale distance S below, or AR camera poses. Each variant is its own row.

## Gates

- **Fieldwork waits for a working exporter and one verified projection.** Measure Lab saves each keyframe's timestamp, pose, intrinsics and image size from the same `ARFrame`, and the capture-contract probe in [#9](https://github.com/SamGu-NRX/house-scanning/pull/9) checks that metadata. Before fieldwork, still run the [implementation plan](../02-implementation-plan.md) test: project a tapped mark into three saved frames and record the pixel error.
- **Decision scoring waits for a complete policy evaluator** that returns UNSURE when evidence is missing. Distance errors do not wait.
- **House 1 is for debugging.** Freeze all code before houses 2 and 3.

## Distances to survey

Survey after recording, so no tape shows in frames. Locate spots by tape offsets from permanent house corners, never AR coordinates. Two people measure each distance independently and re-measure together if they differ by more than 1 cm, an untested starting value. Withhold endpoint photos from every pipeline.

Say whether each distance starts at the wall or the footprint edge. Mixing them subtracts battery depth twice. Use a tape unless noted.

- **S. Scale distance.** Two marked points on one wall, 4 to 6 ft apart. Given only to rows that declare it. Never scored.
- **1. Wall length.** Exterior corner to corner. Laser to a target card.
- **2. Usable span.** Nearest limiting edges on each side of the spot.
- **3. Cable route.** Supported cable route from the declared meter connection point to the battery connection point, measured along every segment, including vertical legs and detours around obstacles. Record both connection endpoints and the route polyline. Base's 20 ft from the meter, `review_route_ft`, `max_route_ft`.
- **4. Gas.** Footprint to the nearest gas meter, regulator or pipe, without touching. `gas_clearance_ft`, 3 ft per Base.
- **5. AC unit.** 3 ft per Base.
- **6. Drivable surface.** Footprint to the nearest surface a car can reach. `drive_clearance_ft`.
- **7. Pool.** Footprint to the permanent pool's edge. `pool_clearance_ft`.
- **8. Door.** Footprint side to the nearest jamb, noting the swing. `opening_clearance_ft`, 3 ft in IRC R328.
- **9. Window.** Footprint side to the nearest operable window. `opening_clearance_ft`.
- **10. Window height.** Ground to the lowest operable window opening.
- **11. Facing gap.** Wall to the nearest facing fence, hedge or wall, minimum across the spot's width. Laser at three points. `facing_gap_ft`.
- **12. Headroom.** Ground to the lowest overhead underside above the spot. Vertical laser. `headroom_ft`.
- **13. Ground slope.** Height difference across the footprint depth. Level and ruler.

Record a missing feature as "absent" and an unreachable one as "not measured", never a guess. Every distance applies to every spot, so the denominator is fixed. Also record which windows open, door swings, drivable surfaces and ground type.

## Survey and results files

The formats are in the harness README, `experiments/scoring/README.md` ([#4](https://github.com/SamGu-NRX/house-scanning/pull/4)): a rules file, one survey file per house and one results file per pipeline run. All three use feet and the survey IDs above. Keep real surveys and results beside the capture in `captures/` or `data/`, never in git. Use the recording's sha256 as its capture ID; every results file carries the rules file's sha256. The harness matches those IDs and the rules hash, but cannot independently verify which recording a pipeline processed.

To score the AR row, write a short map after the walk from each Measure Lab measurement to its survey ID. `score import-measure-lab` turns the session and the map into a results file.

The harness derives each check's survey outcome from the survey value, its uncertainty and the frozen rules, with the strict rule in its README: a value exactly on a threshold is borderline. A teammate who built no pipeline records the facts a tape cannot settle, such as which windows open and which surfaces a car can reach, before seeing any output. This reference is not an installer.

## Metrics

Report every row at every spot. Never average away missing outputs.

- **Absolute error.** |predicted - true| in inches, with the signed error. Median and maximum per house.
- **Error relative to the deciding threshold.** With margin m = |true - threshold| and survey uncertainty u, report error / max(m, u). At 1 or above, the error could put the run on a boundary or flip the check. If both are zero, report "at threshold".
- **Missing outputs.** Against the fixed denominator, split into unsupported, failed, and not surveyed.
- **Unsafe passes.** A pipeline PASS where the label is FAIL. This matters most. Count a PASS where the label is borderline or UNSURE separately as a missed review, and a pipeline UNSURE or FAIL where the label is PASS as over-caution. Report false rejections beside them, and count a pass or fail made without its measurement separately.
- **Abstentions.** UNSURE rate, split into justified, when the label is borderline or evidence is missing, and avoidable.
- **Capture time.** Walk time, taps and retakes of the shared recording. Photo rows cannot claim a shorter capture from it.
- **Latency.** Upload finished to result shown, cold and warm, with crashes and timeouts.

## What one to three houses can and cannot show

They can show:

- Which distances each pipeline returns, and any unsafe pass at these spots.
- Paired errors on identical input, such as each row's facing-gap error at spot c2.
- Whether errors fit the plan's error bars: plus or minus 0.3 ft for taps, 0.5 ft for the mesh, 1.5 ft for photo detection. Those bars are hypotheses to test.

They cannot show:

- An accuracy rate for homes in general. Frames and distances from one house are not independent samples.
- Validated error bars. Tuning them on a house and scoring that house proves nothing.
- Safety. Zero unsafe passes at nine spots is a sample result.
- Homeowner effort. One shared recording cannot measure a first-time user's effort with photos.
- Installation eligibility. Electrical checks are out of scope, and three failed spots do not make a house unsuitable.

An honest pitch sentence: "On [N] houses, AR taps measured [k] of [n] distances, median error [x] in, [u] unsafe passes."
