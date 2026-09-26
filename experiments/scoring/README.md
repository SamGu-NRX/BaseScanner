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

All three are JSON and start with `"format": 1` and `"unit": "ft"`. Every length is in feet. Numbers are read as exact decimals, so a survey value exactly one tolerance from a threshold lands on the same side every time (in floats, 3.3 minus 3.0 is 0.2999999999999998). Unknown fields, duplicate keys, `NaN`, negative lengths and numbers written as strings are all rejected. Fields marked "or null" must still be present.

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
| `pass_when` | `at_least` for a clearance (the distance must be at least the value), `at_most` for a limit such as route length. A value exactly on the threshold passes either way. |
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
  "checks": [{"candidate": "c1", "check": "gas", "measurement": "c1-gas", "threshold": "gas_clearance_ft"}]
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
| `outcomes` | One entry per survey check: `pass`, `unsure` or `fail`. Set the whole field to null for a run that measures distances but makes no decisions. |
| `timing.capture_s`, `processing_s` | Seconds, or null if not recorded. Runs on the same capture must report the same `capture_s` or null. |

## What the scorer reports

The markdown summary has one section per house. Each section has a distances table, a checks table, a timing table, and a list of every unsafe pass. Nothing is averaged across houses, and a missing output is never averaged away. The CSVs hold one row per run and measurement, per run and check, and per run.

**Distances.** Signed error is run minus survey, in inches, so positive means the run overestimated. The summary gives the median and maximum absolute error over the distances both sides measured. "Survey inside run's ±" counts the scored distances where the absolute error is at most the run's reported uncertainty, out of those where the run reported one. Every survey measurement except the scale reference is in the denominator and lands in exactly one bucket: scored, unsupported, failed, wrongly absent (the run says it is not there, the survey measured it), phantom (the run measured a feature the survey found absent), absent in both, or not surveyed.

**The scale reference is excluded from every error statistic.** A run that was given it can match it exactly, so its error says nothing about accuracy. Its rows appear in `measurements.csv` with status `scale_reference` and no error. The summary says this at the top.

**Survey outcome of a check.** Let s be the survey value's margin on the passing side of the threshold, and u the survey uncertainty. The check passes when s ≥ u, fails when s < −u, and is borderline in between. A value exactly on the threshold with u = 0 passes. The same value with any uncertainty is borderline. An absent feature passes. An unmeasured one is unknown and is left out of the decision counts.

**Error relative to the threshold.** The ratio is |error| / max(|s|, u). Above 1, the run's error could flip the check. When s and u are both zero the ratio has no denominator, so the CSV reports `at_threshold`, and any nonzero error counts as a possible flip.

**Decisions.** A correct run passes a passing check, fails a failing one, and says unsure on a borderline one. An unsafe pass is a run's pass where the survey fails or is borderline. That count matters most. A false rejection is a run's fail where the survey passes. An unsure is justified when the survey is borderline or the run had no value (unsupported or failed). Otherwise it is avoidable.

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

- Each check has one threshold. Route length has a review band between `review_route_ft` and `max_route_ft`, and nobody has decided what a pipeline should report inside it. The fixture scores the route against `max_route_ft` only.
- Spot placement error (how far a pipeline's spot sits from the taped mark) is not scored.
- Latency is one processing time per run. Cold and warm starts, crashes and timeouts need separate runs or fields.
- The protocol keeps survey values in meters. This format uses feet to match `rules.yaml` and `scene.json`. Convert once, when the survey is typed up.
- `rules.yaml` does not exist yet. Threshold names follow the protocol note. `facing_gap_ft` and `pool_clearance_ft` in the fixture are synthetic placeholders.
