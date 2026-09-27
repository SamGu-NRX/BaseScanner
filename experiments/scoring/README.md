# Scoring

**Question.** Against an independent tape survey of a house, how far off is each capture pipeline's distance, how close is that error to the threshold that decides the check, and which outputs are missing or unsafe?

**Pass criteria.** None set. The [scoring protocol](https://github.com/SamGu-NRX/house-scanning-master/blob/9737e3f0eefe90f2a12a190bf8750e7fed64413f/docs/research/t3-scoring-protocol.md) reports each house as a case series, and it counts unsafe passes, a pipeline PASS where the survey fails, as the number that matters most.

**Run.** Needs uv. The scorer does not run pipelines. Each pipeline writes a results file.

```sh
cd experiments/scoring && uv sync --locked
uv run score --rules fixtures/rules.json --truth fixtures/truth/synthetic-01.json \
  --results fixtures/results/ar-taps.json fixtures/results/photo-depth.json fixtures/results/mesh-scaled.json \
  --out results/synthetic-01 > results/synthetic-01/summary.md
uv run pytest -q
```

[FORMATS.md](FORMATS.md) specifies the input files and the Measure Lab importer. [METRICS.md](METRICS.md) explains every number. Real surveys and results go in git-ignored `data/`, the default `--out`.

**Result.** No real house scored yet. In [results/synthetic-01](results/synthetic-01/summary.md), three invented runs have median errors of 3.48, 12.60 and 1.20 in, and `ar-taps` makes 1 unsafe pass. Those numbers test the scorer, not any pipeline. All 274 tests and ruff pass.

**What changed.** Nothing in the product or the plan yet. The field eval in PR #12 calls `score import-measure-lab` to score a Measure Lab session.
