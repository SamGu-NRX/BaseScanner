# Scoring capture pipelines against a tape survey

Given an independent tape survey of a house and each capture pipeline's measurements of the same named distances and candidate spots: how large are the errors, how close are they to the thresholds that decide each check, and which outputs are missing or unsafe?

`score` answers that for any number of houses and pipeline runs. It does not run pipelines; each one writes a results file. The fieldwork protocol (what to survey, gates, freezing the rules) is the research note `docs/research/t3-scoring-protocol.md`.

## Commands

```sh
cd experiments/scoring
uv sync --locked
uv run score --rules fixtures/rules.json \
  --truth fixtures/truth/synthetic-01.json \
  --results fixtures/results/ar-taps.json fixtures/results/photo-depth.json fixtures/results/mesh-scaled.json
```

`score` prints a markdown summary and writes `measurements.csv`, `checks.csv` and `runs.csv` to `--out` (default `data/`, which git ignores). `--truth` and `--results` take several files. Any input problem stops the run with exit code 2 and a message naming the file, the field and the fix, and no CSV is written.

CI runs `uv run ruff check .`, `uv run ruff format --check .` and `uv run pytest -q`.

Everything in `fixtures/` is synthetic. Keep real surveys and results beside the capture in `captures/` or `data/`, never in git.

## Input formats

All three files are JSON starting with `"format": 1` and `"unit": "ft"`. Numbers are read as exact decimals, so ties with a threshold resolve the same way every time: in floats 3.1 − 3.0 is 0.10000000000000009, which would pass a 3.1 ± 0.1 ft clearance against a 3 ft rule that is exactly borderline. Unknown fields, duplicate keys, `NaN`, negative lengths and numbers written as strings are rejected. Fields that may be null must still be present.

### Rules file

Named thresholds using `rules.yaml` parameter names, with public or clearly synthetic values only. Base's unpublished values never go in a tracked file.

```json
{
  "format": 1, "unit": "ft", "name": "Synthetic scoring fixture",
  "thresholds": {
    "gas_clearance_ft": {"value_ft": 3, "pass_when": "at_least", "source": "Public: Base help page"},
    "max_route_ft": {"value_ft": 20, "pass_when": "at_most", "source": "Public: Base help page"}
  }
}
```

A threshold name must end in `_ft`. `pass_when` is `at_least` for a clearance or `at_most` for a limit such as route length. Each results file carries the sha256 of the exact rules file it ran under (`shasum -a 256 rules.json`), so a run made under different rules cannot be scored by mistake.

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
| `captures` | Recording ids this survey applies to, ideally each recording's sha256. Each id belongs to one house. |
| `scale_reference` | The one measurement some pipelines may use to set scale. It must be measured, cannot decide a check, and is never scored. |
| `candidates[]` | Spot `id`, its physical `marker`, and its `location` as tape offsets from permanent corners. |
| `measurements[]` | `candidate` (null for house-level distances such as wall length), `from` and `to` in words, `status` (`measured`, `absent` or `not_measured`; only `measured` has `value_ft` and `plus_minus_ft`), `method`, `measured_by`. |
| `checks[]` | The spot, check name, deciding measurement and `threshold`. Every spot needs the same check names with the same thresholds, so the denominator cannot shrink. An absent feature may only decide an `at_least` check. |
| `checks[].review_threshold` | Optional. Makes a band: values that clear `review_threshold` pass, values past `threshold` fail, values between go to review. Both thresholds must point the same way, with the review line on the passing side. |

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
| `pipeline` | Row name. Each variant is its own pipeline id. |
| `capture` | Must appear in exactly one survey's `captures`. |
| `scale_source` | `native_metric`, `scale_reference` or `ar_poses`. |
| `measurements[]` | One entry per survey measurement (the scale reference is optional). `value_ft` with `plus_minus_ft` (a number, or null if the run reports none), or `value_ft` null with `missing`: `unsupported`, `failed` or `absent`. |
| `outcomes` | One `pass`, `unsure` or `fail` per survey check, exactly as the pipeline decided; null for a run that makes no decisions. |
| `timing` | `capture_s` and `processing_s` in seconds, or null. Runs on the same capture must report the same `capture_s`. |

## Import a Measure Lab session

`score import-measure-lab` turns a session zip shared from Measure Lab (session format 2, documented in `experiments/measure-lab/README.md` "Session format") into a results file, using a map file the team writes after the walk.

```sh
uv run score import-measure-lab fixtures/measure-lab/synthetic-session-01.zip \
  --map fixtures/measure-lab/map.json --rules fixtures/rules.json \
  --truth fixtures/truth/synthetic-01.json --out data/measure-lab.json
```

An excerpt of a map; `fixtures/measure-lab/map.json` is complete. Every survey measurement id needs a key, except the scale reference.

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
| `{"session_measurement": id, "key": k}` | `values[k]` in feet. `k` must be the measurement's `compared` quantity, the one `accepted` vouches for. `accepted: false` becomes null, missing `failed`. |
| `{"refusal": id}` | Null, missing `failed`. |
| `"absent"` / `"unsupported"` | Null, missing `absent` / `unsupported`. |

Every value needs a stated uncertainty, its entry's `plus_minus_ft` or its key's in `plus_minus_ft_by_key`; there is no default. The ±0.3 ft in the example is docs/02's estimate for AR taps, not a measured error bar. `session` must match the zip's session id.

The importer converts meters exactly (1 ft = 0.3048 m) and rounds half up to a millionth of a foot. The capture id is the zip's sha256, which must already be in the survey's `captures`. `scale_source` is `ar_poses`. `capture_s` runs from the session's start to its last measurement; `processing_s` is null, because the rig shows each value as it is tapped. A map or session problem stops the import with a specific message, and the output is loaded through the scorer before it is written.

`--decide` writes a row named `<pipeline>+rule` whose outcomes apply the survey's strict rule (below) to the run's own values and uncertainties. With no value it says unsure, except that an absent feature passes an `at_least` check. This emulates the lane C rule until a real solver exists.

The fixture zip is built reproducibly from `fixtures/measure-lab/synthetic-session-01/session.json`. After editing it, run `uv run python tests/helpers.py rebuild-session-zip` and put the printed sha256 in the survey's `captures`.

## What the numbers mean

The summary has one section per house: distances, checks, timing, and every unsafe pass, missed review and decision made without its measurement, by name. Nothing is averaged across houses, and missing outputs stay in the denominator.

**Distances.** Error is run minus survey, in inches. The summary gives the median and maximum absolute error over distances both sides measured, and how often the survey value lies within the run's reported ±. Every survey measurement except the scale reference lands in one bucket: scored, unsupported, failed, wrongly absent (the run says it is not there; the survey measured it), phantom (the run measured a feature the survey found absent), absent in both, or not surveyed.

**The scale reference is excluded from every error statistic.** A run given it can match it exactly, so its error says nothing about accuracy.

**Survey outcome.** With s the survey value's margin on the passing side and u its uncertainty, a check passes when s > u, fails when s < −u, and is borderline otherwise. Both comparisons are strict, following `docs/02-implementation-plan.md` Lane C ("PASS if the margin is larger than the error"), so a value exactly on a line or exactly u from it never passes or fails. A band works the same way with two lines. For the route:

| Survey | Outcome |
|---|---|
| L + u < `review_route_ft` | pass |
| L − u > `max_route_ft` | fail |
| anything else | review |

An absent feature passes. An unmeasured one is unknown and left out of the decision counts.

**Error relative to the threshold.** |error| / max(m, u), where m is the survey value's distance to the nearest line. At 1 or above the error could flip the check, since a run exactly on a line neither passes nor fails. With m and u both zero the CSV reports `at_threshold`, and any nonzero error could flip.

**Decisions.** A correct run passes a passing check, fails a failing one, and says unsure on a borderline or review one. Wrong answers are counted in three categories that mean the same for every check:

- **Unsafe pass:** a pass where the survey fails. This count matters most.
- **Missed review:** a pass where the survey is borderline or review. The protocol note counts a borderline pass as unsafe; here it stays visible in its own column, so "unsafe" always means the survey shows the spot breaks a rule.
- **Over-caution:** an unsure or fail where the survey passes. False rejections, the fails among them, are also listed.

**Decided without its measurement:** a pass or fail whose deciding value is missing as `failed` or `unsupported`, or marked `absent` for an `at_most` limit. It is scored as usual and also counted, flagged and listed on its own.

An unsure is justified when the survey is borderline or review, or the run had no value; otherwise it is avoidable.

**Timing.** As reported. Rows sharing a recording share its capture time.

## What one to three houses can and cannot show

They can show which distances each pipeline returns, any unsafe pass at these spots, paired errors on identical input, and whether errors fit the plan's hypothesized error bars (±0.3 ft taps, ±0.5 ft mesh, ±1.5 ft photo detection).

They cannot show an accuracy rate for homes in general (distances from one house are not independent samples), validated error bars (tuning and scoring on the same house proves nothing), safety (zero unsafe passes at nine spots is a sample result), homeowner effort, or installation eligibility (electrical checks are out of scope).

An honest pitch sentence: "On [N] houses, AR taps measured [k] of [n] distances, median error [x] in, [u] unsafe passes."

## Not scored

- Spot placement error: how far a pipeline's spot sits from the taped mark.
- Latency beyond one processing time per run: cold and warm starts, crashes, timeouts.
- `rules.yaml` does not exist yet. Threshold names follow the protocol note, and `facing_gap_ft`, `pool_clearance_ft` and `review_route_ft` in the fixture are synthetic placeholders. The format uses feet to match `rules.yaml` and `scene.json`; the protocol records surveys in meters, so convert once when typing a survey up.
