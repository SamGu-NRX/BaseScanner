# Scoreboard

Generated 2026-09-26 03:21 CDT by `make scoreboard` (`uv run python -m hsverify.scoreboard`) in `verification/`; slow probes not run (add ARGS=--slow). Probes are defined in `verification/scoreboard/metrics.yaml`.

## Open pull requests

| # | Branch | Head | Draft | CI | Updated |
| --- | --- | --- | --- | --- | --- |
| [#14](https://github.com/SamGu-NRX/house-scanning/pull/14) | `t3/docs-cleanup` | `9c9ceb2a` | no | 4 success | 2026-09-26 03:15 CDT |
| [#13](https://github.com/SamGu-NRX/house-scanning/pull/13) | `t3/verification` | `328373d8` | yes | 4 success | 2026-09-26 03:19 CDT |
| [#12](https://github.com/SamGu-NRX/house-scanning/pull/12) | `t3/evals` | `b0b8a274` | yes | 4 success | 2026-09-26 03:11 CDT |
| [#11](https://github.com/SamGu-NRX/house-scanning/pull/11) | `t3/server` | `fcd45741` | yes | 4 success, 1 pending | 2026-09-26 03:20 CDT |
| [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) | `t3/ios-mvf` | `6885b7b5` | yes | 5 success | 2026-09-26 03:07 CDT |
| [#9](https://github.com/SamGu-NRX/house-scanning/pull/9) | `codex/capture-contract-probe` | `4b6c4309` | yes | 4 success | 2026-09-26 00:08 CDT |
| [#8](https://github.com/SamGu-NRX/house-scanning/pull/8) | `t3/testflight` | `b896d59f` | no | 4 success | 2026-09-26 03:18 CDT |
| [#7](https://github.com/SamGu-NRX/house-scanning/pull/7) | `t3/measure-lab` | `45770a3b` | no | 6 success | 2026-09-26 03:19 CDT |
| [#6](https://github.com/SamGu-NRX/house-scanning/pull/6) | `t3/research` | `a7d91f16` | no | 4 success | 2026-09-26 02:11 CDT |
| [#4](https://github.com/SamGu-NRX/house-scanning/pull/4) | `t3/scoring-harness` | `77ce830d` | no | 5 success | 2026-09-26 03:17 CDT |

## S1 Evals on real data

`origin/t3/evals` at [`b0b8a274`](https://github.com/SamGu-NRX/house-scanning/tree/b0b8a2745e3ea67cb8f70df3943177e146f591b9). 1 met, 1 partial, 2 gap, 1 not run.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S1-1 | One command regenerates every number from a clean checkout | gap | not yet reviewed |
| S1-2 | Dataset URLs and sha256 recorded | partial | found ADVIO; missing ETH3D [experiments/evals/README.md](https://github.com/SamGu-NRX/house-scanning/blob/b0b8a2745e3ea67cb8f70df3943177e146f591b9/experiments/evals/README.md) |
| S1-3 | Metric code tested on hand-computed cases | not run | slow; run with --slow |
| S1-4 | ADVIO drift report, median and p90 inches after 3, 10, 20 and 30 ft | met | all 5 found [experiments/evals/results/advio_drift.md](https://github.com/SamGu-NRX/house-scanning/blob/b0b8a2745e3ea67cb8f70df3943177e146f591b9/experiments/evals/results/advio_drift.md) |
| S1-5 | ETH3D errors per model (median and p90 inches for 1-3 m and 3-10 m pairs, scale error %) with a verdict per question | gap | none found in 2 files; missing 1-3 m row, 3-10 m row, scale error, verdict |

## S2 Server and solver

`origin/t3/server` at [`fcd45741`](https://github.com/SamGu-NRX/house-scanning/tree/fcd457411a68171509d53b87b11c115f55a2a765). 3 met, 1 gap, 2 not run, 1 no evidence yet.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S2-1 | pytest green | not run | slow; run with --slow |
| S2-2 | Every public golden test 01-14 of docs/research/t3-lane-c-review.md present | met | all 14 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/fcd457411a68171509d53b87b11c115f55a2a765/server/tests/test_golden_public.py) |
| S2-3 | Property tests: missing coverage never passes, equality is unsure, left/right mirror, larger clearance never turns pass into fail | gap | none found in 5 files; missing missing coverage, equality unsure, mirror, larger clearance |
| S2-4 | Schemas published | met | present at fcd45741 [server/schemas/scene.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/fcd457411a68171509d53b87b11c115f55a2a765/server/schemas/scene.schema.json), [server/schemas/result.schema.json](https://github.com/SamGu-NRX/house-scanning/blob/fcd457411a68171509d53b87b11c115f55a2a765/server/schemas/result.schema.json) |
| S2-5 | Schemas validated in tests | met | all 2 found [server/tests/test_golden_public.py](https://github.com/SamGu-NRX/house-scanning/blob/fcd457411a68171509d53b87b11c115f55a2a765/server/tests/test_golden_public.py), [server/tests/test_schemas.py](https://github.com/SamGu-NRX/house-scanning/blob/fcd457411a68171509d53b87b11c115f55a2a765/server/tests/test_schemas.py) |
| S2-6 | A real-derived scene returns a result in under 1 s | no evidence yet | no report matches ~/house-scanning-data/reports/e2e/*/report.json |
| S2-7 | ruff clean | not run | slow; run with --slow |

## S3 iOS capture app

`origin/t3/ios-mvf` at [`6885b7b5`](https://github.com/SamGu-NRX/house-scanning/tree/6885b7b5ad872df7f73a6b915e5837cd38a2034d). 3 met, 5 gap, 1 no evidence yet.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S3-1 | CI build green | met | iOS build: success at 6885b7b5 [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-2 | Built as Swift 6 with strict concurrency | met | all 2 found [ios/project.yml](https://github.com/SamGu-NRX/house-scanning/blob/6885b7b5ad872df7f73a6b915e5837cd38a2034d/ios/project.yml) |
| S3-3 | Zero build warnings | met | build.warnings = length 0 (want 0): ~/house-scanning-data/reports/sim/20260926-031352-t3-ios-mvf-6885b7b5-replay/report.json |
| S3-4 | Unit tests for coverage, auto-capture and guidance | gap | none found in 1 files; missing coverage, auto-capture, guidance |
| S3-5 | UI tests run the whole flow from a real replay with no manual input, including one gap-instruction-recapture loop | gap | none found in 1 files; missing replay argument, autopilot argument, gap loop |
| S3-6 | Accessibility audit on every screen | gap | 0 of 1 matches needed, searched 1 files |
| S3-7 | Screenshots of each state in the PR | gap | 0 of 9 matches in the PR body [#10](https://github.com/SamGu-NRX/house-scanning/pull/10) |
| S3-8 | Exported scene.json validates against C1 | no evidence yet | no report matches ~/house-scanning-data/reports/e2e/*/report.json |
| S3-9 | Design self-review against frontend-design, emil-design-eng, holistic-ux, apple-design | gap | not yet reviewed |

## S4 Verification

`origin/t3/verification` at [`328373d8`](https://github.com/SamGu-NRX/house-scanning/tree/328373d81f280496380c0a9737f1dd0cc3ac50bb), `origin/t3/ios-mvf` at [`6885b7b5`](https://github.com/SamGu-NRX/house-scanning/tree/6885b7b5ad872df7f73a6b915e5837cd38a2034d). 3 gap, 1 no evidence yet.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| S4-1 | End to end from a real replay to a placement result passes | no evidence yet | no report matches ~/house-scanning-data/reports/e2e/*/report.json |
| S4-2 | Screenshot report per app state | gap | states = length 0 (want at least 9): ~/house-scanning-data/reports/sim/20260926-031352-t3-ios-mvf-6885b7b5-replay/report.json |
| S4-3 | Product description written from the code and checked against screenshots | gap | not yet reviewed |
| S4-4 | Scoreboard of every PR | gap | missing at 328373d8: verification/SCOREBOARD.md |

## M Maintenance

`origin/t3/docs-cleanup` at [`9c9ceb2a`](https://github.com/SamGu-NRX/house-scanning/tree/9c9ceb2a608e9762bd002f20f1b979694bb0c92f). 1 met, 1 gap.

| Metric | Text | Status | Evidence |
| --- | --- | --- | --- |
| M-1 | AGENTS.md shorter than on main | met | exit 0: AGENTS.md 39 lines, main 45 |
| M-2 | AGENTS.md accurate, every path and command real | gap | not yet reviewed |
