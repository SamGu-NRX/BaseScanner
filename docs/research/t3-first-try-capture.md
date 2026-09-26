# First-try capture: enough evidence before the homeowner leaves

[docs/05-live-guided-survey-hld.md](../05-live-guided-survey-hld.md) describes the live guided survey: automatic capture, the coverage display, next-view planning and recovery. This note fills in what the capture needs before the homeowner leaves: the evidence per check, the finish rule, a proposal to stop early, the close-up gates and the first trial.

The capture has enough when one candidate spot has a result for every placement check backed by saved keyframes, the meter and panel close-ups have passed their photo checks, and the server has acknowledged every upload. Anything the phone cannot settle stays UNSURE and goes to installer review with its reason. It never becomes a later photo request. This is a direction for lane A, not a hackathon promise.

## What counts as evidence, by check

Each check returns PASS, FAIL or UNSURE, as in [02-implementation-plan.md](../02-implementation-plan.md). PASS needs the deciding area in retained keyframes and a margin larger than the error. The error bars are team estimates, not measurements: ±0.3 ft for AR taps, ±0.5 ft for the LiDAR mesh, ±1.5 ft for photo detections. Freeze one set of `rules.yaml` values before capture.

| Check | Evidence that settles it | Threshold |
|---|---|---|
| Wall and footprint | Wall behind the whole 31 x 22 in footprint, seen from two positions | Base: within 1 ft of the wall |
| Ground | Surface and slope of the ground under and around the footprint | Chosen policy; Base's page gives a 3 by 3 ft area |
| Gates and paths | Gate swings and paths past the spot, with clear widths | Chosen policy |
| Nearby equipment | Footprint and service side of each nearby AC unit, battery or other equipment | Base: 3 ft from AC units and other batteries |
| Above the spot | Vents and wall boxes on the wall above the footprint | Chosen policy |
| Gas | Gas meter and pipes located; ground within the clearance of every footprint edge seen | `gas_clearance_ft`; Base's page says 3 ft |
| Driveway | Nearest boundary measured, plus retained views showing connected vehicle access, including around corners; unseen connections remain UNSURE | `drive_clearance_ft`, set by Base |
| Pool | Pool edge seen, or the area within the clearance seen empty | `pool_clearance_ft`, set by Base |
| Doors and windows | Position measured; whether it opens comes from the homeowner | `opening_clearance_ft`; IRC R328 says 3 ft |
| Facing gap | Nearest fence, hedge or wall across the full footprint width | `facing_gap_ft`, set by Base |
| Headroom | Lowest overhead object across the installation and its working space | `headroom_ft`, set by Base |
| Cable route | Continuous wall from meter to spot, no door or garage crossing | `max_route_ft`; Base: within 20 ft of the meter |
| Working space | Footprint outside the space in front of meter and panel | NEC 110.26: 30 in x 36 in x 6.5 ft |
| Disconnect, if the install uses one | Free wall space for the disconnect box | NEC 706.15: within sight, and within 10 ft or lockable |

This table summarizes what to capture. It is not the acceptance checklist: before capture, list every check the chosen policy applies. A check without evidence stays unsure and cannot count toward a pass.

A non-LiDAR phone has no mesh, so facing gap and headroom stay UNSURE. Hypothesis to test: taps on the wall and the facing fence at both footprint edges, raycast onto detected planes, bound the gap within ±0.3 ft.

Ask the homeowner only for facts a camera cannot establish: whether a window opens, whether they would move the bins, whether a street-facing spot is acceptable. Answers about hazards steer capture but never pass a check.

Proposed `scene.json` addition for lanes A to C: each check result lists its supporting keyframe IDs.

## Coverage tracker and finish rule

The tracker extends the coverage display in [docs/05 section 2](../05-live-guided-survey-hld.md#2-customer-journey) with a failed state and a strip showing the unrolled wall with the meter at zero, plus ground and overhead bands. Cells are 6 in wide, a display guess to try. Each cell is unseen, seen but not enough, enough, or failed. Tapping one shows the single view it needs. In AR, a fog on the wall clears where the camera has looked.

The fog is guidance, never proof that space is clear. A cell clears only from retained keyframes with normal tracking, from two positions. A non-LiDAR phone still cannot tell that a bin hid the ground behind it; the server's checks decide.

**Finish** unlocks when all four hold:

1. One candidate passes every placement check with linked keyframes, or the homeowner has reached both walkable limits and each unknown is recorded for installer review.
2. Both close-ups passed their gates, or the homeowner chose "Can't get a clear shot".
3. The server acknowledged every upload. Saved offline is not finished.
4. For the hackathon, a teammate acting as Base's reviewer has checked the packet while the homeowner is still outside.

## Early stop

This is a proposal the team has not approved. A2 in [01-feature-map.md](../01-feature-map.md) requires walking to both wall ends, and [docs/05 section 7](../05-live-guided-survey-hld.md#7-deterministic-criteria-evaluation) keeps that gate until the team approves a tested completion rule. The proposal: one fully evidenced candidate ends the walk. Two limits apply:

- Evidence can extend past the candidate. A gas meter 2 ft beyond the footprint still needs its surrounding ground seen.
- Proving the shortest route is optional. If the other side of the meter is unseen out to the same distance, the result says "A closer spot may exist on the left".

With no candidate on the meter wall, continue to reachable adjacent walls when more placement evidence is needed. Unseen alternatives remain unknown. This capture checklist does not define installation eligibility or authorize a site-level rejection.

## Close-up gates

- **Meter label.** Run Vision's `RecognizeTextRequest` with `recognitionLevel` accurate and `usesLanguageCorrection` off. Require the text inside the reticle, all label edges in frame, and matching reads from two frames. OCR confidence cannot say which of the meter's numbers is the meter number; the server decides.
- **Blur.** Laplacian variance on the label crop, not the whole frame.
- **Glare.** Reject when near-white pixels cover any recognized character's box.
- **Panel.** Three shots: panel and surrounding wall, breakers with the door open, main breaker rating up close.

All cutoffs are hypotheses to tune. After two failed tries, "Can't get a clear shot" sends that check to installer review instead of looping.

## What the homeowner sees

1. A text with a link. The hackathon build opens the development app.
2. Camera permission, then "Go to your electric meter" and **I'm here**.
3. The meter close-up. The shutter fires itself when the gates pass.
4. "Tap the meter." A raycast onto a detected wall plane sets the anchor. With no plane, it asks them to step closer; it never guesses a depth.
5. "If there's room, step back until the whole meter box and the ground below it are in view."
6. The walk with strip and fog. One question at a time, two large buttons.
7. The early stop, then the panel while the wall uploads.
8. Corrections on saved frames. The homeowner marks a missed object in a saved keyframe. Its pixel and stored pose define a ray, placed on a validated wall plane only for an object on that wall. Otherwise its position stays UNSURE.
9. The reveal at the meter: a box on the meter's anchor and a cable line, with clearances as numbers on tap.

Opening the panel:

> Open the panel's hinged door. Don't unscrew or remove the metal cover behind it, and don't touch the breakers. If the door is locked or stuck, tap **Skip**.

Borderline reveal:

> This spot is 3 ft 2 in from the gas meter. The rule is 3 ft and our measurement can be off by about 4 in, so an installer will check it. The panel still needs an electrician's review.

## Recovery

These add to the operational cases in [docs/05 section 9](../05-live-guided-survey-hld.md#9-reliability-latency-and-data-handling).

- **Tracking drops.** Coverage credit stops and the prompt changes, with no modal: "Slow down" for `excessiveMotion`, "Aim at a corner or somewhere with more texture" for `insufficientFeatures`.
- **Interruptions.** Keyframes and close-ups go to disk after each step. On return, `sessionShouldAttemptRelocalization(_:)` returns true and the app shows a saved meter view: "Point at the meter like this."
- **Failed relocalization.** Start a new coordinate frame: re-tap the meter and re-walk. One matching point does not fix heading, and a 5 degree heading error moves a point 20 ft away by about 1.7 ft.
- **Uploads.** Foreground only, resumed on return, never restarted.

## First trial

Run one manually guided end-to-end capture on a non-LiDAR iPhone, with the operator keeping the evidence checklist by hand. First, a second person lists every hazard and tape-measures each deciding clearance. Stage four cases:

1. A clear candidate. Expected: without validated measurements, facing gap and headroom stay UNSURE and go to installer review, so the spot cannot fully pass.
2. A candidate whose ground is hidden behind a bin. Expected: a view request during the walk, or UNSURE.
3. A gap within the error bar of its threshold. Expected: UNSURE, installer review.
4. An electrical label made unreadable by tape or glare. Expected: the gate refuses it, then installer review after two tries.

Fail the trial if any PASS contradicts the independent measurements or hazard inventory, or if a packet is marked evidence-complete while a required view, readable label or measurement is missing. Record evidence-complete, review-pending and installer-assessment outcomes separately, along with unresolved capture needs. Also record walk time, retakes, questions asked and wall length walked.
