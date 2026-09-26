# UX review of every app state

Each state of the HouseScan app judged against [checklist.md](checklist.md). Screenshots and
audit reports stay in `~/house-scanning-data/reports/` (replay frames are non-commercial data).

## Evidence

| Run | What it shows |
| --- | --- |
| `sim/20260926-051323-t3-ios-mvf-24af4342-replay` | Every state at `t3/ios-mvf` `24af434` with the real server's result |
| `sim/20260926-052535-t3-ios-mvf-525ea401-replay` | Every state at `525ea40`, the current head, with the real server's result and the end question answered |
| `a11y/20260926-052756-t3-ios-mvf-525ea401-head-sample` | Apple's audit at `525ea40` on 21 screens, including the end question and the sample wording |
| `a11y/20260926-051535-t3-ios-mvf-24af4342-head-sample` | Apple's audit at `24af434` on 17 screens; the gap loop closes on the replay |
| `sim/20260926-050058-t3-ios-mvf-0876e03c-replay` | Every state at `0876e03` |
| `sim/20260926-043152-5520229-5520229d-preview-sample` | Every state of the flow, default text size, light appearance, sample result |
| `sim/20260926-044328-5520229-5520229d-preview-ax5-dark` | The same at the largest accessibility text size (AX5), dark appearance |
| `sim/20260926-044527-5520229-5520229d-preview-unsupported` | The unsupported-phone screen |
| `a11y/20260926-044005-5520229-5520229d-preview-sample` | Apple's accessibility audit on 17 distinct screens, with every label |
| Source at `0876e03` | Items that need the live camera |

`5520229` is `t3/ios-mvf` `90c01dd` merged with the UI lane `e5dde35`; `0876e03` is the same UI
merged by S3, plus the fixes listed under "Fixed since the preview". The Simulator cannot run
ARKit, so tracking loss, relocalization and the live meter tap are judged from source.

## Verdict: Block

Blockers that fail: R9 (camera access denied leads nowhere, [B-03](../product/bug-triage.md#blockers)),
T5 (the close-up's way out can fail to appear, B-04) and R1 (a stretch the homeowner can't reach
is not recorded, B-08). The feature list's "Add something" doing nothing (B-09) blocks adding a
missed feature.

## By state

| State | Result | Findings |
| --- | --- | --- |
| `onboarding` | Pass at default size: one message, one primary button, "About 2 min". At AX5 the pill reads "About 2 mi" and the body runs under the page dots. | UX-01 |
| `unsupported` | Pass: "This phone can't measure walls" with what to do instead. Camera denied never reaches this screen. | B-03 |
| `findMeter` | Pass at default size: one instruction, the reticle, "This is my meter". At AX5 the button is pushed partly off screen. Refusal wording ("Step a little closer to the wall") also covers tracking refusals. | UX-01, B-11 |
| `meterCloseUp` | Pass: one instruction, no shutter, a named fix ("Center the meter in the circle"). The problem pill fails contrast; the way out can fail to appear. | UX-03, B-04 |
| `wallWalk` | One instruction with its reply inside the card, as the checklist asks. The strip's states differ by colour alone, the counter fails contrast, and at AX5 the card covers most of the camera and pushes "Mark something" and the strip off screen. At `525ea40` a marked end is followed by "What's at the left end?", so its kind is truthful, but an end closer than 20 ft still can't be marked. | UX-01, UX-02, UX-03, UX-05, UX-08, B-06 |
| `markFeatures` | Pass at default size: clear list, remove buttons labelled, window question with two full-width answers. At AX5 the list is hidden behind "Looks complete". "Add something" does nothing. | UX-01, B-09 |
| `gapRequest` | Pass: one line with the reason and target, a progress bar, "I can't get there". The requested stretch reuses the amber that means "seen". | UX-05, UX-06, B-08 |
| `uploading` | Pass: progress in its own steps, apart from coverage (R7); with no server it says "Making a sample result" (`525ea40`). Four text elements do not scale. A failure shows raw error text. | UX-04, B-02 |
| `result` | Pass on honesty: "An installer will take a look", the rules-not-final note, the unseen side disclosed, the borderline window check with measurement, rule and error, and "An installer will check this". A maximum reads like a minimum; the first load leaves the upload screen up for over 1.2 s. | B-14, UX-07 |
| `resultAR` | Pass: the spot and cable over the camera with one headline and "Done". The headline says "The spot an installer will check" unless the result is an approved pass, and "Example spot, not your result" for a sample (seen at `525ea40`). | none |

Checks that passed across the flow: one primary instruction per camera screen (I1); plain words,
no jargon in any on-screen string (I3); no shutter where capture is automatic (I5); every control
has a spoken name (A1, from the audit's labels); no hit area below 44 pt (A6, audit).

## Findings

**UX-01. Major. Large text breaks the camera screens and the feature list (A4).** At AX5:
"This is my meter" is pushed partly off screen; the feature list shows its heading and "Looks
complete" but not the marked features or the window question; on the walk and a gap request the
instruction card covers most of the camera, and "Mark something", "I can't get there" and the strip
fall off screen; onboarding's "About 2 min" truncates to "About 2 mi". Seen on the preview; the
only layout change at `0876e03` stacks the window answers, which makes the list taller. The audit flags clipped text
on the close-up and walk cards. Suggested: cap the instruction card's type at a large size with
the rest scrollable, keep the primary button pinned above the home indicator, and let the list
scroll behind a pinned "Looks complete".

**UX-02. Major. Coverage is shown by colour alone (A9).** Covered cells are green and seen cells
amber; in grayscale both are the same light gray, and the strip has no legend or row labels. A
homeowner with red-green colour blindness cannot tell done from not done. Suggested: a pattern or
height difference per state, and "Wall" and "Ground" row labels.

**UX-03. Minor. Contrast over the camera (A5).** The audit fails contrast on the photo counter
during the walk, the close-up's problem pill and, at `24af434`, the walk's "Can't get there"
reply. Failures it reported on text mid-transition (the upload steps, the result headline as it
fades in) are left out.

**UX-04. Minor. Text that does not scale (A4).** The audit reports elements whose font size cannot
change on the upload screen (four) and, at `525ea40`, on the close-up (four) and the walk (two).

**UX-05. Minor. Two names for one action (V8).** The walk's reply is "Can't get there"; the gap
request's is "I can't get there".

**UX-06. Minor. One colour, two meanings.** The requested stretch is outlined in the amber that
marks "seen but not enough" cells on the same strip.

**UX-07. Minor. The result appears late the first time.** On the first visit the upload screen
("Checking your wall") was still showing 1.2 s after the app logged the result; after returning
from AR the result appeared at once. The 3D model's first load is the likely cause.

**UX-08. Minor. Text VoiceOver cannot read (A2).** At `525ea40` the audit flags text on the walk
that is drawn rather than exposed to accessibility, probably labels drawn into the camera overlay
or the strip.

## Fixed since the preview (`0876e03`)

Seen: the window question answers "It opens" and "It stays shut", stacked (I4), and the result
says the electrical panel still needs an electrician's review (H7). From source: tracking coaching says
"Slow down" and "Aim at a corner or somewhere with more texture" (T1). While relocalizing, the
saved meter photo shows with "Point at the meter like this." (T7). Overlays hide while tracking is
not normal (T3).
