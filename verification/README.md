# Verification (S4)

Independent checks of what the other workstreams' commits do, each tied to a commit SHA. Nothing
here fixes their code; findings go to the owning thread. Reports are written to
`~/house-scanning-data/reports/`, outside git, because replay frames come from non-commercial
datasets. Requirements: uv, and Xcode 26 or newer with an iOS Simulator runtime.

| Check | Command, from `verification/` | Output |
| --- | --- | --- |
| The app at `t3/ios-mvf` on the real ADVIO replay, uploading to a server started from `t3/server`; a screenshot per `STATE` | `make sim-app` (`REF=`, `SERVER_REF=` or `SERVER_URL=` for the hosted API, `ARGS=`) | `reports/sim/<run>/index.html` |
| Every case, the ETH3D facade scene and optional app exports through the server's API | `make e2e` (`ARGS="--app-export <sim report>"`, `SERVER_REF=` or `SERVER_URL=`) | `reports/e2e/<run>/report.md` |
| Apple's accessibility audit on every screen the app reaches | `uv run python -m hsverify.a11yaudit --ref <ref> --replay <session> --autopilot` | `reports/a11y/<run>/index.html` |
| A replay session is well formed; its poses against ground truth | `uv run python -m hsverify.replaycheck <session>` | printed |
| Every open PR and plan metric with its evidence | `make scoreboard` (`ARGS=--slow` also runs test suites) | `SCOREBOARD.md` |
| These tools' own tests | `make test` | pass or fail |
| The Simulator runner against a probe app with a known sequence | `make sim-probe` | `reports/sim/<run>/` |

Written results: [the UX review](ux/review.md) against [the checklist](ux/checklist.md), [the
friction audit](ux/friction.md) of the homeowner's path, and
[the product description](product/README.md) with its [bug triage](product/bug-triage.md).

## What the checks guarantee

**Simulator runner** (`hsverify/simrun.py`). Builds the ref in a `/tmp` worktree, installs it on
its own Simulator ("HouseScan Verify") and launches it with the C4 arguments. It follows
`STATE=<name>` from subsystem `dev.housescanning.housescan` and screenshots each state once it has
settled for 1.2 s; a state replaced sooner is captured at once and marked *transient*. The report
lists a failed build, a crash, markers logged as `<private>`, and a run with no markers as
problems, and keeps every app log line. `make sim-app` also fails unless the app reaches
`result`, and keeps the scan it uploaded as `scan.zip`. The app is launched only once the log
stream has attached, so early states are not missed. The runner waits while another
`xcodebuild` compiles, because several workers share the Mac.

**End-to-end check** (`hsverify/e2e.py`, `hsverify/resultcheck.py`). Starts the server from a ref
and finds its placement endpoint in the OpenAPI document, refusing to guess between candidates.
The server is killed if it passes 3.5 GB, and the report says so. Each scene is validated against
`server/schemas/scene.schema.json` at that ref first, so bad input is not blamed on the server.
Battery size, clearance radii and measurement errors are read from `server/rules.yaml` at the same
ref. Each answer must validate against `server/schemas/result.schema.json` and satisfy, for any
policy:

- `pass` has a passing spot, all checks passing, no photo request and an approved policy;
  `reject` has no spot; `manual_review` gives reasons.
- Each check's outcome follows from its numbers (C5): a minimum T passes only when measured −
  error > T and fails only when measured + error < T, a maximum mirrored, a review line also
  cleared for a pass; an unsure labelled `margin` lies within its error of a line.
- No battery position passes unless the wall and cable route under it were observed, and every
  point within each clearance's radius, widened by the battery's position error, was observed
  in the bands a hazard could hide in (gas: wall and ground; openings: wall; AC, drives, pools:
  ground). Only points within that reach whatever the wall's shape are required: along the wall
  to the radius, and on the ground out to the battery's depth plus the radius in front, tapering
  past its ends. So a correct server is never flagged.
- When the result gives an unobserved area as a reason, each check left unsure for that reason
  is named by a request of every band it lacks, and no request covers an area already observed.
- Counts add up, `input_sha256` is the hash of the bytes sent, the spot's offset equals its centre
  minus the meter.

Each scene is also resent changed, and the pairs must stay ordered: the same scene answers the
same; mirrored it gives the same decision and outcome lengths; with no coverage, less coverage, or
ground trimmed just short of the largest clearance nothing new passes; with more error, or tape
measurements re-taken by tap, no outcome moves except to unsure; adding every requested photo, up
to three rounds, leaves no check unsure for lack of coverage. Five hostile inputs (150 objects
with their own errors, coordinates of 1e300, a 5000 ft wall, nesting 5000 deep, and a small zip
holding a 400 MB scene.json) must each be refused with 400, 413 or 422, or answered validly,
within 10 s and, for a server started here, 500 MB of extra memory. `--no-hostile` skips them.

The 43 cases in [`e2e/cases/`](e2e/cases/README.md) were written from the public goldens and C5
without reading the server's tests, except that the three drift cases take drift at the
battery's far edge as S2's 70ab0b0 states. The hostile inputs were chosen after reading S2's
hardening tests. Each case names the thresholds it assumes; a mismatch is reported as such
rather than as a pass or fail. [`scenes/eth3d-facade`](scenes/eth3d-facade/README.md)
builds a scene from real laser-scanned geometry; real scenes must answer within 1 s.
`--app-export` takes a `make sim-app` report folder and sends the scan the app uploaded, recording
the app's commit.

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
