# Scoreboard

Generated 2026-09-26 07:19 CDT by `make scoreboard` (`uv run python -m hsverify.scoreboard`) in `verification/`; slow probes not run (add ARGS=--slow). Probes are defined in `verification/scoreboard/metrics.yaml`.

## Open pull requests

| # | Branch | Head | Draft | CI | Updated |
| --- | --- | --- | --- | --- | --- |
| [#17](https://github.com/SamGu-NRX/house-scanning/pull/17) | `t3/panel-label` | `2dc7a4f1` | yes | 2 success | 2026-09-26 07:02 CDT |
| [#16](https://github.com/SamGu-NRX/house-scanning/pull/16) | `t3/meter-closeup` | `944cbe17` | yes | 3 success | 2026-09-26 06:45 CDT |
| [#15](https://github.com/SamGu-NRX/house-scanning/pull/15) | `t3/web-review` | `a7c9b129` | yes | 3 success, 3 failure; failing: Label PR size, Web checks, Vercel | 2026-09-26 06:08 CDT |
| [#14](https://github.com/SamGu-NRX/house-scanning/pull/14) | `t3/docs-cleanup` | `ab03d7fd` | no | 4 success | 2026-09-26 05:17 CDT |
| [#13](https://github.com/SamGu-NRX/house-scanning/pull/13) | `t3/verification` | `30e866c6` | yes | 2 success | 2026-09-26 06:28 CDT |
| [#12](https://github.com/SamGu-NRX/house-scanning/pull/12) | `t3/evals` | `d64be59f` | yes | 3 success | 2026-09-26 07:14 CDT |
| [#11](https://github.com/SamGu-NRX/house-scanning/pull/11) | `t3/server` | `739fb6f7` | no | 3 success | 2026-09-26 06:35 CDT |
| [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) | `t3/ios-mvf` | `a39d0a50` | no | 2 success, 1 pending | 2026-09-26 07:11 CDT |
| [#9](https://github.com/SamGu-NRX/house-scanning/pull/9) | `codex/capture-contract-probe` | `4b6c4309` | yes | 4 success | 2026-09-26 00:08 CDT |
| [#8](https://github.com/SamGu-NRX/house-scanning/pull/8) | `t3/testflight` | `b896d59f` | no | 4 success | 2026-09-26 03:18 CDT |
| [#7](https://github.com/SamGu-NRX/house-scanning/pull/7) | `t3/measure-lab` | `45770a3b` | no | 6 success | 2026-09-26 03:19 CDT |
| [#6](https://github.com/SamGu-NRX/house-scanning/pull/6) | `t3/research` | `9737e3f0` | no | 4 success | 2026-09-26 05:13 CDT |
| [#4](https://github.com/SamGu-NRX/house-scanning/pull/4) | `t3/scoring-harness` | `77ce830d` | no | 5 success | 2026-09-26 03:17 CDT |

## S1 Evals on real data

`origin/t3/evals` at [`d64be59f`](https://github.com/SamGu-NRX/house-scanning/tree/d64be59f7850fabaa86b0c08cf6a5003e66ab007). 2 met, 2 partial, 1 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S1-1 | One command regenerates every number from a clean checkout | partial | make drift at b5ca7af from a clean worktree reproduced advio_drift.md and advio_drift.json byte for byte (85 MB peak). ETH3D recon not rerun: it loads the laser scans, whose memory has not been bounded on this shared Mac. |
| S1-2 | Dataset URLs and sha256 recorded | met | all 2 found [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/README.md) |
| S1-3 | Metric code tested on hand-computed cases | not run | slow; run with --slow |
| S1-4 | ADVIO drift report, median and p90 inches after 3, 10, 20 and 30 ft | met | all 5 found [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/README.md), [experiments/evals/results/advio_drift.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/results/advio_drift.md), [experiments/evals/results/modern_arkit.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/results/modern_arkit.md) |
| S1-5 | ETH3D errors per model (median and p90 inches for 1-3 m and 3-10 m pairs, scale error %) with a verdict per question | partial | found 1-3 m row, 3-10 m row, scale error; missing verdict [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/README.md), [experiments/evals/results/eth3d_recon.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/results/eth3d_recon.md), [experiments/evals/results/eth3d_visibility_sensitivity.md](https://github.com/SamGu-NRX/house-scanning/blob/d64be59f7850fabaa86b0c08cf6a5003e66ab007/experiments/evals/results/eth3d_visibility_sensitivity.md) |

## S2 Server and solver

`origin/t3/server` at [`739fb6f7`](https://github.com/SamGu-NRX/house-scanning/tree/739fb6f747294b7253eb7d8936315392a80d178a). 4 met, 1 partial, 1 gap, 2 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S2-1 | pytest green | not run | slow; run with --slow |
| S2-2 | Every public golden test 01-14 of docs/research/t3-lane-c-review.md present | met | all 14 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/tests/test_golden_public.py) |
| S2-3 | Property tests: missing coverage never passes, equality is unsure, left/right mirror, larger clearance never turns pass into fail | partial | found missing coverage, mirror; missing equality unsure, larger clearance [server/tests/test_coderabbit_review.py](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/tests/test_coderabbit_review.py), [server/tests/test_properties.py](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/tests/test_properties.py) |
| S2-4 | Schemas published | met | present at 739fb6f7 [server/schemas/scene.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/schemas/scene.schema.json), [server/schemas/result.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/schemas/result.schema.json) |
| S2-5 | Schemas validated in tests | met | all 2 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/tests/test_golden_public.py), [server/tests/test_schemas.py](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/tests/test_schemas.py), [server/tests/test_api.py](https://github.com/SamGu-NRX/house-scanning/blob/739fb6f747294b7253eb7d8936315392a80d178a/server/tests/test_api.py) |
| S2-6 | A real-derived scene returns a result in under 1 s | met | latency_ms = 364.2 (want < 1000) at sha 739fb6f7: ~/house-scanning-data/reports/e2e/20260926-071717-739fb6f7/report.json |
| S2-7 | ruff clean | not run | slow; run with --slow |
| S2-8 | Black-box (verification e2e at this SHA): results valid under C2, consistent with the decision and C5 margins, coverage to each check's required radius, missing evidence complete, ordering properties, hostile inputs refused in time | gap | contract_problem_count = 12 (want 0) at sha 739fb6f7: ~/house-scanning-data/reports/e2e/20260926-071717-739fb6f7/report.json |

## S3 iOS capture app

`origin/t3/ios-mvf` at [`a39d0a50`](https://github.com/SamGu-NRX/house-scanning/tree/a39d0a503412d688dd151f628cdeebc00f8221b6). 4 met, 3 partial, 2 gap, 1 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S3-1 | CI build green | not run | iOS build: pending at a39d0a50 [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-2 | Built as Swift 6 with strict concurrency | met | all 2 found [ios/project.yml](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/project.yml) |
| S3-3 | Zero build warnings | met | build.warnings = length 0 (want 0) at sha a39d0a50: ~/house-scanning-data/reports/sim/20260926-071459-t3-ios-mvf-a39d0a50-replay/report.json |
| S3-4 | Unit tests for coverage, auto-capture and guidance | partial | found coverage; missing auto-capture, guidance [ios/HouseScanKit/Tests/HouseScanKitTests/AutoCaptureTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanKit/Tests/HouseScanKitTests/AutoCaptureTests.swift), [ios/HouseScanKit/Tests/HouseScanKitTests/SceneExportTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanKit/Tests/HouseScanKitTests/SceneExportTests.swift), [ios/HouseScanKit/Tests/HouseScanKitTests/ServerGapTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanKit/Tests/HouseScanKitTests/ServerGapTests.swift) |
| S3-5 | UI tests run the whole flow from a real replay with no manual input, including one gap-instruction-recapture loop | partial | all 3 found (the tests exist; passing is S3-1) [ios/HouseScanUITests/FullFlowUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanUITests/FullFlowUITests.swift), [ios/HouseScanUITests/ScreenStatesUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanUITests/ScreenStatesUITests.swift) |
| S3-6 | Accessibility audit on every screen | partial | 3 matches in 2 files (an audit exists; which screens it covers needs a read) [ios/HouseScanUITests/FullFlowUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanUITests/FullFlowUITests.swift), [ios/HouseScanUITests/ScreenStatesUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/a39d0a503412d688dd151f628cdeebc00f8221b6/ios/HouseScanUITests/ScreenStatesUITests.swift) |
| S3-6b | Independent accessibility audit (verification a11yaudit: Apple's audit on each screen the run reached, at least nine, plus symbol-name button labels) finds no issues | gap | issue_count = 10 (want 0) at sha a39d0a50: ~/house-scanning-data/reports/a11y/20260926-071248-t3-ios-mvf-a39d0a50-head-sample/report.json |
| S3-7 | Screenshots of each state in the PR | met | 18 of 9 matches in the PR body [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-8 | Exported scene.json validates against C1 | met | app_export_scene_valid = true (want True) at app_sha a39d0a50: ~/house-scanning-data/reports/e2e/20260926-071717-739fb6f7/report.json |
| S3-9 | Design self-review against frontend-design, emil-design-eng, holistic-ux, apple-design | gap | not yet reviewed |

## S4 Verification

`origin/t3/ios-mvf` at [`a39d0a50`](https://github.com/SamGu-NRX/house-scanning/tree/a39d0a503412d688dd151f628cdeebc00f8221b6), `origin/t3/verification` at [`30e866c6`](https://github.com/SamGu-NRX/house-scanning/tree/30e866c6d0c835c025dfa050d339d7b6ff350e69). 3 met, 1 gap.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S4-1 | End to end from a real replay to a placement result passes | gap | app_export_passed = false (want True) at app_sha a39d0a50: ~/house-scanning-data/reports/e2e/20260926-071717-739fb6f7/report.json |
| S4-2 | Screenshot report per app state | met | states = length 10 (want at least 9) at sha a39d0a50: ~/house-scanning-data/reports/sim/20260926-071459-t3-ios-mvf-a39d0a50-replay/report.json |
| S4-3 | Product description written from the code and checked against screenshots | met | verification/product covers every screen of t3/ios-mvf at a39d0a5, checked in the Simulator there with the real server's result (verification.md); bug-triage.md has 16 entries, 3 resolved; ux/review.md judges every state. |
| S4-4 | Scoreboard of every PR | met | present at 30e866c6 [verification/SCOREBOARD.md](https://github.com/SamGu-NRX/house-scanning/blob/30e866c6d0c835c025dfa050d339d7b6ff350e69/verification/SCOREBOARD.md) |

## M Maintenance

`origin/t3/docs-cleanup` at [`ab03d7fd`](https://github.com/SamGu-NRX/house-scanning/tree/ab03d7fd735884346f9182e3cb4cbf4aee60994a). 1 met, 1 gap.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| M-1 | AGENTS.md shorter than on main | met | exit 0: AGENTS.md 39 lines, main 45 |
| M-2 | AGENTS.md accurate, every path and command real | gap | not yet reviewed |
