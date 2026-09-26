"""Compare one pipeline run with the tape survey of the same house.

Pure functions over the loaded inputs. Every figure is exact Decimal arithmetic on the numbers as
typed, so a tie with a threshold or with a reported uncertainty resolves the same way on every
machine. Errors are reported in inches; survey values, uncertainties and thresholds stay in feet.
"""

from dataclasses import dataclass
from decimal import Decimal
from statistics import median
from typing import Literal

from scoring.inputs import (
    Check,
    Outcome,
    PipelineMeasurement,
    Results,
    SurveyMeasurement,
    Threshold,
    Truth,
)

INCHES_PER_FOOT = Decimal(12)

MeasurementStatus = Literal[
    "scored",  # both the survey and the run have a value
    "scale_reference",  # the house's declared scale distance: never scored
    "not_surveyed",  # the survey could not reach it, so nothing can be said about the run
    "missing_unsupported",  # the run has no way to produce this distance
    "missing_failed",  # the run tried and produced nothing
    "false_absent",  # the run says the feature does not exist; the survey measured it
    "phantom",  # the run gives a distance to a feature the survey found absent
    "absent_agreed",  # both say the feature does not exist
]

# pass and fail are outside the survey's uncertainty; borderline is within it; unknown means the
# survey could not measure the deciding distance.
TruthOutcome = Literal["pass", "fail", "borderline", "unknown"]
Abstention = Literal["justified", "avoidable"]

AT_THRESHOLD = "at_threshold"


@dataclass(frozen=True)
class MeasurementScore:
    survey: SurveyMeasurement
    reported: PipelineMeasurement | None
    status: MeasurementStatus
    # Run minus survey, so a positive error means the run overestimated. None unless scored.
    error_ft: Decimal | None
    # |run - survey| <= the run's reported uncertainty. None when not scored or none reported.
    truth_within_reported: bool | None

    @property
    def signed_error_in(self) -> Decimal | None:
        return None if self.error_ft is None else self.error_ft * INCHES_PER_FOOT

    @property
    def abs_error_in(self) -> Decimal | None:
        return None if self.error_ft is None else abs(self.error_ft) * INCHES_PER_FOOT


def score_measurement(
    survey: SurveyMeasurement, reported: PipelineMeasurement | None, *, scale_reference: bool
) -> MeasurementScore:
    status = _measurement_status(survey, reported, scale_reference=scale_reference)
    if status != "scored":
        return MeasurementScore(survey, reported, status, None, None)
    assert reported is not None and reported.value_ft is not None
    assert survey.value_ft is not None
    error_ft = reported.value_ft - survey.value_ft
    within = None if reported.plus_minus_ft is None else abs(error_ft) <= reported.plus_minus_ft
    return MeasurementScore(survey, reported, status, error_ft, within)


def _measurement_status(
    survey: SurveyMeasurement, reported: PipelineMeasurement | None, *, scale_reference: bool
) -> MeasurementStatus:
    if scale_reference:
        return "scale_reference"
    if survey.status == "not_measured":
        return "not_surveyed"
    if reported is None:
        raise ValueError(f"run has no entry for survey measurement {survey.id!r}")
    if reported.missing == "unsupported":
        return "missing_unsupported"
    if reported.missing == "failed":
        return "missing_failed"
    run_says_absent = reported.missing == "absent"
    if survey.status == "absent":
        return "absent_agreed" if run_says_absent else "phantom"
    return "false_absent" if run_says_absent else "scored"


def truth_outcome(survey: SurveyMeasurement, threshold: Threshold) -> TruthOutcome:
    """The outcome the tape survey supports under the rules.

    With s the survey value's margin on the passing side of the threshold and u the survey
    uncertainty, the check passes when s >= u, fails when s < -u, and is borderline otherwise.
    Equality with the threshold passes, matching "within 20 ft" and "at least 3 ft": when u = 0 a
    value exactly on the threshold passes. A missing feature clears every at_least rule.
    """
    if survey.status == "not_measured":
        return "unknown"
    if survey.status == "absent":
        if threshold.pass_when != "at_least":
            raise ValueError(f"absent measurement {survey.id!r} cannot decide an at_most rule")
        return "pass"
    margin, uncertainty = passing_margin_ft(survey, threshold), survey.plus_minus_ft
    assert margin is not None and uncertainty is not None
    if margin >= uncertainty:
        return "pass"
    if margin < -uncertainty:
        return "fail"
    return "borderline"


def passing_margin_ft(survey: SurveyMeasurement, threshold: Threshold) -> Decimal | None:
    """Survey value minus threshold, signed so that positive is the passing side."""
    if survey.value_ft is None:
        return None
    if threshold.pass_when == "at_least":
        return survey.value_ft - threshold.value_ft
    return threshold.value_ft - survey.value_ft


def expected_outcome(truth: TruthOutcome) -> Outcome | None:
    """What a correct run reports: a borderline survey value should make it say unsure."""
    return {"pass": "pass", "fail": "fail", "borderline": "unsure", "unknown": None}[truth]


def error_to_margin(
    abs_error_ft: Decimal, margin_ft: Decimal, survey_plus_minus_ft: Decimal
) -> Decimal | str:
    """error / max(|margin|, survey uncertainty). Above 1, the run's error could flip the check.

    Returns AT_THRESHOLD when the survey value sits exactly on the threshold with no uncertainty,
    where the ratio has no denominator.
    """
    scale = max(abs(margin_ft), survey_plus_minus_ft)
    if scale == 0:
        return AT_THRESHOLD
    return abs_error_ft / scale


def could_flip(ratio: Decimal | str, abs_error_ft: Decimal) -> bool:
    if ratio == AT_THRESHOLD:
        return abs_error_ft > 0
    assert isinstance(ratio, Decimal)
    return ratio > 1


@dataclass(frozen=True)
class CheckScore:
    check: Check
    threshold: Threshold
    survey: SurveyMeasurement
    measurement: MeasurementScore
    truth: TruthOutcome
    margin_ft: Decimal | None
    error_to_margin: Decimal | str | None
    could_flip: bool | None
    reported: Outcome | None
    expected: Outcome | None
    # The following are None when the run makes no decisions or the survey outcome is unknown.
    agrees: bool | None
    unsafe_pass: bool | None
    false_rejection: bool | None
    abstention: Abstention | None


def score_check(
    check: Check,
    threshold: Threshold,
    measurement: MeasurementScore,
    reported: Outcome | None,
) -> CheckScore:
    survey = measurement.survey
    truth = truth_outcome(survey, threshold)
    margin = passing_margin_ft(survey, threshold)

    ratio: Decimal | str | None = None
    flip: bool | None = None
    if measurement.error_ft is not None:
        assert margin is not None and survey.plus_minus_ft is not None
        abs_error_ft = abs(measurement.error_ft)
        ratio = error_to_margin(abs_error_ft, margin, survey.plus_minus_ft)
        flip = could_flip(ratio, abs_error_ft)

    expected = expected_outcome(truth)
    agrees = unsafe = rejection = None
    abstention: Abstention | None = None
    if reported is not None and truth != "unknown":
        agrees = reported == expected
        unsafe = reported == "pass" and truth in ("fail", "borderline")
        rejection = reported == "fail" and truth == "pass"
        if reported == "unsure":
            evidence_missing = measurement.status in ("missing_unsupported", "missing_failed")
            justified = truth == "borderline" or evidence_missing
            abstention = "justified" if justified else "avoidable"

    return CheckScore(
        check=check,
        threshold=threshold,
        survey=survey,
        measurement=measurement,
        truth=truth,
        margin_ft=margin,
        error_to_margin=ratio,
        could_flip=flip,
        reported=reported,
        expected=expected,
        agrees=agrees,
        unsafe_pass=unsafe,
        false_rejection=rejection,
        abstention=abstention,
    )


@dataclass(frozen=True)
class RunScore:
    truth: Truth
    results: Results
    measurements: tuple[MeasurementScore, ...]
    checks: tuple[CheckScore, ...]

    def count(self, status: MeasurementStatus) -> int:
        return sum(score.status == status for score in self.measurements)

    @property
    def denominator(self) -> int:
        """Every survey measurement except the scale reference, whether or not the run answered."""
        return sum(score.status != "scale_reference" for score in self.measurements)

    @property
    def scored_errors_in(self) -> list[Decimal]:
        return [s.abs_error_in for s in self.measurements if s.abs_error_in is not None]

    @property
    def median_abs_error_in(self) -> Decimal | None:
        errors = self.scored_errors_in
        return median(errors) if errors else None

    @property
    def max_abs_error_in(self) -> Decimal | None:
        errors = self.scored_errors_in
        return max(errors) if errors else None

    @property
    def within_reported(self) -> tuple[int, int]:
        """(scored distances inside the run's ±, scored distances where the run gave a ±)."""
        flags = [s.truth_within_reported for s in self.measurements]
        return sum(flag is True for flag in flags), sum(flag is not None for flag in flags)

    @property
    def makes_decisions(self) -> bool:
        return self.results.outcomes is not None

    @property
    def judged(self) -> int:
        """Checks the survey can settle: its outcome is not unknown."""
        return sum(score.truth != "unknown" for score in self.checks)

    @property
    def agreements(self) -> int:
        return sum(score.agrees is True for score in self.checks)

    @property
    def unsafe_passes(self) -> int:
        return sum(score.unsafe_pass is True for score in self.checks)

    @property
    def false_rejections(self) -> int:
        return sum(score.false_rejection is True for score in self.checks)

    @property
    def could_flip(self) -> int:
        return sum(score.could_flip is True for score in self.checks)

    def abstentions(self, kind: Abstention) -> int:
        return sum(score.abstention == kind for score in self.checks)


def score_run(truth: Truth, results: Results, thresholds: dict[str, Threshold]) -> RunScore:
    measurements = tuple(
        score_measurement(
            survey,
            results.measurements.get(survey.id),
            scale_reference=survey.id == truth.scale_reference,
        )
        for survey in truth.measurements.values()
    )
    by_id = {score.survey.id: score for score in measurements}
    checks = tuple(
        score_check(
            check,
            thresholds[check.threshold],
            by_id[check.measurement],
            None if results.outcomes is None else results.outcomes[(check.candidate, check.check)],
        )
        for check in truth.checks
    )
    return RunScore(truth, results, measurements, checks)
