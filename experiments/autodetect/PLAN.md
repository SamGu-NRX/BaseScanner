# Auto-proposed marks: recommendation, flow and integration plan

Written for the experience design thread, which owns the confirm UI, and for S3 and Aiden, who own
the app. The measurements are in [README.md](README.md) and `results/`. Line numbers refer to
`origin/t3/ios-mvf`.

## Recommendation

1. **Ship the meter brand now.** Vision's text recognition already runs on the close-up, and a list
   of meter makers turns its lines into a brand. It names the right maker on 17 of 19 photos where
   the brand is printed in plain letters, and on 22 of 42 where it is part of a logo, such as
   Tatung's round badge or GE's script monogram. It named nothing on the 9 photos without a brand,
   and a wrong maker once, on a plate carrying two makers' names
   ([meter_brand/results/brand.md](meter_brand/results/brand.md)). Show the brand pre-filled and
   editable above the number candidates. It needs no model and no download.
2. **Don't ship automatic wall-object proposals from public data.** No candidate passed. The best,
   OWLv2, found 23% of Open Images windows at 55% precision, and it is a 308 MB model that takes
   about half a second a frame on a Mac GPU. The on-device student (Create ML, 6.8 MB, 50 ms on the
   Mac) found 7%. The public photos show whole buildings from far away. The app sees one wall from
   1 to 3 m. Counting only large objects, the student's window AP50 rises from 9% to 38%, which
   points at the data, not the model size.
3. **Collect the app's own frames and train on those.** The packet already keeps every keyframe
   with its pose. Aiden records walls with the app (about 30 to start; nothing yet says how many
   are enough); OWLv2 pre-labels the keyframes offline (Apache-2.0, and this harness already runs
   it); a person accepts or fixes each box; the Create ML student retrains on that, and this
   harness scores it on held-out houses against the same criteria. That is the first run whose
   result can settle the question, and the same labels give the first test of AC units, gas
   meters, electrical boxes, garage doors and batteries, which no public set labels.
4. **Lift boxes from their inner corners.** Lifting a true door box through the laser depth from
   the midpoints of its sides is off by 0.59 ft p90; from the inner corner of each side, by
   0.11 ft ([results/extent.md](results/extent.md)). Whatever detector lands, the lifting code
   should use inner corners.
5. **Leave the long D-FINE and Grounding DINO runs.** D-FINE would train about 10 hours and
   Grounding DINO would label for about 5 hours on this shared Mac, both on the same off-view data
   that limited the student. Neither would change recommendation 3.

Not measured, and worth a device check once the flow exists: ARKit's mesh classes include window
and door on LiDAR phones only, with no published outdoor accuracy, so they can at most add a cue.
RoomPlan is documented for indoor rooms. On iOS 27 the Foundation Models framework accepts images,
but Apple documents no box output, so it could at most verify a crop ("is this a gas meter?").

## The flow once a detector passes

The homeowner answers yes or no to what the phone found, and draws only what it missed.

```
Walk along the wall (unchanged)
   │  the detector runs on each kept keyframe, off the main actor
   │  a proposal appears once the same object lifts to the same wall stretch in 2 keyframes
   │  it is drawn on the wall as a dashed outline with its kind; no prompt, no haptic,
   │  so the walk is not interrupted
   ↓
"Anything else near your meter?" (MarkFeaturesScreen)
   │  "We spotted 3 things on this wall", nearest the meter first, at most 6 rows
   │  each row: crop from the sharpest keyframe with the box drawn · kind · "About 7 ft right"
   │            [Yes]   [Not a window ▾]   (menu: another kind, or "Nothing there")
   ├──→ Yes: the row turns solid; a window then asks "Does it open?" as today
   ├──→ another kind: the kind changes and the row is confirmed
   ├──→ Nothing there: the row goes away and is recorded as rejected
   ├──→ tap the crop: the full photo with four edge handles; drag, Done; the box is lifted again
   ├──→ Add something: today's tap-to-mark flow, unchanged
   ↓
"Looks complete": unanswered proposals are exported, never dropped
```

Why each choice:

- **An unanswered proposal stays.** Dropping an unconfirmed gas meter would turn unsure into clear,
  which AGENTS.md forbids. It goes to the server as `source: "vlm"` with its `conf`, so the server
  applies the vision-model error bar.
- **Adjust on a still photo, not in AR.** Dragging handles on a live view fights hand shake and
  tracking. The crop is the image the extent was computed from, so an edit maps straight back.
- **Yes is the big target; rejecting takes two taps.** "Nothing there" sits inside the kind menu.
- **Dashed means proposed and solid means confirmed**, in AR and in the list, so the state never
  rests on colour alone.
- **Motion.** An outline fades in over 200 ms with a strong ease-out from 96% scale, and turns
  solid over 150 ms when confirmed. With Reduce Motion, opacity only. Nothing bounces.
- **VoiceOver** reads a row as "Window, about 7 feet right of the meter, proposed", with actions
  Yes, Change kind and Nothing there. Targets are at least 44 pt.

The meter close-up gains one line above the number candidates: the brand, with "Change". A brand
not on the list shows "Brand not read" and a picker, and never blocks the step.

## Where it goes in HouseScanKit and the app

PR #52 (`t3/battery-mark`) adds `.battery` and `.elecBox` to `FeatureKind` and should merge first.
`FeatureKind` still has no garage door, although `PacketMark.Kind` has `garageDoor`.

| Step | Files | Change |
|---|---|---|
| 1. Brand | `HouseScan/Runtime/MeterReader/VisionMeterNumberReader.swift:11-70`, new `HouseScanKit/Meter/MeterBrand.swift`, `UI/Screens/MeterCloseUpScreen.swift` | Keep the recognised lines, which are discarded after ranking today; port `meter_brand/brands.py` with strict tests; show the brand. Ships alone. |
| 2. Detector interface | new `HouseScanKit/Detect/WallObjectDetector.swift`; new `HouseScan/Runtime/Detect/CoreMLWallObjectDetector.swift` | `detect(jpeg:) -> [ImageBox]` in landscape sensor pixels, matching the intrinsics (AGENTS.md). The app target holds the model; the package stays model-free. A file-backed stub lets steps 3-7 ship before a model passes. |
| 3. Lift to the wall | `HouseScanKit/Geometry/WallFrame.swift:214-257`, `Geometry/Camera.swift:65-107` | Box → rays through the inner corners → keyframe depth when present, else `WallFrame.intersectWall` → span, bottom, top. |
| 4. Fuse keyframes | new `HouseScanKit/Detect/ProposalTracker.swift` | Match lifted boxes by kind and overlapping span; keep a proposal after 2 views; median edges and their spread. |
| 5. Run on keyframes | `HouseScan/Runtime/KeyframeStore.swift:66-116`, `Runtime/ScanEngine.swift:524-550` | Detect in the detached task that already writes each keyframe; post results to the engine on the main actor. |
| 6. State | `HouseScan/Contract/ScanContract.swift:406-449` | `MarkedFeature` gains its origin (tap or proposal with `conf`), a status (unanswered, confirmed, rejected), and the keyframe and box it came from. |
| 7. Review UI | `UI/Screens/MarkFeaturesScreen.swift`, `UI/Camera/WallMarksOverlay.swift:46-71`, `UI/Copy/ScanCopy.swift:149-178` | The rows, outlines and copy above. |
| 8. Export | `Runtime/ScanEngine+Export.swift:13-51`, `HouseScanKit/Scene/SceneExport.swift:407-434` | `source: "vlm"` and `conf` for proposals. `SceneDocument.Object` has no `conf` field yet. |
| 9. Replay test | `Runtime/ReplayPlayer.swift`, `HouseScanKit/Replay/ReplaySession.swift` | Replay a recorded walk through steps 2-5 and check the proposals, without a phone. |

Steps 1, 3 and 4 are pure logic with one correct answer, so they get strict unit tests; step 3 can
reuse the ETH3D door numbers in `results/extent.md`.
