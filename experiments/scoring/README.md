# Scoring capture pipelines against a tape survey

## Question

Take an independent tape survey of a house and each capture pipeline's measurements of the same named distances and candidate spots. How large are the errors? How close are they to the thresholds that decide each check? Which outputs are missing or unsafe?

The scorer answers that for any number of houses and pipeline runs. It does not run a pipeline. Each pipeline writes a results file, and `score` compares that file with the survey.

The protocol behind it (distances to survey, gates, freezing rules before fieldwork) is the research note `docs/research/t3-scoring-protocol.md`. It is not merged yet. This README repeats only what the scorer needs.

## Commands

```sh
cd experiments/scoring
uv sync --locked
uv run score --rules fixtures/rules.json \
  --truth fixtures/truth/synthetic-01.json \
  --results fixtures/results/ar-taps.json fixtures/results/photo-depth.json fixtures/results/mesh-scaled.json
```

`score` prints a markdown summary on stdout and writes `measurements.csv`, `checks.csv` and `runs.csv` to `--out`, which defaults to `data/`. Git ignores `data/`. `--truth` and `--results` each take several files, so shell globs work. Any problem with the inputs stops the run with exit code 2 and a message naming the file, the field and what to change. No CSV is written.

Checks, as in CI:

```sh
uv run ruff check .
uv run ruff format --check .
uv run pytest -q
```

Everything under `fixtures/` is synthetic. Keep real surveys and results beside the real capture in `captures/` or `data/`, never in git.

## Input formats

All three are JSON and start with `"format": 1` and `"unit": "ft"`. Every length is in feet. Numbers are read as exact decimals, so a survey value exactly one tolerance from a threshold lands on the same side every time. In floats, 3.1 minus 3.0 is 0.10000000000000009, which would pass a 3.1 ± 0.1 ft clearance against a 3 ft rule that is exactly borderline. Unknown fields, duplicate keys, `NaN`, negative lengths and numbers written as strings are all rejected. Fields marked "or null" must still be present.

### Rules file

Named thresholds, using the parameter names from `rules.yaml`. Use public or clearly synthetic values only. The unpublished values Base gave the team never go in a tracked file.

```json
{
  "format": 1, "unit": "ft", "name": "Synthetic scoring fixture",
  "thresholds": {
    "gas_clearance_ft": {"value_ft": 3, "pass_when": "at_least", "source": "Public: Base help page"},
    "max_route_ft": {"value_ft": 20, "pass_when": "at_most", "source": "Public: Base help page"}
  }
}
```

| Field | Meaning |
|---|---|
| threshold name | The `rules.yaml` parameter name. Must end in `_ft`. |
| `value_ft` | The threshold. |
| `pass_when` | `at_least` for a clearance (the distance must clear the value), `at_most` for a limit such as route length. Passing is strict: a value exactly on the threshold is borderline, not a pass (see "Survey outcome of a check" below). |
| `source` | Where the number comes from, or `Synthetic placeholder`. |

Each results file carries the sha256 of the exact rules file it was produced under. Any edit to the rules, even whitespace, changes the hash, so a run made under a different policy cannot be scored by mistake. `shasum -a 256 rules.json` prints it.

### Survey file (one per house)

```json
{
  "format": 1, "unit": "ft", "house": "synthetic-01",
  "captures": ["synthetic-01-walk-1"],
  "scale_reference": "scale",
  "candidates": [{"id": "c1", "marker": "Blue painter's tape outline", "location": "South wall, 7 ft 5 in from the SW corner"}],
  "measurements": [
    {"id": "c1-gas", "candidate": "c1", "from": "footprint edge", "to": "gas regulator",
     "status": "measured", "value_ft": 4.500, "plus_minus_ft": 0.010,
     "method": "tape", "measured_by": ["surveyor-a", "surveyor-b"]}
  ],
  "checks": [
    {"candidate": "c1", "check": "gas", "measurement": "c1-gas", "threshold": "gas_clearance_ft"},
    {"candidate": "c1", "check": "route", "measurement": "c1-route",
     "threshold": "max_route_ft", "review_threshold": "review_route_ft"}
  ]
}
```

| Field | Meaning |
|---|---|
| `house` | Unique across the study. |
| `captures` | The recording ids this survey applies to. Use each recording's sha256 as its id, so a run on a re-exported or different recording cannot claim the same capture; the scorer never sees the recording, so it can only compare ids. A LiDAR recording of the same house is a second id here. Each id belongs to one house. |
| `scale_reference` | The id of the one measurement some pipelines may use to set their scale. It must be measured, cannot decide a check, and is never scored. |
| `candidates[]` | `id`, the physical `marker` on the ground, and its `location` as tape offsets from permanent corners. |
| `measurements[].candidate` | The spot it belongs to, or null for house-level distances such as wall length. |
| `measurements[].from`, `to` | The endpoints in words. Say whether a distance starts at the wall or the footprint edge. |
| `measurements[].status` | `measured`, `absent` (the feature does not exist, such as no pool) or `not_measured` (unreachable). Only `measured` has `value_ft` and `plus_minus_ft`. |
| `measurements[].plus_minus_ft` | The survey's own uncertainty, u. |
| `measurements[].method`, `measured_by` | How and by whom. |
| `checks[]` | One pass/fail decision: the spot, a check name, the measurement that decides it and the threshold it is compared with. A measurement can decide more than one check. An absent feature may only decide an `at_least` check, which it passes. Every candidate must have the same check names, so leaving a hard check out at one spot cannot shrink the denominator. |
| `checks[].review_threshold` | Optional. Turns the check into a band: values that clear `review_threshold` pass, values past `threshold` fail, and values between go to review. Both thresholds must pass in the same direction, and the review line must sit on the passing side of `threshold`. The route check uses `review_route_ft` and `max_route_ft`. |

### Results file (one per pipeline run)

```json
{
  "format": 1, "unit": "ft",
  "pipeline": "ar-taps", "capture": "synthetic-01-walk-1",
  "rules_sha256": "<64 hex digits>", "scale_source": "ar_poses",
  "measurements": [
    {"id": "c1-gas", "value_ft": 4.7, "plus_minus_ft": 0.3},
    {"id": "c2-facing", "value_ft": null, "missing": "failed"}
  ],
  "outcomes": [{"candidate": "c1", "check": "gas", "outcome": "pass"}],
  "timing": {"capture_s": 420, "processing_s": 12.5}
}
```

| Field | Meaning |
|---|---|
| `pipeline` | The row name. Each variant (another model, another scale source) is its own pipeline id. |
| `capture` | Must appear in exactly one survey's `captures`. |
| `scale_source` | `native_metric`, `scale_reference` or `ar_poses`. |
| `measurements[]` | One entry for every survey measurement id. The scale reference is optional. `value_ft` is a number or null. With a number, `plus_minus_ft` is the run's reported uncertainty, or null if it reports none. With null, `missing` says why: `unsupported` (the pipeline cannot produce this distance), `failed` (it tried and got nothing) or `absent` (it says the feature is not there). |
| `outcomes` | One entry per survey check: `pass`, `unsure` or `fail`. Report what the pipeline actually decided. A pass or fail whose measurement is missing as `failed` or `unsupported` is accepted, scored as usual and flagged as decided without its measurement. Set the whole field to null for a run that measures distances but makes no decisions. |
| `timing.capture_s`, `processing_s` | Seconds, or null if not recorded. Runs on the same capture must report the same `capture_s` or null. |

## Import a Measure Lab session

`score import-measure-lab` turns a session zip shared from Measure Lab (session format 2, documented in `experiments/measure-lab/README.md` "Session format") into a results file. The rig names its measurements with app-generated ids and reports meters, so the team writes a map file after the walk that ties each survey measurement to what the rig produced.

```sh
uv run score import-measure-lab fixtures/measure-lab/synthetic-session-01.zip \
  --map fixtures/measure-lab/map.json --rules fixtures/rules.json \
  --truth fixtures/truth/synthetic-01.json --out data/measure-lab.json
```

Add `--decide` for a second row that makes decisions (write it to another `--out` file). The importer then computes pass, unsure or fail for every check from the run's own value and uncertainty, with the same strict rule the scorer applies to the survey: pass when the margin is larger than the uncertainty, fail when the miss is larger, unsure otherwise, and unsure whenever there is no value. A feature the operator marked absent passes an `at_least` check. The pipeline id gets a `+rule` suffix so the row is visibly rule-emulated. This emulates the lane C rule until a real solver exists; it says nothing about how the solver will behave.

An excerpt of a map file. A real map has a key for every survey measurement id; `fixtures/measure-lab/map.json` is a complete one.

```json
{
  "format": 1, "unit": "ft",
  "pipeline": "measure-lab",
  "session": "synthetic-session-01",
  "notes": "plus_minus_ft_by_key is docs/02's ±0.3 ft for AR taps, the plan's untested estimate.",
  "plus_minus_ft_by_key": {"straight": 0.3, "alongWall": 0.3, "gapToWall": 0.3},
  "measurements": {
    "wall-length": {"session_measurement": "m2", "key": "alongWall"},
    "c1-gas": {"session_measurement": "m3", "key": "straight", "plus_minus_ft": 0.25},
    "c2-facing": {"refusal": "r1"},
    "c1-pool": "absent",
    "c2-pool": "unsupported"
  }
}
```

| Map entry | Becomes |
|---|---|
| `{"session_measurement": id, "key": k}` | That measurement's `values[k]`, converted to feet. `k` must match the session measurement's `compared` field: `accepted` validates that quantity only. A measurement with `accepted: false` (the rig's own abstention, for example a negative `heightAboveGround`) becomes a null value, missing `failed`. |
| `{"refusal": id}` | The rig tried and refused: a null value, missing `failed`. |
| `"absent"` | The operator saw no such feature: missing `absent`. |
| `"unsupported"` | The rig has no way to measure it: missing `unsupported`. |

The uncertainty must be stated: an entry's own `plus_minus_ft`, or else the entry's key in `plus_minus_ft_by_key`. The code has no default. The ±0.3 ft in the example map is docs/02's figure for AR taps, the plan's untested estimate, not a measured error bar. The scale reference may be left out of the map, as in a results file. `session` must match the zip's session id, so a map cannot be applied to the wrong walk. `notes` is free text.

What the importer writes:

- **Feet.** Meters divided exactly by 0.3048, then rounded half up to 6 decimal places (a millionth of a foot). ARKit is good to centimeters at best, so the rounding is invisible, and it keeps values inside the scorer's 12-decimal limit. `--decide` works on the rounded value, the same one the scorer reads.
- **capture:** the zip's sha256. Add it to the house's `captures` in the survey before importing.
- **rules_sha256:** the rules file's sha256. **scale_source:** `ar_poses`, since ARKit tracking supplies metric scale.
- **capture_s:** from the session's start (`startedAtUptime`) to its last measurement, to the millisecond. **processing_s:** null. The rig shows each value as it is tapped, so there is no processing stage after the walk, and session.json records no time for one.

The importer stops with a specific message, and writes nothing, for:

- a map key that is not a survey measurement id;
- a survey measurement the map leaves out;
- a session measurement or refusal id the session does not have;
- a values key that measurement lacks or that differs from its `compared` field;
- a session format other than version 2;
- a map written for another session;
- an entry with no uncertainty;
- an accepted measurement with a negative value;
- a zip that is not in the survey's captures.

It also scores its own output before saving it, so a file it writes always loads.

The fixture zip is built reproducibly from `fixtures/measure-lab/synthetic-session-01/session.json`. After editing that file, run `uv run python tests/helpers.py rebuild-session-zip` and put the printed sha256 in the survey's captures.

## What the scorer reports

The markdown summary has one section per house. Each section has a distances table, a checks table, a timing table, and every unsafe pass, missed review and decision made without its measurement, listed by name. Nothing is averaged across houses, and a missing output is never averaged away. The CSVs hold one row per run and measurement, per run and check, and per run.

**Distances.** Signed error is run minus survey, in inches, so positive means the run overestimated. The summary gives the median and maximum absolute error over the distances both sides measured. "Survey inside run's ±" counts the scored distances where the absolute error is at most the run's reported uncertainty, out of those where the run reported one. Every survey measurement except the scale reference is in the denominator and lands in exactly one bucket: scored, unsupported, failed, wrongly absent (the run says it is not there, the survey measured it), phantom (the run measured a feature the survey found absent), absent in both, or not surveyed.

**The scale reference is excluded from every error statistic.** A run that was given it can match it exactly, so its error says nothing about accuracy. Its rows appear in `measurements.csv` with status `scale_reference` and no error. The summary says this at the top.

**Survey outcome of a check.** Let s be the survey value's margin on the passing side of the threshold, and u the survey uncertainty. The check passes when s > u, fails when s < −u, and is borderline otherwise. Both comparisons are strict, following `docs/02-implementation-plan.md` "Lane C": "A check answers PASS if the margin is larger than the error." So a value exactly on the threshold is borderline, with or without uncertainty, and so is a value exactly u from it on either side. An absent feature passes. An unmeasured one is unknown and is left out of the decision counts.

A check with a review band follows `docs/02-implementation-plan.md` "Lane C": past the confident reach it is unsure, over the maximum it fails. For the route, with length L and survey uncertainty u:

| Survey | Outcome |
|---|---|
| L + u < `review_route_ft` | pass |
| L − u > `max_route_ft` | fail |
| anything else | review |

So a route exactly on either line is review, including when u = 0. A pipeline should apply the same strict rule with its own ±, as the lane C solver does: pass only when the margin is larger than the error, fail only when the miss is larger than the error. A pipeline that passes a value exactly on a line is counted as a missed review.

**Error relative to the threshold.** The ratio is |error| / max(m, u), where m is the survey value's distance to the nearest threshold. For a band, that is whichever of the two lines is closer, since crossing either changes the outcome. At 1 or above, the run's error could flip the check: an error equal to the margin can put the run exactly on a line, which no longer passes or fails. When m and u are both zero the ratio has no denominator, so the CSV reports `at_threshold`, and any nonzero error counts as a possible flip.

**Decisions.** A correct run passes a passing check, fails a failing one, and says unsure on a borderline or review one. Borderline means the survey itself is unsure. Three wrong answers are counted separately, and each means the same for a single-threshold check and a banded one:

- An unsafe pass is a run's pass where the survey fails. That count matters most.
- A missed review is a run's pass where the survey is borderline or review: the answer needed a person to look.
- Over-caution is a run's unsure or fail where the survey passes. False rejections are the fails among them, listed on their own too.

The protocol note counts a pass on a borderline survey as unsafe. This scorer counts it as a missed review instead, so that "unsafe" always means the survey shows the spot breaks a rule, and the borderline cases stay visible in their own column and list. A run's fail where the survey is borderline or review is a disagreement but none of the three.

**Decided without its measurement.** A pass or fail where the run's own deciding distance is missing as `failed` or `unsupported`, or is marked `absent` for an `at_most` limit. The scorer accepts it and scores it like any other outcome, so a pass on a failing survey is still an unsafe pass. It is also counted in this separate column, flagged in `checks.csv` as `decided_without_measurement`, and listed by name, whatever the survey outcome, including unknown. An absent feature can support an `at_least` clearance, but absence cannot establish a maximum route length.

An unsure is justified when the survey is borderline or review, or the run had no value (unsupported or failed). Otherwise it is avoidable.

**Timing.** Capture and processing seconds, as the run reported them. Every row that shares a recording shares its capture time. A photo row cannot claim a shorter capture from it.

## What one to three houses can and cannot show

They can show:

- Which distances each pipeline returns, and any unsafe pass at these spots.
- Paired errors on identical input, such as each row's facing-gap error at spot c2.
- Whether errors fit the plan's error bars: ±0.3 ft for taps, ±0.5 ft for the mesh, ±1.5 ft for photo detection. Those bars are hypotheses to test.

They cannot show:

- An accuracy rate for homes in general. Frames and distances from one house are not independent samples.
- Validated error bars. Tuning them on a house and scoring that same house proves nothing.
- Safety. Zero unsafe passes at nine spots is a sample result.
- Homeowner effort. One shared recording cannot measure a first-time user's effort with photos.
- Installation eligibility. Electrical checks are out of scope, and three failed spots do not make a house unsuitable.

An honest pitch sentence: "On [N] houses, AR taps measured [k] of [n] distances, median error [x] in, [u] unsafe passes."

## Known gaps

- Spot placement error (how far a pipeline's spot sits from the taped mark) is not scored.
- Latency is one processing time per run. Cold and warm starts, crashes and timeouts need separate runs or fields.
- The protocol keeps survey values in meters. This format uses feet to match `rules.yaml` and `scene.json`. Convert once, when the survey is typed up.
- `rules.yaml` does not exist yet. Threshold names follow the protocol note. `facing_gap_ft`, `pool_clearance_ft` and `review_route_ft` in the fixture are synthetic placeholders.
