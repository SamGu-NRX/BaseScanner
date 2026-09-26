# Scoreboard

Generated 2026-09-26 04:25 CDT by `make scoreboard` (`uv run python -m hsverify.scoreboard`) in `verification/`; slow probes not run (add ARGS=--slow). Probes are defined in `verification/scoreboard/metrics.yaml`.

## Open pull requests

| # | Branch | Head | Draft | CI | Updated |
| --- | --- | --- | --- | --- | --- |
| [#14](https://github.com/SamGu-NRX/house-scanning/pull/14) | `t3/docs-cleanup` | `9c9ceb2a` | no | 4 success | 2026-09-26 03:15 CDT |
| [#13](https://github.com/SamGu-NRX/house-scanning/pull/13) | `t3/verification` | `1330a827` | yes | 4 success | 2026-09-26 04:21 CDT |
| [#12](https://github.com/SamGu-NRX/house-scanning/pull/12) | `t3/evals` | `b5ca7af8` | yes | 5 success | 2026-09-26 03:57 CDT |
| [#11](https://github.com/SamGu-NRX/house-scanning/pull/11) | `t3/server` | `6a623d8a` | yes | 5 success | 2026-09-26 04:22 CDT |
| [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) | `t3/ios-mvf` | `90c01dde` | yes | 4 success, 1 pending | 2026-09-26 04:17 CDT |
| [#9](https://github.com/SamGu-NRX/house-scanning/pull/9) | `codex/capture-contract-probe` | `4b6c4309` | yes | 4 success | 2026-09-26 00:08 CDT |
| [#8](https://github.com/SamGu-NRX/house-scanning/pull/8) | `t3/testflight` | `b896d59f` | no | 4 success | 2026-09-26 03:18 CDT |
| [#7](https://github.com/SamGu-NRX/house-scanning/pull/7) | `t3/measure-lab` | `45770a3b` | no | 6 success | 2026-09-26 03:19 CDT |
| [#6](https://github.com/SamGu-NRX/house-scanning/pull/6) | `t3/research` | `a7d91f16` | no | 4 success | 2026-09-26 02:11 CDT |
| [#4](https://github.com/SamGu-NRX/house-scanning/pull/4) | `t3/scoring-harness` | `77ce830d` | no | 5 success | 2026-09-26 03:17 CDT |

## S1 Evals on real data

`origin/t3/evals` at [`b5ca7af8`](https://github.com/SamGu-NRX/house-scanning/tree/b5ca7af816cf09da6deb9e480e00719031f0643c). 2 met, 2 partial, 1 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S1-1 | One command regenerates every number from a clean checkout | partial | make drift at b5ca7af from a clean worktree reproduced advio_drift.md and advio_drift.json byte for byte (85 MB peak). ETH3D recon not rerun: it loads the laser scans, whose memory has not been bounded on this shared Mac. |
| S1-2 | Dataset URLs and sha256 recorded | met | all 2 found [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/README.md) |
| S1-3 | Metric code tested on hand-computed cases | not run | slow; run with --slow |
| S1-4 | ADVIO drift report, median and p90 inches after 3, 10, 20 and 30 ft | met | all 5 found [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/README.md), [experiments/evals/results/advio_drift.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/results/advio_drift.md), [experiments/evals/results/eth3d_recon.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/results/eth3d_recon.md) |
| S1-5 | ETH3D errors per model (median and p90 inches for 1-3 m and 3-10 m pairs, scale error %) with a verdict per question | partial | found 1-3 m row, 3-10 m row, scale error; missing verdict [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/README.md), [experiments/evals/results/eth3d_recon.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/results/eth3d_recon.md), [experiments/evals/results/frames.md](https://github.com/SamGu-NRX/house-scanning/blob/b5ca7af816cf09da6deb9e480e00719031f0643c/experiments/evals/results/frames.md) |

## S2 Server and solver

`origin/t3/server` at [`6a623d8a`](https://github.com/SamGu-NRX/house-scanning/tree/6a623d8a7e340c15072efa412dd34738818e4f7e). 4 met, 1 partial, 2 not run, 1 no evidence yet.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S2-1 | pytest green | not run | slow; run with --slow |
| S2-2 | Every public golden test 01-14 of docs/research/t3-lane-c-review.md present | met | all 14 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/tests/test_golden_public.py) |
| S2-3 | Property tests: missing coverage never passes, equality is unsure, left/right mirror, larger clearance never turns pass into fail | partial | found missing coverage, mirror; missing equality unsure, larger clearance [server/tests/test_properties.py](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/tests/test_properties.py) |
| S2-4 | Schemas published | met | present at 6a623d8a [server/schemas/scene.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/schemas/scene.schema.json), [server/schemas/result.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/schemas/result.schema.json) |
| S2-5 | Schemas validated in tests | met | all 2 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/tests/test_golden_public.py), [server/tests/test_schemas.py](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/tests/test_schemas.py), [server/tests/test_api.py](https://github.com/SamGu-NRX/house-scanning/blob/6a623d8a7e340c15072efa412dd34738818e4f7e/server/tests/test_api.py) |
| S2-6 | A real-derived scene returns a result in under 1 s | no evidence yet | no latency_ms in ~/house-scanning-data/reports/e2e/20260926-042213-6a623d8a/report.json |
| S2-7 | ruff clean | not run | slow; run with --slow |
| S2-8 | Black-box (verification e2e): every answer valid under C2, consistent with its decision and the C5 margin rule, never passing unobserved ground or wall, deterministic, symmetric when mirrored, and never passing without coverage | met | contract_problem_count = 0 (want 0): ~/house-scanning-data/reports/e2e/20260926-042213-6a623d8a/report.json |

## S3 iOS capture app

`origin/t3/ios-mvf` at [`90c01dde`](https://github.com/SamGu-NRX/house-scanning/tree/90c01ddef93bdc7abef6a0520c41025bf8fc33be). 2 met, 3 partial, 2 gap, 1 stale, 1 not run, 1 no evidence yet.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S3-1 | CI build green | not run | iOS build: pending at 90c01dde [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-2 | Built as Swift 6 with strict concurrency | met | all 2 found [ios/project.yml](https://github.com/SamGu-NRX/house-scanning/blob/90c01ddef93bdc7abef6a0520c41025bf8fc33be/ios/project.yml) |
| S3-3 | Zero build warnings | stale | report for 6885b7b5, ref at 90c01dde: ~/house-scanning-data/reports/sim/20260926-031352-t3-ios-mvf-6885b7b5-replay/report.json |
| S3-4 | Unit tests for coverage, auto-capture and guidance | partial | found coverage; missing auto-capture, guidance [ios/HouseScanKit/Tests/HouseScanKitTests/AutoCaptureTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/90c01ddef93bdc7abef6a0520c41025bf8fc33be/ios/HouseScanKit/Tests/HouseScanKitTests/AutoCaptureTests.swift), [ios/HouseScanKit/Tests/HouseScanKitTests/SceneExportTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/90c01ddef93bdc7abef6a0520c41025bf8fc33be/ios/HouseScanKit/Tests/HouseScanKitTests/SceneExportTests.swift), [ios/HouseScanKit/Tests/HouseScanKitTests/ServerGapTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/90c01ddef93bdc7abef6a0520c41025bf8fc33be/ios/HouseScanKit/Tests/HouseScanKitTests/ServerGapTests.swift) |
| S3-5 | UI tests run the whole flow from a real replay with no manual input, including one gap-instruction-recapture loop | partial | all 3 found (the tests exist; passing is S3-1) [ios/HouseScanUITests/FullFlowUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/90c01ddef93bdc7abef6a0520c41025bf8fc33be/ios/HouseScanUITests/FullFlowUITests.swift) |
| S3-6 | Accessibility audit on every screen | partial | 2 matches in 1 files (an audit exists; which screens it covers needs a read) [ios/HouseScanUITests/FullFlowUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/90c01ddef93bdc7abef6a0520c41025bf8fc33be/ios/HouseScanUITests/FullFlowUITests.swift) |
| S3-6b | Independent accessibility audit (verification a11yaudit: Apple's audit on each screen the run reached, plus symbol-name button labels) finds no issues; S4-2 shows how many screens the app reached | no evidence yet | no report matches ~/house-scanning-data/reports/a11y/*t3-ios-mvf*/report.json |
| S3-7 | Screenshots of each state in the PR | gap | 0 of 9 matches in the PR body [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-8 | Exported scene.json validates against C1 | met | app_export_scene_valid = true (want True): ~/house-scanning-data/reports/e2e/20260926-041009-b04558df/report.json |
| S3-9 | Design self-review against frontend-design, emil-design-eng, holistic-ux, apple-design | gap | not yet reviewed |

## S4 Verification

`origin/t3/verification` at [`1330a827`](https://github.com/SamGu-NRX/house-scanning/tree/1330a82758df3a007fede909936542f5fb3fb358), `origin/t3/ios-mvf` at [`90c01dde`](https://github.com/SamGu-NRX/house-scanning/tree/90c01ddef93bdc7abef6a0520c41025bf8fc33be). 2 met, 1 partial, 1 stale.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S4-1 | End to end from a real replay to a placement result passes | met | app_export_passed = true (want True): ~/house-scanning-data/reports/e2e/20260926-041009-b04558df/report.json |
| S4-2 | Screenshot report per app state | stale | report for 6885b7b5, ref at 90c01dde: ~/house-scanning-data/reports/sim/20260926-031352-t3-ios-mvf-6885b7b5-replay/report.json |
| S4-3 | Product description written from the code and checked against screenshots | partial | verification/product: scope, glossary, both foundations and the pilot drafted from S3's integration commit 21a63e7; one Simulator pass recorded (verification.md); 7 suspected defects in bug-triage.md. Seven screen documents to go. |
| S4-4 | Scoreboard of every PR | met | present at 1330a827 [verification/SCOREBOARD.md](https://github.com/SamGu-NRX/house-scanning/blob/1330a82758df3a007fede909936542f5fb3fb358/verification/SCOREBOARD.md) |

## M Maintenance

`origin/t3/docs-cleanup` at [`9c9ceb2a`](https://github.com/SamGu-NRX/house-scanning/tree/9c9ceb2a608e9762bd002f20f1b979694bb0c92f). 1 met, 1 gap.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| M-1 | AGENTS.md shorter than on main | met | exit 0: AGENTS.md 39 lines, main 45 |
| M-2 | AGENTS.md accurate, every path and command real | gap | not yet reviewed |
