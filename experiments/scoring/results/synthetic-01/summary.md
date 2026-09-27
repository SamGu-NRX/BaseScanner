# Capture pipeline scores

Rules: `rules.json` (Synthetic scoring fixture. Not a real placement policy.), sha256 `05b466b3436155e190513a21b6333304ad9da4e93f1b5022b1813a433bdb325e`.
1 house, 2 candidate spots, 3 pipeline runs.

Each house's declared scale reference is left out of every error figure: a run that was given it can match it exactly, so its error says nothing about accuracy.

## House synthetic-01

Captures: synthetic-01-walk-1, fc082df094988c98d204aa6fcd98a215f047826a7a4ade11c88c5c735e048686. Candidates: c1, c2. Scale reference `scale` (5.000 ft), excluded.

### Distances

9 distances besides the scale reference; each row's counts add up to it. Errors are absolute, in inches, over the distances both the survey and the run measured. Wrongly absent: the run says the feature is not there, but the survey measured it. Phantom: the run measured a feature the survey found absent.

| Pipeline | Scale source | Scored | Median error (in) | Max error (in) | Survey inside run's ± | Unsupported | Failed | Wrongly absent | Phantom | Absent, agreed | Not surveyed |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `ar-taps` | ar_poses | 6/9 | 3.48 | 4.80 | 3/6 | 0 | 1 | 0 | 0 | 1 | 1 |
| `photo-depth` | native_metric | 6/9 | 12.60 | 24.00 | 5/6 | 1 | 0 | 0 | 1 | 0 | 1 |
| `mesh-scaled` | scale_reference | 5/9 | 1.20 | 6.00 | 4/4 | 0 | 1 | 1 | 0 | 1 | 1 |

### Checks

8 checks, 7 with a survey outcome. The survey passes a check when it clears the pass line by more than its ± and fails it when it misses the fail line by more than its ±. Anything between, including a value exactly on a line, is borderline (one threshold) or review (a band such as review_route_ft to max_route_ft), where the right answer is unsure. Unsafe pass: a pass where the survey fails. Missed review: a pass where the survey is borderline or review. Over-cautious: unsure or fail where the survey passes; false rejections are the fails among them. Decided without its measurement: a pass or fail with the run's measurement missing as failed or unsupported; a claimed absence also cannot support an at_most decision or an at_least fail. It is also scored as usual. An unsure is justified when the survey is borderline or review, or the run's measurement failed or is unsupported. The error could flip a check when it is at least as large as both the survey's distance to the nearest threshold and its ±.

| Pipeline | Agree | Unsafe passes | Missed reviews | Over-cautious | False rejections | Decided without its measurement | Unsure, justified | Unsure, avoidable | Error could flip |
|---|---|---|---|---|---|---|---|---|---|
| `ar-taps` | 4/7 | 1 | 2 | 0 | 0 | 2 | 0 | 0 | 2 |
| `photo-depth` | 2/7 | 0 | 0 | 2 | 1 | 0 | 1 | 1 | 2 |
| `mesh-scaled` | no decisions | n/a | n/a | n/a | n/a | n/a | n/a | n/a | 0 |

### Timing

| Pipeline | Capture (s) | Processing (s) |
|---|---|---|
| `ar-taps` | 420.0 | 12.5 |
| `photo-depth` | 420.0 | 95.0 |
| `mesh-scaled` | 420.0 | not recorded |

### Unsafe passes

- `ar-taps` passed `facing_gap` at `c2`; the survey is fail at 2.500 ± 0.020 ft against `facing_gap_ft` at_least 3.000 ft (run measured no value).

### Missed reviews

- `ar-taps` passed `gas` at `c2`; the survey is borderline at 3.020 ± 0.030 ft against `gas_clearance_ft` at_least 3.000 ft (run measured 3.350 ft).
- `ar-taps` passed `route` at `c2`; the survey is review at 19.900 ± 0.050 ft against `review_route_ft` 15.000 ft and `max_route_ft` at_most 20.000 ft (run measured 19.500 ft).

### Decided without its measurement

- `ar-taps` reported pass for `facing_gap` at `c2` with measurement `c2-facing` missing (failed); the survey is fail at 2.500 ± 0.020 ft against `facing_gap_ft` at_least 3.000 ft.
- `ar-taps` reported fail for `pool` at `c2` with measurement `c2-pool` missing (failed); the survey is unknown (not measured) against `pool_clearance_ft` at_least 5.000 ft.

These are paired results at the listed spots, a case series. They are not an accuracy rate for other homes, validated error bars, or evidence of safety.
