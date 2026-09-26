# Suspected defects

From the documents' open questions and [verification.md](verification.md), deduplicated. Source
`21a63e7` (S3 integration commit) unless stated.

| ID | Severity | Where the homeowner meets it | Decision |
| --- | --- | --- | --- |
| B-01 | Blocker | Uploading: every scan fails with 404 | fix (S3) |
| B-02 | Major | Uploading: a failure shows raw server JSON | fix (S3) |
| B-03 | Blocker | Camera denied, camera failure or unreadable replay: no message, no way on | fix (S3) |
| B-04 | Blocker | Meter close-up: "Can't get a clear shot" may never appear | fix (S3) |
| B-05 | Major, cause unconfirmed | Camera screens: cards render without text in Simulator screenshots | investigate (S3, S4) |
| B-06 | Major | Walk at 20 ft: "Is this the left end?" has no truthful answer when the wall continues | product call |
| B-07 | Minor | Photos of the home stay in the phone's cache after every scan | product call |

## B-01. The app uploads to a route the server does not have

- **What happens.** The app posts the scan to `POST {serverURL}/v1/scenes`; the server serves
  `POST /v1/placements`. Every upload fails with 404.
- **Evidence.** Server log: `"POST /v1/scenes HTTP/1.1" 404 Not Found`. The same bundle posted to
  `/v1/placements` as `application/zip` returns 200 with a result, and passes every check in
  `hsverify/e2e.py` (report `20260926-041009-b04558df`).
- **Cause.** `ios/HouseScan/Runtime/ResultClient.swift:27`; the comment above it calls the route a
  placeholder. Contracts C1 and C2 fix the body and the answer but not the path.

## B-02. Upload failures show raw error text

- **What happens.** "That didn't go through" is followed by `The server answered 404:
  {"error":{"code":"not_found",...}}`.
- **Cause.** `ios/HouseScan/UI/Copy/ScanCopy.swift`, `upload(_:)` puts the error's description in
  the detail line; `Runtime/ScanEngine.swift` passes `String(describing: error)`.
- **Expected.** Plain words ("We couldn't reach the server. Your scan is saved; try again.") and
  the "Try again" button, which the screenshot does not show (see B-05).

## B-03. Failures other than an unsupported phone never reach the screen

- **What happens.** Only the `unsupported` screen shows a failure, and the app switches to it only
  when motion tracking is unsupported. A denied camera, a failed camera session or an unreadable
  replay records the failure and stays on the current screen.
- **Cause.** `Runtime/ScanEngine.swift:89, 93, 338, 340`.
- **Reproduce.** Launch with `-replay /nonexistent`: expected "This recording can't be opened";
  predicted from code: onboarding, then a camera screen with nothing on it. Not yet run.

## B-04. The close-up's way out can fail to appear

- **What happens.** A failed try counts only when one problem lasts 4 s with no good frame between.
  Frames that alternate between good and blurry neither fill the 0.6 s ring nor count a failure,
  so "Can't get a clear shot" never appears.
- **Cause.** `ios/HouseScanKit/Sources/HouseScanKit/Capture/CloseUpGate.swift`, `evaluate`.
  S3's full-flow test cannot catch it: the autopilot calls the skip action directly.
- **Suggested fix.** Count a failed try per 4 s on the screen without a photo.

## B-05. Camera-screen chrome renders without its text in Simulator screenshots

- **What happens.** On `meterCloseUp` and `wallWalk` the instruction card, the pills and the strip
  are empty panels; on `markFeatures` the text is black on the camera image with no panel; on
  `uploading` after a failure the emblem and button are not visible.
- **Unknown.** Whether this is the app or the capture: screenshots were taken with `simctl io
  screenshot` with the Simulator in light appearance, while camera screens force dark. Next: the
  same screens captured from inside the app's process (XCUITest), and in dark appearance.

## B-06. The walk asks for a wall end at 20 ft whether or not the wall ends

- **What happens.** At 6.1 m of coverage the instruction is "Is this the left end of the wall?".
  If the wall continues, the homeowner can only answer "Wall ends here" (recorded as a real end,
  which lets the server reject) or "I can't get there" (an unexplored end).
- **Cause.** `ios/HouseScanKit/Sources/HouseScanKit/Guidance/GuidancePlanner.swift`,
  `preferredTask`. A third answer ("The wall keeps going") recorded as unexplored-beyond-reach
  would be truthful.

## B-07. Scan photos are never deleted

- **What happens.** Each scan writes its photos to `Caches/Scans/<id>/`; nothing deletes them
  after upload, Start over or relaunch. iOS may purge caches, but only under storage pressure.
- **Cause.** `ios/HouseScan/Runtime/KeyframeStore.swift:25`.
