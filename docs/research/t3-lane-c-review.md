# Lane C: what the solver spec must settle before it approves or rejects

The [docs/02 Lane C solver][c] can't yet approve or reject a site safely. Twelve gaps block it, ranked by how many decisions each can flip. The 14 golden tests below check that each gap is closed. Thresholds appear as `rules.yaml` parameters.

## What the spec must settle

1. **Select one complete policy.** The public rules table leaves installation requirements unresolved. Require an approved, versioned configuration before enabling automatic approval. [Lane C][c] has one decision function. Record the policy ID and version in the [rules table][r]. Until a policy is selected, the solver must not approve automatically.
2. **Define error propagation.** [Lane C][c] has a strict PASS margin but no FAIL or equality rule, and it doesn't separate a missing measurement from a measured zero. Two ±0.3 ft taps give a gap with ±0.6 ft error. Proposed, pending Base: for a minimum clearance T and a measured gap d ± e, PASS if d − e > T, FAIL if d + e < T, else UNSURE. Reverse both inequalities for maximum lengths. The docs/02 error sizes are guesses until the D3 tape-measure test checks them.
3. **Define what a reject must have seen.** [Lane C][c] rejects once both wall ends are tapped, but a tapped corner or a closed gate doesn't end the search. Record the observed wall, ground and route intervals, and the type of each end. Reject only when coverage is complete and every candidate region has a clear FAIL.
4. **Store wall geometry.** The [`scene.json` schema][s] doesn't store segment order, outward normals, ground elevations or the meter-anchor transform, although docs/02 describes some of them in prose. The [Lane C][c] sweep also lets a footprint cross a corner. Require each rigid footprint to sit flush on one straight wall segment.
5. **Keep ground-object shapes.** Lane B snaps ground objects to the nearest wall point. [Lane C][c] then can't see that two objects far apart in s sit close together around an inside corner. Keep a ground polygon for every part of an object, such as a gas meter and its regulator, and measure from the whole footprint.
6. **Measure the routed length.** [Lane C][c] uses |s| plus a corner allowance. For a spot left of the meter, s is the far edge of the footprint, and the formula ignores vertical runs and detours. Sum the supported route polyline and carry its error.
7. **Complete the route rules.** The [Lane C][c] route blocks only doors, garages and stretches with no wall, and the pseudocode never feeds `route` into the decision. Store route support, blockers and visibility, apply the selected policy's crossing rules, and treat a hidden stretch that decides the result as UNSURE.
8. **Model openings and access as shapes.** [Lane C][c] checks openings as overlap between wall intervals. That can't express a door or gate swing area, or the working space in front of equipment (NEC 110.26). Keep the attributes each opening rule needs, such as `operable` and `well`. An unknown attribute is UNSURE, never false.
9. **Check facing gap and headroom everywhere.** Lane B samples passage width at 1.5 ft height and headroom 1 ft out from the wall every 2 inches, using a small fan of rays. That sampling does not establish clearance over the whole footprint and working area. Take the conservative minimum over the whole checked region and record which parts were observed. The rules must also say whether the facing threshold counts from the wall or from the battery's front face.
10. **Give ground its meaning.** The ground `type` in the [schema][s] records surface material only. It can't express whether a vehicle can reach the surface (feature B6), the slope, the height above grade or the separation from a pool. An empty pool list doesn't prove there is no pool. If the capture didn't cover the area, the pool check is UNSURE.
11. **Don't reject from samples.** The [Lane C][c] loop stops before its last start, `s_max - W`, and a legal start interval narrower than 2 in can fall between samples. Add segment ends and constraint boundaries as candidates, and confirm infeasibility over continuous intervals before rejecting.
12. **Specify the result record.** C5 in the [feature map][f] lists a verdict, reasons and photos still needed. An audit also needs the policy and version, the footprint relative to the meter anchor, each check's measured value, error and verdict, the route polyline and its length and error, and how scale was set. A reject also needs both wall ends and the reason each region fails. Keep the photo request separate from the verdict. UNSURE has two causes: a measured gap inside its error band, and an area nobody observed. More photos fix only the second.

## Golden tests

Every expected result below follows from geometry, logic, measurement error or the public sources. Further policy-specific cases live in the team's private notes.

| Parameter | Value | Source |
| --- | --- | --- |
| battery footprint | 31/12 × 11/6 ft; test 12 uses a 2 ft wide test battery | Base Core 30.68 × 22 in, rounded to 31 in as in C2 |
| `gas_clearance_ft` | 3 ft | Base help page |
| `opening_clearance_ft` | 3 ft, added to both sides of an opening as in docs/02 | IRC R328 |
| `headroom_ft` | TBD with Base | NEC 110.26 gives 6.5 ft for working space at the meter and panel |
| `confident_reach_ft`, `max_route_ft` | TBD with Base; tests need `max_route_ft` > `confident_reach_ft` + 1 | Base help page: within 20 ft of the meter |

**Shared fixture.** These are test settings, not Base policy. Units are feet, and geometry is exact unless a test gives an error. Wall w1 is straight, with s = x, the meter at 0 and outward +z. The only usable pad is level ground at s = [6, 9]. Every other location fails a fixed ground check. Both wall ends are observed, the facing gap and headroom are 9, and the supported route to the nearest battery edge is 6. Every check that a test doesn't name passes. Footprint containment is inclusive. Tests 09, 10 and 12 rely on the margin rule in item 2.

**01. A fully observed spot passes without unrelated views.** Setup: the wall beyond a garage opening on the far side of the meter is unseen. Expected: pass at s = [6, 103/12], z = [0, 11/6], route 6, no photo request.

**02. No selected policy, no automatic approval.** Setup: shared fixture with no policy selected. Expected: manual review naming policy selection as the reason, never pass.

**03. Negative s uses the near edge.** Setup: pads [−9, −6] and [7, 10]. Expected: pass at [−103/12, −6] with route 6, chosen over [7, 115/12] with route 7. Using |−103/12| as the left route length is wrong.

**04. A corner allows an adjacent wall, not a bent battery.** Setup: w1 runs from [−12, 0] to [4, 0] with outward normal [0, −1] and the meter at [0, 0]. w2 runs from [4, 0] to [4, 12] with outward normal [1, 0], and s = 4 + z. Only the w2 pad at z = [2, 5] works, with route 6. Candidate s = [3, 67/12] crosses the corner at s = 4. Expected: pass on w2 at z = [2, 55/12], x = [4, 35/6]. The corner candidate must FAIL backing and footprint support, and its failure must not invalidate the valid w2 spot.

**05. Inside-corner gas distance is Euclidean.** Setup: w1 runs along z = 0 from x = −6 to 4, outward +z, with the meter at x = −6. A return wall runs along x = 4, outward −x. The only pad is x = [0, 3]. A gas meter sits at [4, 4]. Expected: reject. From the footprint at x = [0, 31/12], the distance is √((17/12)² + (13/6)²) ≈ 2.589, below `gas_clearance_ft`, and later starts are closer. The unrolled distance of 65/12 ≈ 5.417 must not produce a pass.

**06. Every part of an object counts.** Setup: the gas meter body is 10 from the wall, but its regulator reaches x = 7, z = 23/6. Every start on the pad covers x = 7. Expected: reject. The regulator is 2 from the footprint's front edge. Measuring from the wall or from the meter body's center is wrong.

**07. Headroom covers the whole footprint.** Setup: the ray 1 ft out from the wall reads 9. A landing spans the whole pad over z = [1.5, 2.5], so it covers the footprint's front strip, with its underside at `headroom_ft` − 1 ± 0.5. Variants: underside at `headroom_ft` + 0.7 ± 0.5, at `headroom_ft` + 0.3 ± 0.5, and unobserved. Expected: reject; pass; manual review; manual review.

**08. The route decides the result.** Setup: the only pad is [10, 13], and every other check passes there. A garage opening spans s = [3, 7]. In a second variant, a stretch with no wall spans s = [3, 4] instead. Expected: reject in both variants, because the route FAILs for every candidate. No route may interpolate across the missing wall.

**09. Reach uses routed length.** Setup: the only pad starts L along a straight supported wall, so the route is L. Variants: L = `confident_reach_ft` − 1, + 0 and + 1; L = `max_route_ft` + 0 and + 1; L = `max_route_ft` + 0.2 ± 0.3 and + 0.4 ± 0.3. Then a pad `confident_reach_ft` − 4 along the wall whose route needs 5 of vertical run. Expected: pass, manual review, manual review; manual review, reject; manual review, reject; manual review, because the routed length is `confident_reach_ft` + 1.

**10. Margins cover equality and compound error.** Setup: T = `gas_clearance_ft`, and every start has the same gas gap d. For each e in {0.3, 0.5, 1.5}, test d = T + e + 0.01, T + e, T − e and T − e − 0.01. Then derive d = T + 0.5 from two positions that each carry ±0.3. Expected: pass; manual review; manual review; reject. The derived gap is manual review, because its error is ±0.6. A recognition confidence score is not a distance error.

**11. A reject needs the real wall ends and no hidden alternative.** Setup: every candidate on w1 fails gas clearance by a clear margin. The left end is observed, and at s = 12 w1 turns onto an adjacent wall. Variants: (a) only the corner is tapped and the adjacent wall is unseen; (b) the adjacent wall is observed to its real end and every candidate there fails; (c) as b, but a closed gate hides part of the ground; (d) as c, plus a fully observed valid pad and route before the gate. Expected: (a) manual review requesting the adjacent wall past the corner; (b) reject, recording both wall ends and no footprint; (c) manual review requesting the area behind the gate; (d) pass at the valid pad with no photo request.

**12. Sub-grid intervals and the last start count.** Setup: 2 ft test battery, `opening_clearance_ft` = 3, windows at s = [3, 4] and [12.1, 13.1]. Replace the shared ground fixture: the space between these windows is usable ground, and all other ground is unusable. All non-opening checks pass there. Starts in (7, 7.1) are the only legal ones, and the 2 in grid from s = 0 samples 7 and 43/6 but nothing strictly between 7 and 7.1. A second fixture, independent of both the shared fixture and the one above, has one support interval [6, 8] with a 2 ft battery and every other check set to PASS. Expected: pass with a start in (7, 7.1), such as [7.05, 9.05]; a grid-only manual review is wrong. In the second fixture, start 6 is enumerated, not skipped.

**13. An UNSURE spot never outranks a pass.** Setup: pad F has route 6 and a gas gap of `gas_clearance_ft` + 0.2 ± 0.3. Pad S has route 10 and passes every check. Then F alone. Expected: pass at S with route 10. With F alone: manual review with no photo request, because F is fully observed and only its margin is uncertain.

**14. The result records its measurements.** Setup: shared fixture. Expected: pass, recording the policy and version, the footprint relative to the meter anchor, route 6 with its error, and each check's measured value, error and verdict, including facing gap 9 and headroom 9. The photo request is empty.

[c]: ../02-implementation-plan.md#lane-c-placement-code-solverpy
[r]: ../01-feature-map.md#rules-table-c1-confirm-these
[s]: ../01-feature-map.md#hour-1-agree-on-the-data-format-everyone
[f]: ../01-feature-map.md#c-rules--placement-code
