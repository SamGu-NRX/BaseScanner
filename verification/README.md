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

The written reviews of the app (product description, UX review, friction audit) are in #61, at
`docs/app-review/`.

## What the checks guarantee

**Simulator runner** (`hsverify/simrun.py`). Builds the ref in a `/tmp` worktree, runs it on its
own Simulator ("HouseScan Verify") with the C4 arguments, and screenshots each `STATE` once it has
settled for 1.2 s (a state replaced sooner is marked *transient*). A failed build, a crash,
redacted or missing markers, a required state never reached, or, for `make sim-app`, no scan
bundle from the app is a problem, and the run exits 1. The app launches only after the log stream
has attached. The runner waits while another `xcodebuild` compiles, because the Mac is shared.

**End-to-end check** (`hsverify/e2e.py`, `hsverify/resultcheck.py`). Starts the server from a ref
(killed past 3.5 GB) or uses `SERVER_URL`, and sends each scene the way the app does. Scenes are
checked against the ref's scene schema first, so bad input is not blamed on the server. Rules come
from the ref's `rules.yaml`. Every answer must validate against the result schema and:

- have a decision consistent with its spot, checks, requests and policy;
- have each check's outcome follow from its numbers (C5), with an unsure `margin` inside its
  error of a line;
- pass no battery position without the coverage each passing check needs, per the server's "What
  settles each check": the wall seen high enough over the clearance's reach, the ground out to the
  battery's depth plus the reach, and the facing and overhead bands over the battery unless
  measured. The reach includes the battery's position error, whose default depends on how the
  wall was found (tap, mesh or plane). Only points within reach whatever the wall's shape are
  required, so a correct server is not flagged;
- name every check left unsure for lack of coverage in a request for each band it lacks, and ask
  for nothing already seen as far as the request needs;
- add up, and hash the bytes sent.

Each scene is also resent changed, and the answers must stay ordered: mirrored, trimmed, with
more error or with requested views added, nothing improves that should not. Five hostile inputs
must be refused or answered within 10 s and 500 MB. A run claims the contract only when at least
one scene was answered and checked, and latency only for a real scene that got a result. Bundles
are read within fixed size limits.

The 43 generated cases in [`e2e/cases/`](e2e/cases/README.md) come from the public goldens and C5;
regeneration keeps any case written by hand. [`scenes/eth3d-facade`](scenes/eth3d-facade/README.md)
builds a scene from laser-scanned geometry, replacing only its own outputs.

**Accessibility audit** (`hsverify/a11yaudit.py`) runs Apple's audit on every screen the app
reaches, and flags buttons labelled with an SF Symbol name.

**Replay check** (`hsverify/replaycheck.py`) checks a Measure Lab v2 session and compares its
poses with ADVIO's ground truth.

Every report records the harness's peak memory and that of its largest child.
