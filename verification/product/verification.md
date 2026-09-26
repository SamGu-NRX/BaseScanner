# Checks against the running app

Each row is one claim from a document, checked in the Simulator. A failed row is not automatically
an app bug: sometimes the document is wrong, and the note says which. Screenshots stay in
`~/house-scanning-data/reports/sim/` because replay frames come from a non-commercial dataset.

## How a pass is run

`make sim-app` from `verification/` builds `t3/ios-mvf`, runs it on the ADVIO replay
`advio-20-0040-0075` with the autopilot, and uploads to the server started from `t3/server`. Add
`ARGS="--extra-arg=-sampleResult"` for the built-in result, or `--content-size
accessibility-extra-extra-extra-large --appearance dark` for large text. `python -m
hsverify.a11yaudit` runs Apple's audit on every screen. What these cover: the order of screens,
what each shows and speaks, what the app logged, and what the server answered. What they do not
cover: anything needing the live camera (tracking, the meter tap on a real wall, a close-up that
succeeds), haptics, or timing a person feels.

## Current pass: `t3/ios-mvf` `525ea40`, server `26d2870`

Report `sim/20260926-052535-t3-ios-mvf-525ea401-replay` (real server), the audit at `24af434` and
`525ea40` (sample result), plus the variant runs on the preview
`5520229` (the same UI before S3's last fixes) named in [the UX review](../ux/review.md#evidence).

| ID | Claim | Result |
| --- | --- | --- |
| FLOW-01 | Screens appear in the order of [the flow](foundations/flow.md#the-interaction-event-by-event) | Pass: all ten, onboarding to result, AR and back. |
| FLOW-02 | The result appears only after the server answered | Pass: `POST /v1/placements 200`, then `result`. |
| FLOW-03 | A failure other than an unsupported phone reaches the failure screen | Fail, as the document predicts: `-replay /nonexistent` logs "replay unreadable" and stays on onboarding ([B-03](bug-triage.md#blockers)). |
| FLOW-04 | An unsupported phone sees "This phone can't measure walls" | Pass (no replay, Simulator). |
| CU-01 | Without a usable photo, the close-up is skipped after the second failed try | Pass on the replay: logged "close-up skipped after 2 failed attempts". |
| CU-02 | One instruction and one named fix under it | Pass: "Hold your meter in the circle", "Center the meter in the circle". |
| WW-01 | One instruction, the reply inside the card, the strip below | Pass at default size; fails at the largest text size (UX-01). |
| WW-02 | Guidance moves from walking to tilting to stepping back | Pass: the audit saw "Walk slowly to your left", "Tilt down to show the ground", "Take a step back". |
| MF-01 | The list shows each mark with its distance, the window question and "Add something" | Pass at default size; hidden behind "Looks complete" at the largest text size (UX-01). |
| GAP-01 | A gap request states what to show and why, with a progress bar and "I can't get there" | Pass ("Show the ground around your meter", "0%"). |
| GAP-02 | New photos close the request and the flow moves on | Pass: logged "gap 1 satisfied"; the audit saw "Got it, thanks" / "That's the view we needed." |
| WW-03 | After "Wall ends here" the walk asks what is at that end, and a corner stays unexplored | Pass: logged "end left at s=-3.81 (unexplored)", then "answered the left end: turns a corner"; same on the right. |
| UP-01 | Upload progress is shown in steps apart from coverage | Pass: "Photos ready", "Sending photos, 99%", "Check clearances". |
| RES-01 | The result shows the headline, placement line, the server's summary, the rules-not-final note and the panel notice | Pass: "An installer will take a look" with the server's placement and summary (seen at `0876e03`, `24af434` and `525ea40`). |
| RES-02 | A borderline check shows the measurement, the rule and the error | Pass on the sample result: "Measured 3 ft 1 in. The rule is 3 ft, and the measurement can be off by about 4 in." |
| RES-03 | A maximum reads as a maximum | Fail: "Measured 3 ft. The rule is 20 ft" (B-14). |
| RES-04 | The result is visible when the app logs `STATE=result` | Fail, minor: the upload screen was still showing 1.2 s later on first load, in both passes (UX-07). |
| AR-01 | The AR view draws the spot and cable with one headline and "Done" | Pass: "The spot an installer will check" for a manual review (`24af434`). |

Superseded: at `21a63e7` the upload went to `/v1/scenes` and failed with 404, and the camera
screens rendered without text. Both are fixed on `t3/ios-mvf`.
