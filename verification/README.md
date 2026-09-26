# Verification (S4)

Independent checks of what works end to end, run against the exact commits the other
workstreams push. Nothing here fixes their code; findings go back to the owning thread.

| Check | Command | Output |
| --- | --- | --- |
| Unit tests for these tools | `make test` | pass or fail |
| App in the Simulator, a screenshot per `STATE` | `make sim REF=origin/t3/ios-mvf ARGS="--replay <dir> --autopilot --server-url <url>"` | `~/house-scanning-data/reports/sim/<run>/index.html` |
| Runner self-test | `make sim-probe` | same, for `fixtures/state-probe` |

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
