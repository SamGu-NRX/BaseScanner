# Verification (S4)

Independent checks of what works end to end, run against the exact commits the other
workstreams push. Nothing here fixes their code; findings go back to the owning thread.

| Check | Command | Output |
| --- | --- | --- |
| Unit tests for these tools | `make test` | pass or fail |
| App in the Simulator, a screenshot per `STATE` | `make sim REF=origin/t3/ios-mvf ARGS="--replay <dir> --autopilot --server-url <url>"` | `~/house-scanning-data/reports/sim/<run>/index.html` |
| Runner self-test | `make sim-probe` | same, for `fixtures/state-probe` |
| A replay session (C3) is well formed, and how far its poses are from ground truth | `uv run python -m hsverify.replaycheck <session folder>` | printed |
| Scenes through the server's HTTP API, judged against C1, C2 and C5 | `uv run python -m hsverify.e2e --server-ref origin/t3/server [--real scene.zip]` | `~/house-scanning-data/reports/e2e/<run>/report.md` |

Requirements: uv, Xcode 26 or newer with an iOS Simulator runtime.

## Simulator runner

`hsverify/simrun.py` checks the ref out into a detached worktree under `/tmp`, builds it for
the Simulator, installs it on its own device ("HouseScan Verify", so it never touches a
Simulator another worker is using), and launches it with the contract C4 arguments. It
attaches `log stream` before launch and follows `STATE=<name>` lines from subsystem
`dev.housescanning.housescan`, category `state`.

A state is screenshotted after it has been on screen for `--settle` seconds (default 1.2). If
the next state arrives first, the screenshot is taken at once and marked *transient*, since it
may already show the next screen. The run ends at an `--until` state, after `--idle` seconds
with no new state, or at `--timeout`. It reports a build failure, a crash, markers logged as
`<private>`, and a run with no markers at all as problems.

Builds wait while any other `xcodebuild` runs, because four workers share this Mac.

The report folder holds `index.html` (screenshots in state order), `report.json`,
`report.md`, the build log, the raw log stream and the app's stdout and stderr.

`fixtures/state-probe` is a ten-line app that logs a fixed sequence, including a 0.3 s state,
so the runner can be checked without the real app.

## Replay check

`hsverify/replaycheck.py` reads a Measure Lab v2 session and checks what the app and server
rely on: every listed JPEG exists at the stated size, poses are rigid, timestamps increase,
and motion keyframes respect the spacing gate the session declares. With `ground_truth.json`
beside it, it aligns ground truth to ARKit by heading and origin (both worlds are gravity
aligned) and reports the error after the best fit, after also removing scale, and when
anchored at the first keyframe, as the app anchors on the meter. The ARKit-to-truth path
length ratio is printed on its own because a scale difference dominates the other numbers.
It does not say which track is right: ADVIO's ground truth has its own scale error (see
`experiments/evals` on `t3/evals`).

## End-to-end server check

`hsverify/e2e.py` starts the server from a ref in a `/tmp` worktree, or uses `--server-url`,
and reads the scene endpoint from its OpenAPI document. It stops rather than guesses when
more than one POST could take a scene. Every scene is validated against the scene schema at
the same ref first, so bad input is not blamed on the server. Every answer must validate
against the result schema and pass `hsverify/resultcheck.py`:

- `pass` needs a passing spot, every check passing, no photo request and an approved policy;
  `reject` has no spot and no photo request; `manual_review` gives reasons.
- Each check's outcome follows from its numbers (C5): at least T needs measured − error > T
  to pass and measured + error < T to fail; anything else is unsure. At most T is mirrored.
- No battery start passes unless the wall and cable route back to the meter, and the ground
  under the battery out to its depth, were observed. No photo request covers an observed area.
- Counts add up, `input_sha256` is the hash of the bytes sent, and the spot's offset from the
  meter equals its centre minus the meter.

Each scene is also sent again (identical result apart from timing), mirrored left to right
(same decision and the same length of passing, unsure and failing starts), and without its
coverage (no pass anywhere). Case files in `e2e/cases/` add the outcomes their geometry
forces. Each one names the thresholds it assumes, and a case whose assumption differs from the
server's rules is reported as an assumption mismatch, not as a pass or fail. Scenes passed
with `--real` must answer within 1 s.
