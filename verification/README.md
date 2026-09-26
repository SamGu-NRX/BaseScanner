# Verification (S4)

Independent checks of what the other workstreams' commits do, each tied to a commit SHA. Nothing
here fixes their code; findings go to the owning thread. Reports are written to
`~/house-scanning-data/reports/`, outside git, because replay frames come from non-commercial
datasets. Requirements: uv, and Xcode 26 or newer with an iOS Simulator runtime.

| Check | Command, from `verification/` | Output |
| --- | --- | --- |
| The app at `t3/ios-mvf` on the real ADVIO replay, uploading to a server started from `t3/server`; a screenshot per `STATE` | `make sim-app` (`REF=`, `SERVER_REF=`, `ARGS=` to vary) | `reports/sim/<run>/index.html` |
| Every case, the ETH3D facade scene and optional app exports through the server's API | `make e2e` (`ARGS="--app-export <scan.zip>"`) | `reports/e2e/<run>/report.md` |
| Apple's accessibility audit on every screen the app reaches | `uv run python -m hsverify.a11yaudit --ref <ref> --replay <session> --autopilot` | `reports/a11y/<run>/index.html` |
| A replay session is well formed; its poses against ground truth | `uv run python -m hsverify.replaycheck <session>` | printed |
| Every open PR and plan metric with its evidence | `make scoreboard` (`ARGS=--slow` also runs test suites) | `SCOREBOARD.md` |
| These tools' own tests | `make test` | pass or fail |
| The Simulator runner against a probe app with a known sequence | `make sim-probe` | `reports/sim/<run>/` |

Written results: [the UX review](ux/review.md) against [the checklist](ux/checklist.md), and
[the product description](product/README.md) with its [bug triage](product/bug-triage.md).

## What the checks guarantee

**Simulator runner** (`hsverify/simrun.py`). Builds the ref in a `/tmp` worktree, installs it on
its own Simulator ("HouseScan Verify") and launches it with the C4 arguments. It follows
`STATE=<name>` from subsystem `dev.housescanning.housescan` and screenshots each state once it has
settled for 1.2 s; a state replaced sooner is captured at once and marked *transient*. The report
lists a failed build, a crash, markers logged as `<private>`, and a run with no markers as
problems, and keeps every app log line. It waits while another `xcodebuild` compiles, because
several workers share the Mac.

**End-to-end check** (`hsverify/e2e.py`, `hsverify/resultcheck.py`). Starts the server from a ref
and finds its placement endpoint in the OpenAPI document, refusing to guess between candidates.
Each scene is validated against `server/schemas/scene.schema.json` at that ref first, so bad input
is not blamed on the server. Each answer must validate against `server/schemas/result.schema.json`
and satisfy, for any policy:

- `pass` has a passing spot, all checks passing, no photo request and an approved policy;
  `reject` has no spot; `manual_review` gives reasons.
- Each check's outcome follows from its numbers (C5): a minimum T passes only when measured −
  error > T and fails only when measured + error < T, a maximum mirrored, a review line also
  cleared for a pass; an unsure labelled `margin` lies within its error of a line.
- No battery start passes over wall, cable route or ground that was not observed, and no photo
  request covers an observed area.
- Counts add up, `input_sha256` is the hash of the bytes sent, the spot's offset equals its centre
  minus the meter.
- The same scene sent again answers the same; mirrored left to right it gives the same decision
  and the same length of each outcome; without coverage nothing passes.

The 40 cases in [`e2e/cases/`](e2e/cases/README.md) were written from the public goldens and C5
without reading the server's tests. Each names the thresholds it assumes; a mismatch is reported
as such rather than as a pass or fail. [`scenes/eth3d-facade`](scenes/eth3d-facade/README.md)
builds a scene from real laser-scanned geometry; real scenes must answer within 1 s.

**Accessibility audit** (`hsverify/a11yaudit.py`). Runs the UI test bundle in
`fixtures/a11y-audit`, which launches the installed app by bundle id and calls
`performAccessibilityAudit(for: .all)` on each distinct screen. It also flags buttons labelled
with an SF Symbol name, which Apple's audit accepts. The probe app's middle screen carries an
unlabelled 12 pt button; an audit of the probe must find it.

**Replay check** (`hsverify/replaycheck.py`). Checks the fields, JPEG sizes, rigid poses and
spacing gate of a Measure Lab v2 session, then compares ARKit with `ground_truth.json` after
aligning heading and origin. It reports the path-length ratio separately and does not say which
track is right: ADVIO's ground truth has its own scale error.

Every report records the harness's peak memory and that of the largest child it waited for.
