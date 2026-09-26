"""Turn run scores into a markdown summary and three CSV tables.

CSV cells hold the figure, or stay empty when it does not apply (a missing distance has no error).
Booleans are written true or false. Decimals are rounded half up for display only; every
comparison was made on the exact values.
"""

import csv
from collections.abc import Iterable
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

from scoring.inputs import Study
from scoring.metrics import AT_THRESHOLD, CheckScore, MeasurementScore, RunScore

MEASUREMENT_COLUMNS = (
    "house",
    "capture",
    "pipeline",
    "measurement",
    "candidate",
    "from",
    "to",
    "survey_status",
    "survey_ft",
    "survey_plus_minus_ft",
    "run_ft",
    "run_plus_minus_ft",
    "run_missing",
    "status",
    "signed_error_in",
    "abs_error_in",
    "truth_within_reported",
)

CHECK_COLUMNS = (
    "house",
    "capture",
    "pipeline",
    "candidate",
    "check",
    "measurement",
    "threshold",
    "threshold_ft",
    "pass_when",
    "survey_ft",
    "survey_plus_minus_ft",
    "margin_ft",
    "truth_outcome",
    "run_ft",
    "abs_error_in",
    "error_to_margin",
    "could_flip",
    "run_outcome",
    "expected_outcome",
    "agrees",
    "unsafe_pass",
    "false_rejection",
    "abstention",
)

RUN_COLUMNS = (
    "house",
    "capture",
    "pipeline",
    "scale_source",
    "capture_s",
    "processing_s",
    "measurements",
    "scored",
    "median_abs_error_in",
    "max_abs_error_in",
    "within_reported",
    "with_reported_uncertainty",
    "missing_unsupported",
    "missing_failed",
    "false_absent",
    "phantom",
    "absent_agreed",
    "not_surveyed",
    "checks",
    "judged",
    "agrees",
    "unsafe_passes",
    "false_rejections",
    "abstentions_justified",
    "abstentions_avoidable",
    "could_flip",
)


def fixed(value: Decimal | None, places: int) -> str:
    """Round half up to `places` decimals. Never prints -0.00 or scientific notation."""
    if value is None:
        return ""
    rounded = value.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
    if rounded == 0:
        rounded = abs(rounded)
    return format(rounded, "f")


def feet(value: Decimal | None) -> str:
    return fixed(value, 3)


def inches(value: Decimal | None) -> str:
    return fixed(value, 2)


def ratio(value: Decimal | str | None) -> str:
    if isinstance(value, Decimal):
        return fixed(value, 2)
    return AT_THRESHOLD if value == AT_THRESHOLD else ""


def flag(value: bool | None) -> str:
    return "" if value is None else str(value).lower()


def seconds(value: Decimal | None) -> str:
    return fixed(value, 1)


def measurement_row(run: RunScore, score: MeasurementScore) -> dict[str, str]:
    survey, reported = score.survey, score.reported
    return {
        "house": run.truth.house,
        "capture": run.results.capture,
        "pipeline": run.results.pipeline,
        "measurement": survey.id,
        "candidate": survey.candidate or "",
        "from": survey.start,
        "to": survey.end,
        "survey_status": survey.status,
        "survey_ft": feet(survey.value_ft),
        "survey_plus_minus_ft": feet(survey.plus_minus_ft),
        "run_ft": feet(reported.value_ft) if reported else "",
        "run_plus_minus_ft": feet(reported.plus_minus_ft) if reported else "",
        "run_missing": (reported.missing or "") if reported else "",
        "status": score.status,
        "signed_error_in": inches(score.signed_error_in),
        "abs_error_in": inches(score.abs_error_in),
        "truth_within_reported": flag(score.truth_within_reported),
    }


def check_row(run: RunScore, score: CheckScore) -> dict[str, str]:
    reported = score.measurement.reported
    return {
        "house": run.truth.house,
        "capture": run.results.capture,
        "pipeline": run.results.pipeline,
        "candidate": score.check.candidate,
        "check": score.check.check,
        "measurement": score.check.measurement,
        "threshold": score.threshold.name,
        "threshold_ft": feet(score.threshold.value_ft),
        "pass_when": score.threshold.pass_when,
        "survey_ft": feet(score.survey.value_ft),
        "survey_plus_minus_ft": feet(score.survey.plus_minus_ft),
        "margin_ft": feet(score.margin_ft),
        "truth_outcome": score.truth,
        "run_ft": feet(reported.value_ft) if reported else "",
        "abs_error_in": inches(score.measurement.abs_error_in),
        "error_to_margin": ratio(score.error_to_margin),
        "could_flip": flag(score.could_flip),
        "run_outcome": score.reported or "",
        "expected_outcome": score.expected or "",
        "agrees": flag(score.agrees),
        "unsafe_pass": flag(score.unsafe_pass),
        "false_rejection": flag(score.false_rejection),
        "abstention": score.abstention or "",
    }


def run_row(run: RunScore) -> dict[str, str]:
    within, with_uncertainty = run.within_reported
    decides = run.makes_decisions

    def decision(count: int) -> str:
        return str(count) if decides else ""

    return {
        "house": run.truth.house,
        "capture": run.results.capture,
        "pipeline": run.results.pipeline,
        "scale_source": run.results.scale_source,
        "capture_s": seconds(run.results.capture_seconds),
        "processing_s": seconds(run.results.processing_seconds),
        "measurements": str(run.denominator),
        "scored": str(run.count("scored")),
        "median_abs_error_in": inches(run.median_abs_error_in),
        "max_abs_error_in": inches(run.max_abs_error_in),
        "within_reported": str(within),
        "with_reported_uncertainty": str(with_uncertainty),
        "missing_unsupported": str(run.count("missing_unsupported")),
        "missing_failed": str(run.count("missing_failed")),
        "false_absent": str(run.count("false_absent")),
        "phantom": str(run.count("phantom")),
        "absent_agreed": str(run.count("absent_agreed")),
        "not_surveyed": str(run.count("not_surveyed")),
        "checks": str(len(run.checks)),
        "judged": str(run.judged),
        "agrees": decision(run.agreements),
        "unsafe_passes": decision(run.unsafe_passes),
        "false_rejections": decision(run.false_rejections),
        "abstentions_justified": decision(run.abstentions("justified")),
        "abstentions_avoidable": decision(run.abstentions("avoidable")),
        "could_flip": str(run.could_flip),
    }


def _write(path: Path, columns: tuple[str, ...], rows: Iterable[dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_csvs(runs: list[RunScore], out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = [out_dir / "measurements.csv", out_dir / "checks.csv", out_dir / "runs.csv"]
    measurement_rows = (measurement_row(r, s) for r in runs for s in r.measurements)
    _write(paths[0], MEASUREMENT_COLUMNS, measurement_rows)
    _write(paths[1], CHECK_COLUMNS, (check_row(r, s) for r in runs for s in r.checks))
    _write(paths[2], RUN_COLUMNS, (run_row(r) for r in runs))
    return paths


def _table(header: list[str], rows: list[list[str]]) -> list[str]:
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(cell or "n/a" for cell in row) + " |" for row in rows]
    return lines


def _count(number: int, noun: str) -> str:
    return f"{number} {noun}" if number == 1 else f"{number} {noun}s"


def markdown(study: Study, runs: list[RunScore]) -> str:
    rules = study.rules
    houses = study.houses
    spots = sum(len(house.truth.candidates) for house in houses)
    lines = [
        "# Capture pipeline scores",
        "",
        f"Rules: `{rules.path.name}` ({rules.name}), sha256 `{rules.sha256}`.",
        f"{_count(len(houses), 'house')}, {_count(spots, 'candidate spot')}, "
        f"{_count(len(runs), 'pipeline run')}.",
        "",
        "Each house's declared scale reference is left out of every error figure: a run that was "
        "given it can match it exactly, so its error says nothing about accuracy.",
    ]
    for house in houses:
        truth = house.truth
        house_runs = [run for run in runs if run.truth is truth]
        reference = truth.measurements[truth.scale_reference]
        lines += [
            "",
            f"## House {truth.house}",
            "",
            f"Captures: {', '.join(truth.captures)}. Candidates: {', '.join(truth.candidates)}. "
            f"Scale reference `{reference.id}` ({feet(reference.value_ft)} ft), excluded.",
        ]
        if not house_runs:
            lines += ["", "No pipeline runs for this house."]
            continue
        lines += _distances(house_runs) + _checks(house_runs) + _timing(house_runs)
        lines += _unsafe(house_runs)
    lines += [
        "",
        "These are paired results at the listed spots, a case series. They are not an accuracy "
        "rate for other homes, validated error bars, or evidence of safety.",
    ]
    return "\n".join(lines) + "\n"


def _distances(runs: list[RunScore]) -> list[str]:
    denominator = runs[0].denominator
    rows = []
    for run in runs:
        within, with_uncertainty = run.within_reported
        rows.append(
            [
                f"`{run.results.pipeline}`",
                run.results.scale_source,
                f"{run.count('scored')}/{denominator}",
                inches(run.median_abs_error_in),
                inches(run.max_abs_error_in),
                f"{within}/{with_uncertainty}" if with_uncertainty else "",
                str(run.count("missing_unsupported")),
                str(run.count("missing_failed")),
                str(run.count("false_absent")),
                str(run.count("phantom")),
                str(run.count("absent_agreed")),
                str(run.count("not_surveyed")),
            ]
        )
    header = [
        "Pipeline",
        "Scale source",
        "Scored",
        "Median error (in)",
        "Max error (in)",
        "Survey inside run's ±",
        "Unsupported",
        "Failed",
        "Wrongly absent",
        "Phantom",
        "Absent, agreed",
        "Not surveyed",
    ]
    return [
        "",
        "### Distances",
        "",
        f"{denominator} distances besides the scale reference; each row's counts add up to it. "
        "Errors are absolute, in inches, over the distances both the survey and the run "
        "measured. Wrongly absent: the run says the feature is not there, but the survey "
        "measured it. Phantom: the run measured a feature the survey found absent.",
        "",
        *_table(header, rows),
    ]


def _checks(runs: list[RunScore]) -> list[str]:
    total = len(runs[0].checks)
    judged = runs[0].judged
    rows = []
    for run in runs:
        if run.makes_decisions:
            decided = [
                f"{run.agreements}/{judged}",
                str(run.unsafe_passes),
                str(run.false_rejections),
                str(run.abstentions("justified")),
                str(run.abstentions("avoidable")),
            ]
        else:
            decided = ["no decisions", "", "", "", ""]
        rows.append([f"`{run.results.pipeline}`", *decided, str(run.could_flip)])
    header = [
        "Pipeline",
        "Agree",
        "Unsafe passes",
        "False rejections",
        "Unsure, justified",
        "Unsure, avoidable",
        "Error could flip",
    ]
    return [
        "",
        "### Checks",
        "",
        f"{total} checks, {judged} with a survey outcome. The survey passes a check when its "
        "value clears the threshold by at least its ± and fails it when it misses by more; "
        "anything between is borderline, where the right answer is unsure. An unsafe pass is a "
        "run's pass where the survey fails or is borderline. An unsure is justified when the "
        "survey is borderline or the run has no value. The error could flip a check when it is "
        "larger than both the survey's distance to the threshold and its ±.",
        "",
        *_table(header, rows),
    ]


def _timing(runs: list[RunScore]) -> list[str]:
    rows = [
        [
            f"`{run.results.pipeline}`",
            seconds(run.results.capture_seconds) or "not recorded",
            seconds(run.results.processing_seconds) or "not recorded",
        ]
        for run in runs
    ]
    return ["", "### Timing", "", *_table(["Pipeline", "Capture (s)", "Processing (s)"], rows)]


def _unsafe(runs: list[RunScore]) -> list[str]:
    lines = []
    for run in runs:
        for score in run.checks:
            if not score.unsafe_pass:
                continue
            survey, threshold = score.survey, score.threshold
            reported = score.measurement.reported
            has_value = reported is not None and reported.value_ft is not None
            run_value = f"{feet(reported.value_ft)} ft" if has_value else "no value"
            lines.append(
                f"- `{run.results.pipeline}` passed `{score.check.check}` at "
                f"`{score.check.candidate}`; the survey is {score.truth} at "
                f"{feet(survey.value_ft)} ± {feet(survey.plus_minus_ft)} ft against "
                f"`{threshold.name}` {threshold.pass_when} {feet(threshold.value_ft)} ft "
                f"(run measured {run_value})."
            )
    if not lines:
        return ["", "No unsafe passes."]
    return ["", "### Unsafe passes", "", *lines]
