# HouseScan capture app: UX review checklist

A reviewer uses this list to judge each screen state of the iOS capture app from three kinds of evidence. The first is Simulator screenshots. The second is the ordered `STATE=<name>` log from contract C4. The third is the SwiftUI source. The product priority is a first-time homeowner finishing the scan on the first try, with a result that doesn't overstate what the phone saw.

## How to use it

1. Collect evidence for each state in the per-state table at the end. For each state, take a screenshot at the default text size and a second one at the largest accessibility text size (AX5, `accessibilityExtraExtraExtraLarge`). Also capture the `STATE=` log for the whole run and the Accessibility Inspector readout of each screen.
2. For each item, record **Pass**, **Fail** or **Not verified**, with the evidence file or `path:line`. Mark anything you could not observe as Not verified. Never infer a Pass.
3. The verdict is **Block** if any blocker fails, **Incomplete** if any blocker is Not verified, and **Approve** otherwise. List major and minor failures as work to do.

Severity: **blocker** means the homeowner can't finish or gets a wrong result. **Major** means likely confusion or retakes. **Minor** means polish.

Observed by: `SS` screenshot, `SEQ` STATE log order, `SRC` SwiftUI source, `VO` VoiceOver or Accessibility Inspector, `DT` Dynamic Type run at AX5, `RM` Reduce Motion run, `GRAY` screenshot converted to grayscale.

The Simulator cannot run ARKit world tracking. Screens that depend on it (walk, fog, tracking loss, relocalization, reveal) can be screenshotted only if the app has a preview or fixture mode that injects those states. Without one, check those items from `SRC` and mark the runtime part Not verified.

Sources: `HLD` is `docs/05-live-guided-survey-hld.md`. `FTC` is `docs/research/t3-first-try-capture.md` on `origin/t3/research`. Skill names refer to the design and accessibility skills the checklist draws on.

Numeric limits marked *(reviewer threshold)* are review conventions. No user testing backs them.

## R. First-try reliability

| ID | Check | Observed by | Pass when | Sev | Source |
|---|---|---|---|---|---|
| R1 | The walk can't end with a silent gap | SEQ, SS | Every strip cell on the last screen before the upload or finish state is green, marked "can't access", or listed by name as open for installer review | blocker | FTC finish rule; HLD §2 |
| R2 | Missing coverage never shows as done | SRC, SS | The cell-to-style mapping has one explicit case per state (unseen, seen but not enough, enough, failed, skipped) with no `default:` that falls through to green. Any progress count counts only green cells | blocker | HLD §2 coverage display |
| R3 | Tracking loss stops coverage credit | SRC, SS | Code that clears fog or marks cells runs only when `trackingState == .normal`. The strip in the tracking-lost screenshot is unchanged from the screenshot before it | blocker | HLD §9 tracking row; FTC recovery |
| R4 | An interruption resumes the walk | SEQ, SS | Backgrounding mid-walk logs walk, then a relocalizing state, then walk again (or tap meter). It never returns to onboarding, and the captured count and strip survive | blocker | FTC recovery; HLD §9 session resumed |
| R5 | Failed relocalization starts a new frame | SEQ, SRC | After relocalization fails, the app asks to tap the meter again and resets the strip's spatial cells. It doesn't keep drawing old world-anchored overlays | blocker | FTC failed relocalization |
| R6 | Finish waits for server acknowledgment | SEQ, SS | Finish or reveal is reachable only after every upload is acknowledged. Offline, the screen says the scan is saved on the phone and not yet sent, and it doesn't say done | blocker | FTC finish rule 3 |
| R7 | Upload progress is separate from evidence completeness | SS | Upload status is its own element with its own wording (for example "3 photos waiting to send"), placed apart from the coverage strip, and it never changes a strip cell | major | HLD §2, §9 |
| R8 | Offline keeps local guidance running | SS | Offline screenshots still show the instruction and strip. Findings that need the server are labelled pending, not pass or fail | major | HLD §9 connectivity row |
| R9 | Camera denied has a way forward | SEQ, SS | A `cameraAccessDenied` state explains in one sentence why the camera is needed and has an "Open Settings" button that opens the app's Settings page | blocker | HLD §2 device check |
| R10 | AR unavailable is explained | SEQ, SS | On a device without world tracking, the app shows a plain explanation and what to do next. There's no black camera view, spinner loop or crash | blocker | HLD §2 device check |
| R11 | Each auto-capture is acknowledged | SS, SRC | Each saved capture triggers a brief visual mark, such as a flash on the reticle or a counter tick, and the capture count goes up | major | HLD §2 |

## I. One clear instruction per screen

| ID | Check | Observed by | Pass when | Sev | Source |
|---|---|---|---|---|---|
| I1 | One primary instruction | SS | The largest text is a single instruction sentence. Any other text is visibly smaller and isn't a second command | major | HLD §2; holistic-ux cognitive load |
| I2 | Standing and aiming cues are distinct | SS, SRC | The where-to-stand cue (a ground marker or "step back" text) and the where-to-aim cue (the reticle or target) differ in shape and position. Neither is a recolored copy of the other | major | HLD §2 |
| I3 | Plain words | SRC | A grep of user-visible strings finds none of: raycast, plane, keyframe, anchor, tracking, LiDAR, epoch, relocaliz, OCR, UNSURE, PASS, FAIL | major | frontend-design writing; apple-design simplicity |
| I4 | One question at a time with two large buttons | SS | A question screen shows exactly one question and two full-width buttons, each at least 44 pt tall. Button labels state the answer ("It opens", "It stays shut"), not Yes and No | major | FTC what the homeowner sees 6 |
| I5 | No shutter where auto-capture applies | SS, SRC | The meter close-up, panel shots and walk have no shutter button. Tapping to set the meter anchor is allowed, because that tap marks a location rather than taking a photo | major | HLD §2; FTC 3 |
| I6 | The instruction stays stable | SEQ | The log never shows an A, B, A change of instruction within 3 s unless a task was completed *(reviewer threshold)* | major | HLD §4 next-view planning |
| I7 | No arrow through unseen ground | SS | Guidance toward an unobserved area is text ("Walk around the corner if you can"), not a world-anchored arrow | major | HLD §4 |
| I8 | Anchoring never guesses a depth | SEQ, SS | Tapping the meter with no detected wall plane shows "step closer" and doesn't advance to the step-back state | blocker | FTC 4 |
| I9 | Panel instructions include the safety wording | SS | The panel screen says to open only the hinged door, not to unscrew the cover and not to touch the breakers, and offers Skip | blocker | FTC opening the panel |
| I10 | Recapture requests give a reason and a target | SS | The request is one line naming what to show and where, for example "Show the ground below this part of the wall" | major | HLD §4 capture request |

## T. Recovery from tracking loss and gaps

| ID | Check | Observed by | Pass when | Sev | Source |
|---|---|---|---|---|---|
| T1 | Tracking-loss wording matches the cause | SRC, SS | `excessiveMotion` shows "Slow down". `insufficientFeatures` shows "Aim at a corner or somewhere with more texture". These are separate `case` branches with separate strings | major | FTC recovery |
| T2 | No modal on tracking loss | SRC, SS | No `.alert`, `.sheet` or `.fullScreenCover` is bound to tracking state, and the camera stays visible behind the prompt | major | FTC recovery |
| T3 | World-anchored overlays are hidden while tracking is limited | SRC, SS | Arrows, the fog and the candidate box hide or freeze when tracking isn't `.normal`, and they come back only after it returns | major | HLD §9 tracking row |
| T4 | "I can't access this area" is available | SS | The button is on the walk and gap-request screens and takes one tap. Afterwards the cell shows a distinct skipped mark (not green) and the next task starts | major | HLD §2 |
| T5 | "Can't get a clear shot" appears after two tries | SEQ, SS | The option appears after the second failed close-up attempt, not earlier and never absent. Choosing it moves on and doesn't loop | blocker | FTC close-up gates |
| T6 | Close-up failures name the fix | SS, SRC | Blur, glare and a cut-off label each have their own message saying what to do (hold still, tilt away from the glare, fit the whole label in the box) | major | HLD §9 blur row |
| T7 | Relocalization shows the saved meter view | SS | The screen shows the saved meter image and "Point at the meter like this." | major | FTC recovery |

## H. Result reveal honesty

| ID | Check | Observed by | Pass when | Sev | Source |
|---|---|---|---|---|---|
| H1 | UNSURE reads as needing review, with a reason | SS, SRC | Each unsure check shows "An installer will check this" plus a one-line reason. Its style is distinct from pass, and it's never hidden or folded into a pass | blocker | FTC intro; HLD §7 |
| H2 | Borderline numbers show the error | SS | A result near its limit shows the measured value, the rule and the error, as in FTC's example ("3 ft 2 in ... rule is 3 ft ... off by about 4 in") | blocker | FTC borderline reveal |
| H3 | Green coverage doesn't imply a pass | SS | The screen shown when coverage is complete uses no approval words ("approved", "all set", "you qualify"). The verdict appears only on the reveal, in wording separate from coverage | blocker | HLD §2 green row |
| H4 | The reveal is anchored to the meter | SRC, SS | The candidate box and cable line are placed relative to the meter's anchor, and they hide with an explanation if tracking isn't normal at reveal | major | AGENTS.md hard rules; FTC 9 |
| H5 | A failure isn't a dead end | SS | A failed spot names the rule and distance, then shows another candidate or says an installer will look for one | major | holistic-ux peak-end |
| H6 | An unseen side is disclosed | SS | If the other side of the meter wasn't seen, the reveal says so ("A closer spot may exist on the left") | minor | FTC early stop |
| H7 | The panel review needs are stated | SS | The reveal says the panel still needs an electrician's review whenever the server marks it that way | major | FTC borderline reveal |

## A. Accessibility

| ID | Check | Observed by | Pass when | Sev | Source |
|---|---|---|---|---|---|
| A1 | Every control has a label | VO, SRC | The inspector reads a name for every button. Each icon-only `Button { Image(systemName:) }` has `.accessibilityLabel`. A primary action without one is a blocker | blocker | better-accessibility names |
| A2 | The AR overlay state is exposed | VO | One element summarises coverage in words ("Wall: 4 of 10 sections done, 2 need another look") and the tracking status | major | better-accessibility; HLD §2 |
| A3 | Instruction changes are announced | VO, SRC | A new instruction posts `AccessibilityNotification.Announcement` or updates a focused element's value | major | better-accessibility live regions |
| A4 | Dynamic Type reaches AX sizes | DT, SRC | At AX5 the full instruction wraps with no "…", both answer buttons stay on screen, and there's no `.lineLimit(1)` or `.dynamicTypeSize(...)` cap below AX5 on instruction text | major | apple-design typography |
| A5 | Text stays readable over the camera | SRC, SS | Instruction text sits on a solid or `.regularMaterial` backing and reaches 4.5:1 contrast against both a white and a black backdrop. Text drawn straight on the camera image fails | major | apple-design materials; holistic-ux |
| A6 | Targets are at least 44 pt | SRC, SS | Each tappable element is at least 44 by 44 pt (132 px in a @3x screenshot), and neighbouring targets don't overlap | major | holistic-ux Fitts; better-accessibility |
| A7 | Reduce Motion is honoured | RM, SRC | The code reads `accessibilityReduceMotion`. With it on, fog clearing, strip fills and the reveal crossfade or cut instead of sliding or scaling, and nothing pulses in a loop | major | apple-design §14; emil-design-eng |
| A8 | Haptics are paired with a visual | SRC | Every `.sensoryFeedback` or feedback-generator call fires with a visible change on the same state update. No signal is haptic-only | major | apple-design multimodal |
| A9 | Coverage isn't colour-only | GRAY, SS | In grayscale, unseen, not enough, enough, failed and skipped cells stay distinguishable by fill pattern or icon, and a text legend or label exists | major | better-accessibility colour; HLD §2 |
| A10 | Reduce Transparency and Increase Contrast are honoured | SRC | With either setting on, materials become opaque | minor | apple-design §14 |
| A11 | VoiceOver order is instruction first | VO | Swiping from the top reads the instruction, then the primary action, then secondary controls | minor | better-accessibility structure |

## V. Visual and motion quality

| ID | Check | Observed by | Pass when | Sev | Source |
|---|---|---|---|---|---|
| V1 | The camera dominates capture screens | SS | Chrome covers no more than about a third of the screen during the walk and close-ups *(reviewer threshold)* | minor | frontend-design restraint |
| V2 | At most one prominent button per screen | SS | Only one filled or prominent button is visible. Recovery options such as "I can't access this area" use a secondary style | minor | apple-design simplicity |
| V3 | No stacked translucency | SS | No translucent panel sits on another translucent panel | minor | apple-design materials |
| V4 | No decorative animation during capture | SRC, SS | Capture states have no `.repeatForever`, shimmer, confetti or idle pulse. The motion that remains is state feedback: capture acknowledgment, fog clearing, strip update | major | emil-design-eng purpose |
| V5 | Motion never blocks input | SRC | No `.disabled`, `sleep` or `asyncAfter` gates a button while a transition plays | minor | apple-design interruptibility |
| V6 | UI transitions take 300 ms or less | SRC | Screen-to-screen and overlay animations take 300 ms or less. Only the result reveal may take longer | minor | emil-design-eng duration |
| V7 | Buttons respond to presses | SRC | Buttons use a style with a visible pressed state (a system style, or a scale of 0.95 to 0.98) | minor | emil-design-eng |
| V8 | One name per action | SRC | An action keeps its name through the flow: the button that says "I'm here" isn't called "Continue" on the next screen | minor | frontend-design writing |

## Per-state table

State names are the raw values of `ScanPhase` in `ios/HouseScan/Contract/ScanContract.swift` on `t3/ios-mvf` (at `6885b7b`), which the app logs as `STATE=<name>`. Several screens the first-try note describes are conditions inside a phase rather than phases of their own; the second column says where to look for them.

| State | Also covers | Must show | Key items |
|---|---|---|---|
| `onboarding` | camera permission, denied permission | What the scan does and roughly how long it takes, in one or two sentences, and one start button. When camera access is denied, why it is needed and "Open Settings" | I1, I3, A1, A4, V2, R9 |
| `unsupported` | | A plain explanation and what to do instead | R10, I3 |
| `findMeter` | tap the meter, step back | "Go to your electric meter" and **I'm here**; then "Tap the meter", with "step closer" when there is no wall plane; then a standing cue distinct from the aiming cue | I1, I2, I8, V8, A4, A6 |
| `meterCloseUp` | panel close-ups | A reticle, no shutter, a named fix on failure, "Can't get a clear shot" after two tries. Panel shots add the safety wording and Skip | I5, I9, T5, T6, R11, A8 |
| `wallWalk` | tracking lost, relocalizing | One instruction, the strip with non-colour cell marks, upload status kept separate, "I can't access this area". When tracking is limited: a cause-specific prompt, no modal, coverage and arrows frozen. After an interruption: the saved meter view | R1, R2, R3, R4, R5, R7, I6, I7, T1, T2, T3, T4, T7, A2, A3, A9, V1, V4 |
| `gapRequest` | | One line with the reason and target, and a skip option | I10, T4, R1 |
| `markFeatures` | homeowner questions | The saved frame with one instruction for marking a missed object and one confirm button. Questions: one at a time, two large answer buttons | I1, I4, A1, A4, A6, H1 |
| `uploading` | offline | Upload count and pending state, no approval wording. Offline: saved on the phone and not sent, retry | R6, R7, R8, H3 |
| `result` | | Decision in plain words, numbers with error on tap, unsure checks as installer review, the unseen side disclosed | H1, H2, H3, H5, H6, H7 |
| `resultAR` | | The box on the meter anchor and the cable line, hidden with an explanation when tracking is not normal | H4, A7, T3 |
