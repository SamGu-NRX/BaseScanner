# Glossary

The words the documents use, each with one meaning. Screen text is quoted as it appears in the
app; everything else is this description's own term.

## The house and the wall

- **Meter.** The homeowner's electric meter. Everything is measured from it.
- **Wall.** The straight outside wall the meter is on, as a line along the ground at its foot.
  Set once, by the meter tap; the app does not follow the wall round a corner.
- **Left, right.** As seen by someone standing outside, facing the wall. The app's words: "to
  your left", "ft left of your meter".
- **Along the wall.** Distance from the meter along the wall line, negative to the left. The app
  shows it in feet and inches; the code works in meters.
- **Wall end.** Where the homeowner said the wall stops. A **real end** comes from "Wall ends
  here" (the wall stops at a corner or something blocking the way); an **unexplored end** comes
  from "I can't get there" during the walk (the wall may continue).

## Seeing the wall

- **Kept photo.** A camera frame the app saves as evidence and later uploads. The homeowner never
  presses a shutter; [coverage and guidance](foundations/coverage-and-guidance.md#when-a-photo-is-kept)
  says when a frame is kept.
- **Close-up.** The one deliberate photo of the meter, taken by itself when the meter is centered,
  near, sharp and well exposed. See [the meter close-up](screens/meter-close-up.md).
- **Coverage strip.** The map along the bottom of the walk screen: the wall unrolled flat, meter at
  zero, in two rows (bands).
- **Band.** One row of the strip. The **wall band** is the wall face from the ground up to
  2.4 m (7 ft 10 in); the **ground band** is the ground from the foot of the wall out to 1.2 m
  (3 ft 11 in).
- **Cell.** A 6 in (0.1524 m) stretch of one band. Each cell is in one of four states:
  - **unseen**: no kept photo shows it; drawn as fog.
  - **seen**: shown in kept photos, but not yet from two positions.
  - **covered**: shown from two positions at least 0.25 m apart with normal tracking. Evidence
    exists; it is not a pass.
  - **skipped**: the homeowner said they can't get there. Recorded for installer review, never
    evidence, drawn differently from both fog and covered.
- **Fog.** The overlay on the camera image over wall and ground not yet seen. It clears where
  kept photos have looked.

## Being told what to do

- **Instruction.** The one line (plus an optional second line) at the top of a camera screen.
  There is exactly one at a time.
- **Coaching.** An instruction about the phone rather than the wall ("Slow down a little",
  "Hold steady"). It replaces the guidance instruction until the problem clears.
- **Target.** A ring on the camera image where the homeowner should aim, or a chevron at the
  screen edge pointing to it when it is off screen.
- **Path.** Dots on the ground showing where to stand next, at most 3 m long, 1.5 m out from the
  wall.
- **Tracking.** Whether the phone knows where it is. **Normal**, **limited** (moving fast, too
  little detail, starting up) or **lost**. **Relocalizing** is the phone finding its place again
  after an interruption.

## Marking

- **Feature.** Something the homeowner marks that affects where a battery can go: gas meter, door,
  window, AC unit, driveway, fence.
- **Mark.** One tap on the camera image (or on the reticle with the Mark button) placing a point of
  a feature. A door or window takes two (opposite corners), a driveway or fence two (along one
  edge), a gas meter or AC unit one.
- **Refusal.** A tap the app does not accept, with the reason shown ("Nothing to pin there").

## After the walk

- **Gap request.** A screen asking for one more specific view ("Show the ground 3 ft right of your
  meter"), from the phone's own check or from the server.
- **Upload.** Sending the scan: the scene description and the kept photos, zipped.
- **Result.** The server's answer, shown as a headline, the battery spot and its cable, and a list
  of checks.
- **Check.** One rule the server evaluated at the spot, shown as **"Looks good"** (pass), **"Not
  sure yet"** (unsure) or **"Doesn't work"** (fail).
- **Installer review.** What happens to anything the phone can't settle: a person at Base
  decides. "An installer will take a look" is the result headline for a manual review.
- **Sample result.** A built-in result the app shows when no server is configured. The screen
  says it is a sample.

## Verification words

- **Replay.** Running the app on a recorded session instead of the live camera (`-replay`).
- **Autopilot.** The app pressing its own buttons through the flow on a replay (`-autopilot`).
- **Screen name.** The name the app logs as `STATE=<name>` when a screen appears:
  `onboarding`, `findMeter`, `meterCloseUp`, `wallWalk`, `markFeatures`, `gapRequest`,
  `uploading`, `result`, `resultAR`, `unsupported`.
