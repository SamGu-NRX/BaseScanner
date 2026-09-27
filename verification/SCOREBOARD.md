# Scoreboard

Generated 2026-09-26 22:39 CDT by `make scoreboard` (`uv run python -m hsverify.scoreboard`) in `verification/`; slow probes not run (add ARGS=--slow). Probes are defined in `verification/scoreboard/metrics.yaml`.

## Open pull requests

| # | Branch | Head | Draft | CI | Updated |
| --- | --- | --- | --- | --- | --- |
| [#86](https://github.com/SamGu-NRX/house-scanning/pull/86) | `t3/experience` | `8bbef71d` | yes | 2 success | 2026-09-26 22:26 CDT |
| [#61](https://github.com/SamGu-NRX/house-scanning/pull/61) | `t3/app-review-docs` | `6059eae6` | no | 2 success | 2026-09-26 21:51 CDT |
| [#60](https://github.com/SamGu-NRX/house-scanning/pull/60) | `t3/device-test-4.1-analysis` | `c566490c` | no | 2 success | 2026-09-26 22:39 CDT |
| [#59](https://github.com/SamGu-NRX/house-scanning/pull/59) | `t3/signals-lab` | `0cde05e3` | yes | 2 success | 2026-09-26 21:38 CDT |
| [#58](https://github.com/SamGu-NRX/house-scanning/pull/58) | `t3/ios-ci-no-preboot` | `3c1298ab` | no | 2 success, 1 failure; failing: iOS build | 2026-09-26 22:18 CDT |
| [#56](https://github.com/SamGu-NRX/house-scanning/pull/56) | `t3/walk-guidance-gaps` | `cae4f426` | no | 3 success | 2026-09-26 22:18 CDT |
| [#55](https://github.com/SamGu-NRX/house-scanning/pull/55) | `t3/motion-permission` | `9607a481` | no | 2 success, 1 failure; failing: iOS build | 2026-09-26 22:23 CDT |
| [#52](https://github.com/SamGu-NRX/house-scanning/pull/52) | `t3/battery-mark` | `68a66a82` | no | 2 success, 1 failure; failing: iOS build | 2026-09-26 20:42 CDT |
| [#49](https://github.com/SamGu-NRX/house-scanning/pull/49) | `t3/gap-skip-continues` | `ce901122` | no | 3 success | 2026-09-26 22:18 CDT |
| [#46](https://github.com/SamGu-NRX/house-scanning/pull/46) | `t3/field-test-run2` | `afd02c82` | no | 2 success | 2026-09-26 17:36 CDT |
| [#23](https://github.com/SamGu-NRX/house-scanning/pull/23) | `t3/device-field-test` | `321ea7e2` | no | 2 success | 2026-09-26 19:39 CDT |
| [#22](https://github.com/SamGu-NRX/house-scanning/pull/22) | `t3/packet` | `b2fefa56` | no | 2 success | 2026-09-26 21:44 CDT |
| [#21](https://github.com/SamGu-NRX/house-scanning/pull/21) | `t3/ios-map3d` | `6f883d8b` | yes | 2 success | 2026-09-26 22:37 CDT |
| [#20](https://github.com/SamGu-NRX/house-scanning/pull/20) | `t3/recon` | `6573a79c` | yes | 3 success | 2026-09-26 21:50 CDT |
| [#18](https://github.com/SamGu-NRX/house-scanning/pull/18) | `codex/research-findings` | `bd4a7d38` | no | 2 success | 2026-09-26 16:21 CDT |
| [#16](https://github.com/SamGu-NRX/house-scanning/pull/16) | `t3/meter-closeup` | `b199613b` | no | 4 success | 2026-09-26 22:26 CDT |
| [#13](https://github.com/SamGu-NRX/house-scanning/pull/13) | `t3/verification` | `e0e3ae6e` | no | 3 success | 2026-09-26 22:36 CDT |
| [#12](https://github.com/SamGu-NRX/house-scanning/pull/12) | `t3/evals` | `190ed339` | no | 3 success | 2026-09-26 19:16 CDT |
| [#11](https://github.com/SamGu-NRX/house-scanning/pull/11) | `t3/server` | `6c7ca23b` | no | 3 success | 2026-09-26 22:37 CDT |
| [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) | `t3/ios-mvf` | `4b71161d` | no | 2 success, 2 pending | 2026-09-26 22:37 CDT |
| [#9](https://github.com/SamGu-NRX/house-scanning/pull/9) | `codex/capture-contract-probe` | `4b6c4309` | yes | 4 success | 2026-09-26 00:08 CDT |
| [#7](https://github.com/SamGu-NRX/house-scanning/pull/7) | `t3/measure-lab` | `7b3ddcc0` | no | 4 success | 2026-09-26 22:27 CDT |
| [#4](https://github.com/SamGu-NRX/house-scanning/pull/4) | `t3/scoring-harness` | `0f3e7532` | no | 3 success | 2026-09-26 22:25 CDT |

## S1 Evals on real data

`origin/t3/evals` at [`190ed339`](https://github.com/SamGu-NRX/house-scanning/tree/190ed339f41924ae0244e0b88c5ebe647ddd9eb4). 2 met, 2 partial, 1 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S1-1 | One command regenerates every number from a clean checkout | partial | make drift at b5ca7af from a clean worktree reproduced advio_drift.md and advio_drift.json byte for byte (85 MB peak). ETH3D recon not rerun: it loads the laser scans, whose memory has not been bounded on this shared Mac. |
| S1-2 | Dataset URLs and sha256 recorded | met | all 2 found [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/README.md) |
| S1-3 | Metric code tested on hand-computed cases | not run | slow; run with --slow |
| S1-4 | ADVIO drift report, median and p90 inches after 3, 10, 20 and 30 ft | met | all 5 found [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/README.md), [experiments/evals/field/FIELD_SHEET.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/field/FIELD_SHEET.md), [experiments/evals/results/advio_drift.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/results/advio_drift.md) |
| S1-5 | ETH3D errors per model (median and p90 inches for 1-3 m and 3-10 m pairs, scale error %) with a verdict per question | partial | found 1-3 m row, 3-10 m row, scale error; missing verdict [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/README.md), [experiments/evals/results/eth3d_recon.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/results/eth3d_recon.md), [experiments/evals/results/eth3d_visibility_sensitivity.md](https://github.com/SamGu-NRX/house-scanning/blob/190ed339f41924ae0244e0b88c5ebe647ddd9eb4/experiments/evals/results/eth3d_visibility_sensitivity.md) |

## S2 Server and solver

`origin/t3/server` at [`6c7ca23b`](https://github.com/SamGu-NRX/house-scanning/tree/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75). 5 met, 1 partial, 2 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S2-1 | pytest green | not run | slow; run with --slow |
| S2-2 | Every public golden test 01-14 of docs/research/t3-lane-c-review.md present | met | all 14 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/tests/test_golden_public.py) |
| S2-3 | Property tests: missing coverage never passes, equality is unsure, left/right mirror, larger clearance never turns pass into fail | partial | found missing coverage, mirror; missing equality unsure, larger clearance [server/tests/test_coderabbit_review.py](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/tests/test_coderabbit_review.py), [server/tests/test_properties.py](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/tests/test_properties.py) |
| S2-4 | Schemas published | met | present at 6c7ca23b [server/schemas/scene.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/schemas/scene.schema.json), [server/schemas/result.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/schemas/result.schema.json) |
| S2-5 | Schemas validated in tests | met | all 2 found [server/tests/test_existing_battery.py](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/tests/test_existing_battery.py), [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/tests/test_golden_public.py), [server/tests/test_schemas.py](https://github.com/SamGu-NRX/house-scanning/blob/6c7ca23b63a5493e5a4224af0a5d12d025f3ba75/server/tests/test_schemas.py) |
| S2-6 | A real-derived scene returns a result in under 1 s | met | latency_ms = 171.6 (want < 1000) at sha 6c7ca23b: ~/house-scanning-data/reports/e2e/20260926-223908-6c7ca23b/report.json |
| S2-7 | ruff clean | not run | slow; run with --slow |
| S2-8 | Black-box (verification e2e at this SHA): results valid under C2, consistent with the decision and C5 margins, coverage to each check's required radius, missing evidence complete, ordering properties, hostile inputs refused in time | met | contract_ok = true (want True) at sha 6c7ca23b: ~/house-scanning-data/reports/e2e/20260926-223908-6c7ca23b/report.json |

## S3 iOS capture app

`origin/t3/ios-mvf` at [`4b71161d`](https://github.com/SamGu-NRX/house-scanning/tree/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672). 2 met, 3 partial, 1 gap, 3 stale, 1 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S3-1 | CI build green | not run | iOS build: pending at 4b71161d [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-2 | Built as Swift 6 with strict concurrency | met | all 2 found [ios/project.yml](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/project.yml) |
| S3-3 | Zero build warnings | stale | report for sha 194f2ebf, ref at 4b71161d: ~/house-scanning-data/reports/sim/20260926-121648-t3-ios-mvf-194f2ebf-replay/report.json |
| S3-4 | Unit tests for coverage, auto-capture and guidance | partial | found coverage, guidance; missing auto-capture [ios/HouseScanKit/Tests/HouseScanKitTests/AutoCaptureTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanKit/Tests/HouseScanKitTests/AutoCaptureTests.swift), [ios/HouseScanKit/Tests/HouseScanKitTests/GroundPatchTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanKit/Tests/HouseScanKitTests/GroundPatchTests.swift), [ios/HouseScanKit/Tests/HouseScanKitTests/JSONSchemaValidatorTests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanKit/Tests/HouseScanKitTests/JSONSchemaValidatorTests.swift) |
| S3-5 | UI tests run the whole flow from a real replay with no manual input, including one gap-instruction-recapture loop | partial | all 3 found (the tests exist; passing is S3-1) [ios/HouseScanUITests/FullFlowUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanUITests/FullFlowUITests.swift), [ios/HouseScanUITests/SourceRestartUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanUITests/SourceRestartUITests.swift), [ios/HouseScanUITests/ScreenStatesUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanUITests/ScreenStatesUITests.swift) |
| S3-6 | Accessibility audit on every screen | partial | 3 matches in 2 files (an audit exists; which screens it covers needs a read) [ios/HouseScanUITests/FullFlowUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanUITests/FullFlowUITests.swift), [ios/HouseScanUITests/ScreenStatesUITests.swift](https://github.com/SamGu-NRX/house-scanning/blob/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672/ios/HouseScanUITests/ScreenStatesUITests.swift) |
| S3-6b | Independent accessibility audit (verification a11yaudit: Apple's audit on each screen the run reached, at least nine, plus symbol-name button labels) finds no issues | stale | report for sha a39d0a50, ref at 4b71161d: ~/house-scanning-data/reports/a11y/20260926-071248-t3-ios-mvf-a39d0a50-head-sample/report.json |
| S3-7 | Screenshots of each state in the PR | met | 18 of 9 matches in the PR body [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-8 | Exported scene.json validates against C1 | stale | report for app_sha 194f2ebf, ref at 4b71161d: ~/house-scanning-data/reports/e2e/20260926-223908-6c7ca23b/report.json |
| S3-9 | Design self-review against frontend-design, emil-design-eng, holistic-ux, apple-design | gap | not yet reviewed |

## S4 Verification

`origin/t3/ios-mvf` at [`4b71161d`](https://github.com/SamGu-NRX/house-scanning/tree/4b71161d3bcc0b5d8ffd8fe438899f9fbe0fd672), `origin/t3/verification` at [`e0e3ae6e`](https://github.com/SamGu-NRX/house-scanning/tree/e0e3ae6e49c996cee123ec8759cc6bea305d5730). 2 met, 2 stale.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S4-1 | End to end from a real replay to a placement result passes | stale | report for app_sha 194f2ebf, ref at 4b71161d: ~/house-scanning-data/reports/e2e/20260926-223908-6c7ca23b/report.json |
| S4-2 | Screenshot report per app state | stale | report for sha 194f2ebf, ref at 4b71161d: ~/house-scanning-data/reports/sim/20260926-121648-t3-ios-mvf-194f2ebf-replay/report.json |
| S4-3 | Product description written from the code and checked against screenshots | met | docs/app-review/product (#61) covers every screen of t3/ios-mvf at a39d0a5, checked in the Simulator there with the real server's result; its bug triage has 16 entries, 3 resolved; docs/app-review/ux/review.md judges every state. |
| S4-4 | Scoreboard of every PR | met | present at e0e3ae6e [verification/SCOREBOARD.md](https://github.com/SamGu-NRX/house-scanning/blob/e0e3ae6e49c996cee123ec8759cc6bea305d5730/verification/SCOREBOARD.md) |

## M Maintenance

`origin/t3/docs-cleanup` at [`3c0dd56c`](https://github.com/SamGu-NRX/house-scanning/tree/3c0dd56c4e74ec872de7a1904c7d9a9a5b860705). 2 gap.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| M-1 | AGENTS.md shorter than on main | gap | exit 1: AGENTS.md 59 lines, main 59 |
| M-2 | AGENTS.md accurate, every path and command real | gap | not yet reviewed |
