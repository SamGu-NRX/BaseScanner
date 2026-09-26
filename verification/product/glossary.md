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
  from "Can't get there" during the walk (the wall may continue).

## Seeing the wall

- **Kept photo.** A camera frame the app saves as evidence and later uploads. The homeowner never
  presses a shutter; [coverage and guidance](foundations/coverage-and-guidance.md#when-a-photo-is-kept)
  says when a frame is kept.
- **Close-up.** The one deliberate photo of the meter, taken by itself when the meter is centered,
  near, sharp and well exposed. See [the meter close-up](screens/meter-close-up.md). The walk
  shows it again while the phone is finding its place, as the picture to aim at.
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
  - **skipped**: the homeowner said they can't get there. Drawn differently from both fog and
    covered, never evidence, and not sent to the server.
- **Fog.** The overlay on the camera image over wall and ground not yet seen. It clears where
  kept photos have looked.

## Being told what to do

- **Instruction.** The one line (plus an optional second line) at the top of a camera screen.
  There is exactly one at a time.
- **Coaching.** An instruction about the phone rather than the wall ("Slow down",
  "Hold steady"). It replaces the guidance instruction until the problem clears.
- **Reticle.** The small circle in the middle of the camera view that a tap on Mark (or "This is
  my meter") aims with, when the homeowner does not tap the image itself.
- **Mode badge.** The yellow "REPLAY · AUTOPILOT" label shown when the app runs on a recording or
  drives itself.
- **Tap ring.** The ring that blooms where a finger touched the camera image.
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
- **Kind picker.** The "What do you see?" panel behind "Mark something" on the walk, with one tile
  per feature.
- **Feature list.** The `markFeatures` screen, "Anything else near your meter?": the marked
  features, the window question and "Add something".

## After the walk

- **Can't get there.** The walk's way out ("Can't get there"); the gap request's is "I can't get
  there". Both mark the asked-for stretch as skipped.
- **Gap request.** A screen asking for one more specific view ("Show the ground 3 ft right of your
  meter"), from the phone's own check or from the server.
- **Phone request, server request.** A gap request from the phone's own check after the feature
  list, or from "Capture it now" on the result. A **past-end request** asks for the ground beyond a
  wall end. The **requested stretch** is highlighted in amber.
- **Upload.** Sending the scan: the scene description and the kept photos, zipped.
- **Result.** The server's answer, shown as a headline, the battery spot and its cable, and a list
  of checks.
- **Placement line.** The line under the result headline: where the spot is and how much cable.
- **3D model, AR view.** The small 3D model of the wall on the result, and the `resultAR` screen
  that draws the spot on the camera image.
- **Sweep.** The server's outcome for every stretch of wall where it tried the battery, drawn as
  tinted zones in the 3D model and the AR view.
- **"Still needed".** The result's list of missing views, each with "Capture it now" or "An
  installer will check this".
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
