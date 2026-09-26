# Device field test

## Question

Does the House Scan TestFlight build produce a scan the server can place a battery on, from one walk
along a real wall with a real iPhone? And which behaviours that the Simulator can't check hold on a device?
Those are the tracking, the live meter tap, the close-up, haptics, the AR overlay and interruptions.

## Method

[RUNBOOK.md](RUNBOOK.md) lists every device-only claim from the product description on `t3/verification`,
in the order a person meets them, each with a test ID. The tester screen-records each run with the
microphone on and says the test IDs and haptics aloud. Before scanning, they tape the wall's features
relative to the meter. After the run:
- the exported scan is sent to the server again, which returns the same result the phone got;
- [`coverage_replay.py`](coverage_replay.py) replays its photos through the app's coverage rules.

[setup-plan.html](setup-plan.html) is the plan for the first site, a mock house wall with a meter, panel,
window, eave and an installed battery (rendered in [setup-plan.png](setup-plan.png)).

## Pass criteria

The first and last come from the runbook's goals before run 1. The 4 in bound is Measure Lab's, applied after the run.

- The uploaded scan covers the stretch of wall the tester walked, and the result names either a spot or a
  reason that refers to something on that wall.
- Measured features are within 4 in of the tape along the wall and in height, as in Measure Lab's criteria.
- Every device-only claim in the runbook is recorded as pass, fail or not reached.

## Result, run 1

Run on 2026-09-26 with TestFlight build 1.1 (workflow run
[36255760659](https://github.com/SamGu-NRX/house-scanning-master/actions/runs/36255760659), branch `beta` at
[`28cd898`](https://github.com/SamGu-NRX/house-scanning-master/commit/28cd8988187979800f74bde78ee1b1fc246d0ec3),
capture code `t3/ios-mvf` at
[`657ab28`](https://github.com/SamGu-NRX/house-scanning-master/tree/657ab283092f1a34cc2dff87d48a0871d284f9c4/ios)).
The screen recording has not been reviewed yet, so the order of taps below is inferred from the scan
and the code.

**The first criterion fails.**
- **What the phone captured.** It kept 44 photos and a meter close-up. It walked about 19 ft right of the
  meter and back, 5 to 7½ ft from the wall.
- **What the scan says.** Both wall ends sit within 4 in of the meter: the exported wall baseline is
  0.66 ft long. The scan leaves out everything past its ends, so it tells the server that no wall and no
  ground were observed.
- **What the server answered.** `manual_review` with no spot, asking the homeowner to "keep walking past
  the left end of the scan (0 ft 4 in left of the meter)", and the same for the right.

### How the walk was lost

"Can't get there" during the walk sets that side's end at `GuidancePlanner.reach`
([`ScanEngine+Actions.swift`](https://github.com/SamGu-NRX/house-scanning-master/blob/ff95f1cb571e2f3ef56d9faae85880665ad0ca30/ios/HouseScan/Runtime/ScanEngine%2BActions.swift#L315-L319)).
`reach`
([`GuidancePlanner.swift`](https://github.com/SamGu-NRX/house-scanning-master/blob/ff95f1cb571e2f3ef56d9faae85880665ad0ca30/ios/HouseScanKit/Sources/HouseScanKit/Guidance/GuidancePlanner.swift#L101-L117))
counts 6-inch cells outward from the meter. It stops at the first cell whose wall and ground are not both
covered. A cell is covered when each of its three sample rows has been seen from two positions: the wall
at 0, 3.25 and 6.5 ft up, and the ground at 0, 2 and 4 ft out. So if the ground right in front of the
meter hasn't been seen twice, the tap puts the end at the meter.

After that, the coverage map ignores everything past the ends:
- `record` stops adding sightings outside them
  ([`CoverageMap.swift`](https://github.com/SamGu-NRX/house-scanning-master/blob/ff95f1cb571e2f3ef56d9faae85880665ad0ca30/ios/HouseScanKit/Sources/HouseScanKit/Coverage/CoverageMap.swift#L332));
- `coveredIntervals` and `groundDepthSpans` leave them out
  ([L979](https://github.com/SamGu-NRX/house-scanning-master/blob/ff95f1cb571e2f3ef56d9faae85880665ad0ca30/ios/HouseScanKit/Sources/HouseScanKit/Coverage/CoverageMap.swift#L979),
  [L527](https://github.com/SamGu-NRX/house-scanning-master/blob/ff95f1cb571e2f3ef56d9faae85880665ad0ca30/ios/HouseScanKit/Sources/HouseScanKit/Coverage/CoverageMap.swift#L527)).

The walk still kept photos and accepted marks up to 19 ft away, and nothing on screen said they would be
dropped. The export then clamps the baseline to ±0.1 m around the meter
([`ScanEngine+Export.swift`](https://github.com/SamGu-NRX/house-scanning-master/blob/ff95f1cb571e2f3ef56d9faae85880665ad0ca30/ios/HouseScan/Runtime/ScanEngine%2BExport.swift#L84-L85)),
which is the ±0.328 ft the server echoes. This code is unchanged between the build's `657ab28` and the
branch head `ff95f1c`.

The replay shows how long the scan was exposed to this. Replaying the 44 photos in order through the
coverage rules, with no ends marked, the covered stretch next to the meter stays at 0 ft on both sides
until photo 43:

```
photo   x (ft)  reach left  reach right
k00001     0.38       0.0 ft        0.0 ft
...
k00030    19.69       0.0 ft        0.0 ft
...
k00042     6.02       0.0 ft        0.0 ft
k00043     5.54       1.0 ft        5.5 ft
```

At the meter, the wall rows were seen from the start. The ground 2 ft and 4 ft out was seen only by photos
41–43, taken on the way back. So during nearly the whole walk, any "Can't get there" would have put that
side's end at the meter. The runbook told the tester to use it at the left corner, only 17 in from the
meter, and at the right corner if the end prompt never came.

The replay also shows why the end prompt couldn't come:
- the ground 4 ft out was never seen twice past 5.5 ft right of the meter;
- the wall's top row, 6.5 ft up, was never seen twice past 10.5 ft.

The prompt appears only after 20 ft of unbroken coverage.

### Measurements

These are the app's marks against the tape, both taken from the meter's centre line. Positive means the
app has it farther right or higher.

| Feature | App − tape | Within 4 in |
|---|---|---|
| Window, right edge | −0.5 in | yes |
| Window, left edge | +5.4 in | no |
| Window, width | −5.9 in | no |
| Window, sill height | +1.9 in | yes |
| Gas meter stand-in, centre | 4.8 in nearer the meter | no |

The window's width error comes almost entirely from its left edge. The gas meter is a one-tap mark with a
nominal 1 ft width.

### Device-only claims

Not yet scored. They need the screen recording.

## What this changes

- **For the capture app (lane A owner's call):** "Can't get there" shouldn't be able to place an end
  inside a stretch the tester has walked and photographed. Possible fixes:
  - place the end at the farthest point seen, or at the phone's position along the wall, instead of at
    the unbroken covered reach;
  - refuse the tap and say what is missing ("tilt down to show the ground by your meter");
  - at least warn when an end lands within a foot of the meter.

  Separately, the walk shouldn't keep photos and marks it will drop without saying so.
- **For guidance:** on this wall the ground 2–4 ft out in front of the meter was only captured on the way
  back. Asking for that ground at the meter before "Walk slowly to your left" would unblock `reach` early.
- **For the next runs:** the runbook now says to fill the strip next to the meter before any "Can't get
  there". Runs 2 and 3 are still to do.

Raw material stays out of git: the recording, the scan and the tape readings.
