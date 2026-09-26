# Placement cases for the server's HTTP API

Black-box cases for the placement server. Each `<id>.json` holds a scene and what the result must
show. The scenes were written from `server/schemas/scene.schema.json` and `result.schema.json` at
origin/t3/server 69c6c3c and the golden tests in `docs/research/t3-lane-c-review.md` at
origin/t3/research a7d91f1. After the first run they were corrected against `server/rules.yaml`
at origin/t3/server 2c9348f, which is public configuration. Nobody read the server's code, tests
or fixtures to write them, so a passing server has been checked against the spec, not against its
own tests.

`generate.py` writes every JSON file in this folder. Edit it, not the JSON, then run from
`verification/`:

```sh
uv run python e2e/cases/generate.py
```

## Why the assertions avoid the decision

`rules.yaml` sets `policy.auto_approve: false`, so any would-be pass or reject becomes
`manual_review`. The cases therefore assert on the sweep, on single checks, on `spot` and on
`missing_evidence`. They assert a decision only where the scene alone forces it:

- An unsure spot or an unobserved area rules out `pass`.
- An unexplored end rules out `reject`. So does a missing `coverage`, since its ends then default
  to unexplored.

## Expectation keys

The keys follow the lead's case format. The cases use two additions and one convention:

- `checks[].measured_ft` and `checks[].plus_minus_ft` (added): the gap and error the check must
  report, within 1e-6. The g10 and g13b outcomes mean something only if the server measured the
  gap the case built. With a different battery depth it measures a different gap, and these keys
  catch that before the outcome is compared.
- `missing_evidence_empty: false` means the list must be non-empty.
- `start_outcomes` (d cases): `{"wall_id", "start_ft", "outcome", "why"}`. The sweep run that
  contains that battery start must have that outcome.
- `rules_assumed` maps a check-id substring to the `threshold_ft` the case depends on: `gas` 3 ft
  (`clearances.gas_ft`), `opening` 3 ft (`clearances.opening_ft`), `headroom` 6.5 ft
  (`headroom.min_ft`) and `route_length` 20 ft (`route.max_ft`). `route.confident_reach_ft` (15)
  is not reported as any check's `threshold_ft`, so g09 can't declare it there. A change to it
  shows up as g09-reach-14 or g09-reach-15 failing.

## The rules these cases depend on

From `rules.yaml` at 2c9348f, rechecked at f2705dd:

- Battery 31/12 × 11/6 ft (W ≈ 2.5833, D ≈ 1.8333), matching the review's table.
- `meter_working_space` 2.5 ft wide, centred on the meter. A battery overlapping s = (−1.25, 1.25)
  fails, so starts in (−1.25 − W, 1.25) = (−3.833, 1.25) fail. The starts −3.833 and 1.25 only
  touch the space: gap 0 against threshold 0, which is unsure.
- `pool_ft` 10 and `drive_ft` 5, both placeholders. With no pool or driveway in the scene these
  checks pass only if the ground was seen 10 ft around the footprint. Otherwise they are unsure
  and ask for a photo.
- `openings.types` is `[door, garage_door, window]` since f2705dd (it was `[door, window]` at
  2c9348f). A garage door therefore has the 3 ft opening clearance, and it also fails the route
  (`route.crossing.garage_door: fail`). g01 and g08a hold under either version.
- `route.crossing.window: detour`, `gas_meter: detour` and `elec_box: detour`.
  `route.corner_allowance_ft` adds 0.5 ft per corner the cable turns. `route.height_ft` 1: the
  cable runs 1 ft above the ground. The route length has no vertical run from the meter down to
  that height (at 2c9348f a spot at s = 1.583 reports route 1.583). A detour over an object adds
  2 × (top − 1): up to its top and back down. Going under is impossible when the object sits on
  the ground. A window whose bottom is above 1 ft is crossed with no extra (g12a: route 7.042 for
  start 7.042).
- `route.confident_reach_ft` 15: a longer route is unsure. Since f2705dd the `route_length`
  check reports it as `review_threshold_ft`: pass needs length + error < 15. `route.max_ft` 20 (`route_length`,
  `at_most`): pass needs length + error < 20, fail needs length − error > 20. The route's error
  is the meter's and the wall's errors summed (at 2c9348f a wall at ±0.3 with an exact meter gives
  a route at ±0.3).
- `headroom.min_ft` 6.5 (`at_least`): pass needs clearance − error > 6.5, fail needs
  clearance + error < 6.5.
- `ground.allowed` is concrete, gravel, lawn and mulch. A deck under the footprint fails
  `ground_surface`.
- `facing.measured_from: battery_front`, `min_ft` 3: a 9 ft facing gap gives 9 − 11/6 ≈ 7.17.

## Fixture conventions

- Units are feet. Walls are exact (`plus_minus_ft: 0`) unless a case says otherwise. So are the
  meter and every object: `source: "tape"` with an explicit error, so no default error applies.
- A straight wall along +x has outward +z (the schema's clockwise rule). s = x − meter x.
- Cases g10, g11a, g11c and g13 place the wall at z = −11/6. A flush battery's front edge then
  sits at z = 0.0 exactly in floating point, so a gas strip at z = d measures exactly d. The
  equality rows need this: 3.3 − 0.3 and 2.7 + 0.3 both evaluate to exactly 3.0, so a server
  that forgets equality lands on the wrong side and fails the case.
- "Fully observed" means wall, overhead, facing and ground bands from 15 ft past the left end to
  15 ft past the right end, ground seen 15 ft out, both ends `limit`, facing depth 9, no overheads,
  and concrete ground over the chain. 15 ft clears the 10 ft pool distance measured from a
  footprint whose front is 11/6 ft out. g05, g08b and g11a–c keep coverage ending at the chain,
  since they passed with it and g11 depends on exact gaps.
- A gas "strip" is a long, thin gas footprint parallel to the wall. It spans past both ends of
  the stretch it covers, so every battery beside it has the same perpendicular gap. It stands in
  for the review's "every start has the same gas gap".

## Cases

| Case | Golden | Asserts | Arithmetic |
| --- | --- | --- | --- |
| g01-unseen-beyond-garage | 01 | `missing_evidence` empty; starts in (−19.9, −8.2) fail with `route` | Wall s = [−20, 10], garage [−5.5, −1], nothing observed left of s = −9. A battery with right edge b < −1 needs a cable across the garage (b ≤ −5.5 means a ≤ −8.083). A battery with b > −1 overlaps the working space. So every start left of the meter fails. Right of the meter a start must clear the working space (a ≥ 1.25) and, since f2705dd, the garage's 3 ft opening clearance (a ≥ −1 + 3 = 2). Pool then needs ground from 2 − 10 = −8 (−8.75 at 2c9348f), both ≥ −9. |
| g03-negative-s-near-edge | 03 | spot on w1 within [−9, −6]; starts in (−8.4, 6.9) fail; no photo request | Pads are straight 3 ft segments at s = [−9, −6] and [7, 10]. Between them sit 7 segments of 13/7 ≈ 1.857 ft, each shorter than the battery, with corners at s = −4.143, −2.286, −0.429, 1.429, 3.286, 5.143. Headings run 32°, 24°, …, −24°, −32°, so every corner is an outside corner. Left route = 6 + 3 corners × 0.5 = 7.5; right = 7 + 3 × 0.5 = 8.5; left wins. Measuring to the far edge gives 103/12 + 1.5 ≈ 10.08 > 8.5 and would pick the right pad. Pad starts are (−9, −8.583] and [7, 7.417]; every other start crosses a corner. |
| g05-inside-corner-gas | 05 | starts on w1 in (6, 7.4) fail with `gas`; never pass | w1 is z = 0 from x = −7 to 4 (w1 extended 1 ft left of the golden, so the meter at x = −6 sits inside the wall rather than on its end); s = x + 6. w2 is x = 4 going +z; gas point [4, 4] at s = 14. For start s the battery is x ∈ [s − 6, s − 6 + W], z ∈ [0, 11/6]. At s = 6 the nearest corner is (31/12, 11/6): √((17/12)² + (13/6)²) = √965/12 ≈ 2.589 < 3. Fail needs the right edge past 4 − √(9 − (13/6)²) = 4 − √155/6 ≈ 1.925, so s > 5.342. The last start on w1 is 89/12 ≈ 7.417 (2.167). Unrolled gap 14 − 103/12 = 65/12 ≈ 5.417 would wrongly pass. |
| g06-regulator-footprint | 06 | starts in (3, 9) fail with `gas`; never pass | Gas footprint: body x ∈ [6.5, 7.5], z ∈ [9.5, 10.5], with a spike reaching [7, 23/6]. Battery front at z = 11/6, so the gap to the tip is 23/6 − 11/6 = 2 whenever the battery covers x = 7, i.e. starts in [7 − W, 7] ≈ [4.417, 7]. Outside that the gap is √(dx² + 4) < 3 while dx < √5 ≈ 2.236, so starts in (2.18, 9.24) fail. The body alone gives 10 − 11/6 ≈ 8.17 and would pass. Facing depth is 12 here so the body stands inside it. |
| g08a-garage-blocks-route | 08 | spot null; starts in (5, 9.4) fail with `route`; no photo request; never pass | Wall s = [−0.5, 12], garage [1, 5]. Starts in [−0.5, 1.25) overlap the working space. From 1.25 on, the route to the near edge covers [0, a] and crosses the garage, which starts at 1. The golden's garage [3, 7] and pad [10, 13] were shifted so the meter side holds no start. |
| g08b-missing-wall-blocks-route | 08 | spot null; starts on w2 in (2, 9.4) fail with `route`; no photo request; never pass | w1 s = [−0.5, 1] (1.5 ft, shorter than the battery), no wall for s = (1, 2), w2 s = [2, 12]. The schema says no battery backs onto and no cable crosses a no-wall stretch, so every start fails by geometry. |
| g10-e03-{pass, upper-edge, lower-edge, fail} | 10 | gas check pass / unsure (margin) / unsure (margin) / fail, with measured d and ±0.3; no photo request; the fail row also needs spot null and every start in (−5, 12.4) failing with `gas` | T = 3, e = 0.3. d = 3.31: 3.31 − 0.3 = 3.01 > 3, pass. d = 3.3: 3.3 − 0.3 = 3.0, not > 3; 3.6 not < 3, so unsure. d = 2.7: 2.7 + 0.3 = 3.0, not < 3, so unsure. d = 2.69: 2.99 < 3, fail. |
| g10-e05-* | 10 | as above with ±0.5 | d = 3.51, 3.5, 2.5, 2.49 → 3.01 > 3; 3.0; 3.0; 2.99 < 3. |
| g10-e15-* | 10 | as above with ±1.5 | d = 4.51, 4.5, 1.5, 1.49 → 3.01 > 3; 3.0; 3.0; 2.99 < 3. |
| g10-derived-compound-error | 10 | gas unsure (margin), measured 3.5, ±0.6; never pass | Wall ±0.3 plus gas ±0.3 = ±0.6 (linear, as the review specifies). 3.5 − 0.6 = 2.9 is not > 3, and 3.5 + 0.6 = 4.1 is not < 3. Root-sum-square would give ±0.424 and 3.076 > 3, a wrong pass. Every g10 gas object also carries `conf: 0.6`; treating 1 − conf as an error would shift every row. |
| g11a-unexplored-corner | 11 (a) | decision manual_review; spot null; `missing_evidence` non-empty; starts in (−3, 5.4) fail with `gas` | Strip at gap 1: 1 + 0 < 3 fails every start. The right end at s = 8 is `unexplored`, so reject is ruled out and the wall past the corner must be requested. The end sits 8 ft out, inside `route.max_ft` 20. |
| g11b-both-ends-real-all-fail | 11 (b) | decision manual_review or reject; spot null; no photo request; w1 starts in (−3, 5.4) and w2 starts in (8, 11.4) fail with `gas` | w1 s = [−3, 8], outside corner, w2 runs x = 8 toward −z, s = [8, 14], outward +x. Strips sit 1 ft beyond each wall's battery front: z = 11/6 + 1 and x = 8 + 11/6 + 1. |
| g11c-unobserved-ground | 11 (c) | decision manual_review; spot within [2.328, 10]; `missing_evidence` non-empty; starts in (−9.9, 2.2) fail with `gas`; starts in (2.5, 7.3) unsure | Strip x ∈ [−12, −0.5] at gap 1. A start a > −0.5 has gap √((a + 0.5)² + 1), under 3 while a < 2√2 − 0.5 ≈ 2.328. Ground was observed only for s ≤ 1, so starts past 2.328 pass gas on unseen ground: unsure. The last start is 10 − W ≈ 7.417. |
| g12a-subgrid-start | 12 | spot within [7, 7.1 + W]; starts in (−1, 6.95) and (7.2, 13.4) fail with `opening` | Windows [3, 4] and [10.1 + W, 11.1 + W] ≈ [12.683, 13.683]. Legal start: a − 4 > 3 and (10.1 + W) − (a + W) > 3, so 7 < a < 7.1. Both ends give a gap of exactly 3, which is unsure, not pass. The 2 in grid from 0 samples 7 and 43/6 ≈ 7.167, both outside. The wall starts at −1, so any battery left of window 1 would need its right edge < 0 but has it ≥ −1 + W > 0. Past window 2 a start needs a > 16.683, beyond the wall end at 16. The cable detours under window 1. |
| g12b-exact-fit-last-start | 12 | spot within [6, 6 + W]; no photo request | Five 1.8 ft segments (headings 40° to 8°) for s = [−3, 6], then one segment of exactly W at heading 0° ending the wall. Its only start, 6, is also its last. Measured in floating point, the segment is 4.4e-16 longer than W. Route 6 + 3 corners × 0.5 = 7.5. |
| g13a-unsure-never-outranks-pass | 13 | spot within [−8, −1.25]; gas check at the spot passes; starts in (−3.8, 1.2) fail with `meter_working_space`; starts in (1.3, 5) unsure; no photo request | Strip x ∈ [0.3, 12] at gap 3.2, ±0.3: every battery overlapping x ≥ 0.3 gets 3.2 − 0.3 = 2.9, unsure. A battery with right edge b < 0.3 gets √((0.3 − b)² + 3.2²), which passes when > 3.3: (0.3 − b)² > 0.65, b < 0.3 − √0.65 ≈ −0.506. The working space also needs b ≤ −1.25, so passing spots have b ≤ −1.25 and route ≥ 1.25. Unsure spots start at 1.25 (route 1.25), and the passing spot must still win. |
| g13b-unsure-alone | 13 | decision manual_review; spot on w1; gas unsure (margin), measured 3.2, ±0.3; starts in (−0.4, 1.2) fail with `meter_working_space`; starts in (1.3, 5.3) unsure; no photo request | The wall starts at −0.5, so every battery ends at ≥ 2.08 and overlaps the strip: gap 3.2 for all. The spot is fully observed and unsure only by margin, so no photos. |
| g07-headroom-fail | 07 | headroom fail, measured 5.5, ±0.5; spot null; every start in (−5, 12.4) fails with `headroom`; no photo request | Overhead over the whole wall at 6.5 − 1 = 5.5 ± 0.5: 5.5 + 0.5 = 6.0 < 6.5. |
| g07-headroom-pass | 07 | headroom pass, measured 7.2, ±0.5; starts in (−5, −3.9) and (1.3, 12.4) pass; no photo request | 6.5 + 0.7 = 7.2: 7.2 − 0.5 = 6.7 > 6.5. The gap between the two intervals is the meter working space. |
| g07-headroom-margin | 07 | headroom unsure (margin), measured 6.8, ±0.5; same intervals unsure; no photo request | 6.5 + 0.3 = 6.8: 6.8 − 0.5 = 6.3 is not > 6.5 and 7.3 is not < 6.5. |
| g07-headroom-unobserved | 07 | headroom unsure (unobserved); same intervals unsure; `missing_evidence` non-empty | No overheads, and the overhead band is left out of coverage. |
| g07-headroom-partial-span | 07 | starts in (5.5, 8.4) fail with `headroom`; starts in (1.3, 5.3) and (8.6, 12.4) pass | Overhead 5.5 ± 0.5 over s = [8, 8.5] only. A battery [a, a + W] overlaps it when 8 − W < a < 8.5, i.e. 5.417 < a < 8.5, even if it covers only a few inches of the battery. The schema's overheads have no depth out from the wall, so the golden's "front strip only" is tested along the wall instead. |
| g09-reach-14, -15, -16, -20, -21 | 09 | `route_length` measured L, ±0: pass at 14, unsure at 15, 16 and 20, fail at 21. For pass and unsure the spot is [L, L + W] and the sweep at start L has that outcome. For fail the spot is null and the sweep at L fails with `route_length`. No photo request | The wall runs s = [−1, L + W], all ground before L is deck and [L, L + W] is concrete. Every start before L fails `ground_surface`, starts left of the meter also fail the working space, and L is the last start. So the route is L with no corner. 14 < 15, pass. 15 is not inside 15. 16 is past 15 but below 20. For 20: 20 + 0 is not < 20 and 20 − 0 is not > 20, so unsure. For 21: 21 − 0 > 20, fail. |
| g09-reach-20p2-pm03 | 09 | `route_length` unsure, measured 20.2, ±0.3; spot at L | Meter at ±0.3, wall exact. 20.2 − 0.3 = 19.9 is not > 20, and 20.5 is not < 20. |
| g09-reach-20p4-pm03 | 09 | spot null; the sweep at L fails with `route_length` | 20.4 − 0.3 = 20.1 > 20. |
| g09-vertical-run | 09 | `route_length` unsure, measured 16, ±0; `route_path` pass; spot at [11, 11 + W] | Pad at 15 − 4 = 11. An `elec_box` at s = [4, 5], 0 to 3.5 ft tall, sits across the 1 ft cable run, and elec boxes detour. Over: 2 × (3.5 − 1) = 5. Routed 11 + 5 = 16 = 15 + 1, past the confident reach. Measuring along the wall alone (11) would pass. |
| c5-no-coverage | C5, scene schema | decision manual_review; `missing_evidence` non-empty; starts in (−6, −3.9) and (1.3, 7.4) unsure, starts in (−3.8, 1.2) fail with `meter_working_space` | Clean wall s = [−6, 10] with ground and facing data but no `coverage`. "Absent means nothing is known to be observed" makes every start unsure except where the working space, which needs no observation, fails it. Absent ends default to unexplored, which rules out reject. |

## Drift cases

The cases above set every error explicitly, so they never exercise the error model's growth with
distance. The `d-` cases leave `plus_minus_ft` off the walls, the meter and the objects, and give
objects `source: "tap"`. Ground and facing keep explicit errors so only the checks under test
move.

### The error model, from rules.yaml and server/README.md at f2705dd

- `errors.meter_ft` 0.3, `errors.wall_ft` 0.3, `errors.tap_ft` 0.3.
- `errors.drift_per_ft` 0.16 is added per foot walked along the walls from the meter to the
  default error of walls, tap and vlm objects and ground patches. It is not added to tape, the
  meter itself or an explicit `plus_minus_ft`.
- A battery position comes from the wall, so a point of the battery at walked distance x carries
  0.3 + 0.16x.
- A gap or a route sums the errors of its two ends (linear, as the C5 margin rule and g10's
  derived row use).
- A route's ends are the meter and the battery's near edge. A gas gap's ends are the gas meter
  and the battery edge nearest it.

### d-reach-drift-right: cable reach, `at_most` 20 with review line 15

Wall s = [−1, 29], meter at 0. For a start a > 0 the route is a (straight wall, no corners) and its
error is 0.3 (meter) + 0.3 + 0.16a (wall at the near edge) = 0.6 + 0.16a.

| Line | Condition | Start |
| --- | --- | --- |
| pass / unsure | a + 0.6 + 0.16a < 15 | a < 14.4 / 1.16 = 12.4138 |
| unsure / fail | a − 0.6 − 0.16a > 20 | a > 20.6 / 0.84 = 24.5238 |

Asserted starts: pass at 5 and 12.2138. Unsure at 12.6138, 18 and 24.3238. Fail at 24.7238 and
25.5. Each boundary is bracketed 0.2 ft inside on both sides, which is more than one 2 in sweep
step, so each point falls inside a run rather than between two. Using the far edge (a + W) for the
wall term would move both lines by 0.16W / 1.16 = 0.356 and 0.16W / 0.84 = 0.492, which the points
0.2 ft inside catch. So would any cutoff that is off by 0.16W = 0.413.

### d-reach-drift-left: the same, left of the meter

Wall s = [−29, 1]. Left of the meter the near edge is the battery's right edge b = a + W, and
the route is −b. The table above holds for −b, so each asserted start is a = −(right-case start) −
W: pass at −7.5833 and −14.7971, unsure at −15.1971, −20.5833 and −26.9071, fail at −27.3071 and
−28.0833. The lines sit at a = −12.4138 − W = −14.9971 and a = −24.5238 − W = −27.1071.

### d-gas-drift: gas clearance, `at_least` 3

Wall s = [−1, 20]. A tapped gas meter on the wall line at s = 4 (span [4, 4], no footprint)
carries 0.3 + 0.16 × 4 = 0.94. For a start a > 4 the gap is d = a − 4 and its error is 0.94 +
(0.3 + 0.16a) = 1.24 + 0.16a.

| Line | Condition | Start |
| --- | --- | --- |
| fail / unsure | (a − 4) + 1.24 + 0.16a < 3 | a < 5.76 / 1.16 = 4.9655 |
| unsure / pass | (a − 4) − 1.24 − 0.16a > 3 | a > 8.24 / 0.84 = 9.8095 |

Asserted starts:

- **Fail:** 3, where the battery [3, 5.583] covers the gas meter: gap 0, and 0 + 1.88 < 3. Also
  4.7655.
- **Unsure:** 5.1655, 7.5 and 9.6095.
- **Pass:** 10.0095 and 11. Both routes also pass: 11 + 0.6 + 1.76 = 13.36 < 15.

All starts sit right of the working space. The route to them crosses the gas meter, which
detours; a gas meter with no heights added no extra length at 2c9348f.

### What rules.yaml and the README leave open

- **Which battery point carries the drift.** The model gives drift for "AR-placed positions".
  The battery is placed from the wall, not tapped, and it spans W, over which drift changes by
  0.16W = 0.413 ft. These cases take the point the measurement ends at: the near edge for the
  route, the edge nearest the gas for a gas gap. The far edge or the centre is an equally literal
  reading and moves every line (see the reach arithmetic above).
- **Walked distance for an object with a span.** For a tapped object spanning [s0, s1], it could
  be s0, s1 or the nearest end. d-gas-drift uses a zero-length span to avoid the question.
- **Whether the meter's error enters the route.** The README says drift is not added to the
  meter. Whether its 0.3 base enters the route error is inferred from 2c9348f, where both
  defaults gave a route at ±0.6.
- **How errors combine.** Linear sum is assumed, as elsewhere in this suite. Root-sum-square
  would move every line.
- **Whether drift enters checks with explicit inputs.** Facing gaps and the working space involve
  the wall's drifting error. These cases give facing 20 ft (18.17 from the battery front, far
  above 3 + any error here) and keep every asserted start well clear of the working space.

## Assumptions a failure should be checked against

- A battery must sit flush on one straight segment (review item 4, golden 04; the result's
  `spot.segment`). g03 and g12b use short segments to rule out starts, and g08b uses a 1.5 ft wall.
- Gas objects with a footprint are measured by footprint. In g10, g11a and g11b the strip's span
  covers the meter, which makes the cable detour; those cases assert only gas and photo requests.
  g13a keeps the span off the left routes.
- s counts the length of a no-wall stretch (g08b: w2 starts at s = 2, after a 1 ft gap).
- g09's last start is end − 2.583333333333 (the width as rules.yaml writes it) in floating point.
  For L = 16, 20, 20.4, 21 and 11 the wall end is chosen so that start is exactly L. For 14, 15 and
  20.2 no such end exists, so the start lands 1.8e-15, 1.8e-15 and 3.6e-15 past L. No outcome
  changes, but g09-reach-15 tests "past the confident reach", not the equality at exactly 15.
- The vertical detour is an inference. Neither rules.yaml nor the result schema gives the
  formula; "go over or under it at route height" does not say how far. If g09-vertical-run fails
  on `measured_ft` alone, check `route.detours[].extra_ft` against 5 before calling it a server
  error.

## Changes after the first run

First run: origin/t3/server 66d7ec8 through the solver shim, 10 of 27 passing
(`~/house-scanning-data/reports/e2e/20260926-032427-66d7ec89/report.json`). These were case
errors, corrected once `rules.yaml` was published:

- **Meter working space.** c5, g13a and g13b expected unsure over starts in (−3.833, 1.25), which
  `meter_working_space` fails. Their sweep assertions now expect that fail and assert unsure only
  outside it. The g13a spot bound moved from −0.506 to −1.25.
- **Ground coverage for pool and driveway.** Every "no photo request" case got
  `missing_evidence` asking for ground up to 10 ft beyond the spot, for `pool_clearance` (and
  `drive_clearance`, gas, AC and opening in g03 and g12b, where coverage stopped at the chain's
  ends). "Fully observed" now reaches 15 ft past each end and 15 ft out. The straight-wall helper
  applies this too, so g06, g08a, g10 and g12a gained coverage as well; their assertions are
  unchanged.
- **g01 layout.** The old spot right of the meter needed ground 10 ft to its left, which reached
  into the unseen stretch, so the photo request was correct. The garage moved to [−5.5, −1] and the
  unseen stretch to s < −9: no start between garage and meter survives the working space, and the
  spot's 10 ft pool area is observed.
- **Garage doors are not openings.** `openings.types` is `[door, window]`. g08a still holds through
  the working space and the route. Its `rules_assumed` no longer lists `opening`.

## Known server disagreement at 66d7ec8

- **g03, corner-crossing starts.** The sweep is one run, `{"start_ft": [-9.0, 7.416667],
  "outcome": "unsure"}`, and `stats.candidates` is 14. Starts in (−8.583, 7) cross a corner. They
  are not evaluated, yet the run covering them claims they are unsure. Golden 04 says they fail
  backing. The chosen spot itself is right: `[-8.583, -6.0]`, route 7.5.

## Goldens not encoded

- 02: its only assertion is the policy flag itself. Checking `policy.auto_approve` is false and no
  result is `pass` across all runs covers it.
- 04: the golden gives w1 outward [0, −1] for a baseline running +x, which contradicts the
  schema's clockwise rule. Its pad also relies on a ground check whose passing surfaces are not
  published. The flush rule it tests is exercised by g03 and g12b.
- 11 (d): its expectation is a pass, which `auto_approve: false` can't produce. Its photo-request
  half duplicates g01.
- 14: needs a pass. The result schema already requires every field it lists.
