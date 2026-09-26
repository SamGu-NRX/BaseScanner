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
- `rules_assumed` maps a check-id substring to the `threshold_ft` the case depends on: `gas` 3 ft
  (`clearances.gas_ft`) and `opening` 3 ft (`clearances.opening_ft`).

## The rules these cases depend on

From `rules.yaml` at 2c9348f:

- Battery 31/12 × 11/6 ft (W ≈ 2.5833, D ≈ 1.8333), matching the review's table.
- `meter_working_space` 2.5 ft wide, centred on the meter. A battery overlapping s = (−1.25, 1.25)
  fails, so starts in (−1.25 − W, 1.25) = (−3.833, 1.25) fail. The starts −3.833 and 1.25 only
  touch the space: gap 0 against threshold 0, which is unsure.
- `pool_ft` 10 and `drive_ft` 5, both placeholders. With no pool or driveway in the scene these
  checks pass only if the ground was seen 10 ft around the footprint. Otherwise they are unsure
  and ask for a photo.
- `openings.types` is `[door, window]`. A garage door is not an opening, so it has no 3 ft
  clearance. It does fail the route (`route.crossing.garage_door: fail`).
- `route.crossing.window: detour` and `gas_meter: detour`. `route.corner_allowance_ft` adds 0.5 ft
  per corner the cable turns.
- `facing.measured_from: battery_front`, `min_ft` 3: a 9 ft facing gap gives 9 − 11/6 ≈ 7.17.
- `ground.allowed` includes concrete.

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
| g01-unseen-beyond-garage | 01 | `missing_evidence` empty; starts in (−19.9, −8.2) fail with `route` | Wall s = [−20, 10], garage [−5.5, −1], nothing observed left of s = −9. A battery with right edge b < −1 needs a cable across the garage (b ≤ −5.5 means a ≤ −8.083). A battery with b > −1 overlaps the working space. So every start left of the meter fails. The first start right of the meter that clears the working space is 1.25, and pool needs ground from 1.25 − 10 = −8.75 ≥ −9. |
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
| c5-no-coverage | C5, scene schema | decision manual_review; `missing_evidence` non-empty; starts in (−6, −3.9) and (1.3, 7.4) unsure, starts in (−3.8, 1.2) fail with `meter_working_space` | Clean wall s = [−6, 10] with ground and facing data but no `coverage`. "Absent means nothing is known to be observed" makes every start unsure except where the working space, which needs no observation, fails it. Absent ends default to unexplored, which rules out reject. |

## Assumptions a failure should be checked against

- A battery must sit flush on one straight segment (review item 4, golden 04; the result's
  `spot.segment`). g03 and g12b use short segments to rule out starts, and g08b uses a 1.5 ft wall.
- Gas objects with a footprint are measured by footprint. In g10, g11a and g11b the strip's span
  covers the meter, which makes the cable detour; those cases assert only gas and photo requests.
  g13a keeps the span off the left routes.
- s counts the length of a no-wall stretch (g08b: w2 starts at s = 2, after a 1 ft gap).

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
- 07: needs headroom around `headroom.min_ft` 6.5, a placeholder. Now that the value is
  published this could be encoded; it isn't yet.
- 09: needs `confident_reach_ft` 15 and `max_route_ft` 20. `confident_reach_ft` is a placeholder
  but published, so this could also be encoded now.
- 11 (d): its expectation is a pass, which `auto_approve: false` can't produce. Its photo-request
  half duplicates g01.
- 14: needs a pass. The result schema already requires every field it lists.
