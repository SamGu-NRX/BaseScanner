"""Each metric against answers worked out by hand. Values are feet unless a name says inches."""

from decimal import Decimal
from pathlib import Path

import pytest
from helpers import reported, survey, threshold

from scoring.inputs import Candidate, Check, PipelineMeasurement, Results, Truth
from scoring.metrics import (
    AT_THRESHOLD,
    could_flip,
    error_to_margin,
    score_check,
    score_measurement,
    score_run,
    truth_outcome,
)

D = Decimal
CHECK = Check("c1", "gas", "m", "gas_clearance_ft")


class TestTruthOutcome:
    # Strict, per docs/02-implementation-plan.md Lane C: pass when the margin s > u, fail when
    # s < -u, borderline otherwise. A value exactly on the threshold, or exactly u from it, is
    # borderline, including when u = 0.

    @pytest.mark.parametrize(
        ("value", "plus_minus", "expected"),
        [
            # at_least 3, u = 0
            ("3.001", "0", "pass"),
            ("3", "0", "borderline"),  # on the threshold
            ("2.999", "0", "fail"),
            # at_least 3, u = 0.3: lines at 3.3 (pass) and 2.7 (fail)
            ("3.301", "0.3", "pass"),
            ("3.3", "0.3", "borderline"),  # margin equal to u
            ("3.299", "0.3", "borderline"),
            ("3", "0.3", "borderline"),
            ("2.701", "0.3", "borderline"),
            ("2.7", "0.3", "borderline"),  # miss equal to u
            ("2.699", "0.3", "fail"),
        ],
    )
    def test_at_least_boundaries(self, value, plus_minus, expected):
        assert truth_outcome(survey(value, plus_minus), threshold("3")) == expected

    @pytest.mark.parametrize(
        ("value", "plus_minus", "expected"),
        [
            # at_most 20, u = 0
            ("19.999", "0", "pass"),
            ("20", "0", "borderline"),  # on the threshold
            ("20.001", "0", "fail"),
            # at_most 20, u = 0.05: lines at 19.95 (pass) and 20.05 (fail)
            ("19.949", "0.05", "pass"),
            ("19.95", "0.05", "borderline"),  # margin equal to u
            ("19.951", "0.05", "borderline"),
            ("20.049", "0.05", "borderline"),
            ("20.05", "0.05", "borderline"),  # miss equal to u
            ("20.051", "0.05", "fail"),
        ],
    )
    def test_at_most_boundaries(self, value, plus_minus, expected):
        assert truth_outcome(survey(value, plus_minus), threshold("20", "at_most")) == expected

    def test_equality_is_exact_decimal(self):
        # 3.1 - 3.0 is 0.10000000000000009 in floats, which would clear u = 0.1 and pass.
        assert 3.1 - 3.0 > 0.1
        assert truth_outcome(survey("3.1", "0.1"), threshold("3")) == "borderline"

    def test_absent_feature_clears_an_at_least_rule(self):
        assert truth_outcome(survey(None, None, status="absent"), threshold("3")) == "pass"

    def test_absent_feature_cannot_decide_an_at_most_rule(self):
        with pytest.raises(ValueError, match="at_most"):
            truth_outcome(survey(None, None, status="absent"), threshold("20", "at_most"))

    def test_unmeasured_distance_is_unknown(self):
        assert truth_outcome(survey(None, None, status="not_measured"), threshold()) == "unknown"


class TestErrorToMargin:
    def test_ratio_uses_the_margin_when_it_is_larger(self):
        # error 0.4, margin |3.6 - 3| = 0.6, u 0.02: 0.4 / 0.6
        assert error_to_margin(D("0.4"), (D("0.6"),), D("0.02")) == D("0.4") / D("0.6")

    def test_ratio_uses_the_uncertainty_when_it_is_larger(self):
        # error 0.33, margin 0.02, u 0.03: 0.33 / 0.03 = 11
        assert error_to_margin(D("0.33"), (D("0.02"),), D("0.03")) == D("11")

    def test_negative_margin_uses_its_size(self):
        assert error_to_margin(D("0.4"), (D("-0.5"),), D("0.02")) == D("0.8")

    def test_zero_margin_and_zero_uncertainty_is_at_threshold(self):
        assert error_to_margin(D("0.1"), (D("0"),), D("0")) == AT_THRESHOLD
        assert error_to_margin(D("0"), (D("0"),), D("0")) == AT_THRESHOLD

    def test_ratio_of_exactly_one_can_flip(self):
        # The run could land exactly on the line, which the strict rule does not pass.
        assert could_flip(D("0.9999"), D("0.5")) is False
        assert could_flip(D("1"), D("0.5")) is True

    def test_at_threshold_flips_on_any_error(self):
        assert could_flip(AT_THRESHOLD, D("0.001")) is True
        assert could_flip(AT_THRESHOLD, D("0")) is False


class TestScoreMeasurement:
    def test_signed_and_absolute_error_in_inches(self):
        over = score_measurement(survey("4.5"), reported("4.7", "0.3"), scale_reference=False)
        assert over.status == "scored"
        assert over.error_ft == D("0.2")
        assert over.signed_error_in == D("2.4")
        assert over.abs_error_in == D("2.4")
        under = score_measurement(survey("5"), reported("4.6", "0.3"), scale_reference=False)
        assert under.signed_error_in == D("-4.8")
        assert under.abs_error_in == D("4.8")

    def test_truth_within_reported_uncertainty_is_inclusive(self):
        edge = score_measurement(survey("12"), reported("11.5", "0.5"), scale_reference=False)
        assert edge.truth_within_reported is True
        out = score_measurement(survey("12"), reported("11.499", "0.5"), scale_reference=False)
        assert out.truth_within_reported is False

    def test_no_reported_uncertainty_leaves_within_unset(self):
        score = score_measurement(survey("32.5"), reported("32.6", None), scale_reference=False)
        assert score.signed_error_in == D("1.2")
        assert score.truth_within_reported is None

    def test_scale_reference_is_never_scored(self):
        score = score_measurement(survey("5"), reported("6", "0.3"), scale_reference=True)
        assert score.status == "scale_reference"
        assert score.error_ft is None and score.abs_error_in is None
        assert score.truth_within_reported is None
        unreported = score_measurement(survey("5"), None, scale_reference=True)
        assert unreported.status == "scale_reference"

    @pytest.mark.parametrize(
        ("survey_status", "value", "missing", "expected"),
        [
            ("measured", None, "unsupported", "missing_unsupported"),
            ("measured", None, "failed", "missing_failed"),
            ("measured", None, "absent", "false_absent"),
            ("absent", None, "absent", "absent_agreed"),
            ("absent", "12", None, "phantom"),
            ("absent", None, "failed", "missing_failed"),
            ("not_measured", "4", None, "not_surveyed"),
            ("not_measured", None, "failed", "not_surveyed"),
        ],
    )
    def test_statuses_without_an_error(self, survey_status, value, missing, expected):
        truth_value = "4" if survey_status == "measured" else None
        truth_pm = "0.01" if survey_status == "measured" else None
        score = score_measurement(
            survey(truth_value, truth_pm, status=survey_status),
            reported(value, "0.3" if value else None, missing=missing),
            scale_reference=False,
        )
        assert score.status == expected
        assert score.error_ft is None
        assert score.truth_within_reported is None


def check_score(
    truth_value, truth_pm, run_value, run_pm, outcome, *, missing=None, status="measured"
):
    measurement = score_measurement(
        survey(truth_value, truth_pm, status=status),
        reported(run_value, run_pm, missing=missing),
        scale_reference=False,
    )
    return score_check(CHECK, threshold("3"), measurement, outcome)


class TestScoreCheck:
    def test_pass_on_a_borderline_survey_is_a_missed_review(self):
        # Survey 3.02 +- 0.03 against at_least 3: margin 0.02 < u, borderline.
        score = check_score("3.02", "0.03", "3.35", "0.3", "pass")
        assert score.truth == "borderline"
        assert score.expected == "unsure"
        assert score.margin_ft == D("0.02")
        assert score.error_to_margin == D("11")
        assert score.could_flip is True
        assert score.agrees is False
        assert score.unsafe_pass is False
        assert score.missed_review is True
        assert score.false_rejection is False
        assert score.abstention is None

    def test_pass_on_a_failing_survey_is_unsafe(self):
        score = check_score("2.5", "0.02", "3.4", "0.3", "pass")
        assert score.truth == "fail"
        assert score.unsafe_pass is True
        assert score.missed_review is False

    def test_fail_on_a_passing_survey_is_a_false_rejection(self):
        score = check_score("4.5", "0.01", "2.9", "0.3", "fail")
        assert score.truth == "pass"
        assert score.false_rejection is True
        assert score.unsafe_pass is False
        assert score.agrees is False

    def test_fail_on_a_borderline_survey_is_neither_unsafe_nor_a_false_rejection(self):
        score = check_score("3.02", "0.03", "2.4", "1.5", "fail")
        assert (score.agrees, score.unsafe_pass, score.false_rejection) == (False, False, False)

    def test_unsure_on_a_borderline_survey_agrees_and_is_justified(self):
        score = check_score("3.02", "0.03", "3.1", "0.3", "unsure")
        assert score.agrees is True
        assert score.abstention == "justified"

    def test_unsure_without_a_run_value_is_justified(self):
        score = check_score("2.5", "0.02", None, None, "unsure", missing="failed")
        assert score.truth == "fail"
        assert score.agrees is False
        assert score.abstention == "justified"
        assert score.error_to_margin is None and score.could_flip is None

    def test_unsure_with_a_value_on_a_clear_survey_is_avoidable(self):
        score = check_score("5", "0.02", "3.8", "1.5", "unsure")
        assert score.abstention == "avoidable"

    def test_unsure_after_a_false_absence_is_avoidable(self):
        # The run claimed there is no gas meter, so it did not lack evidence.
        score = check_score("4.5", "0.01", None, None, "unsure", missing="absent")
        assert score.measurement.status == "false_absent"
        assert score.abstention == "avoidable"

    def test_unknown_survey_outcome_is_not_judged(self):
        score = check_score(None, None, None, None, "pass", missing="failed", status="not_measured")
        assert score.truth == "unknown"
        assert score.expected is None
        assert (score.agrees, score.unsafe_pass, score.false_rejection) == (None, None, None)
        assert score.abstention is None

    def test_run_without_decisions_is_not_judged_but_still_gets_the_ratio(self):
        score = check_score("5", "0.02", "5.1", "0.5", None)
        assert score.truth == "pass"
        assert score.reported is None
        assert (score.agrees, score.unsafe_pass, score.false_rejection) == (None, None, None)
        assert score.error_to_margin == D("0.05")  # 0.1 / 2.0
        assert score.could_flip is False

    def test_survey_on_the_threshold_with_no_uncertainty(self):
        score = check_score("3", "0", "3.1", "0.3", "pass")
        assert score.truth == "borderline"
        assert score.margin_ft == D("0")
        assert score.error_to_margin == AT_THRESHOLD
        assert score.could_flip is True
        assert (score.agrees, score.missed_review) == (False, True)

    def test_absent_feature_passes_without_a_ratio(self):
        score = check_score(None, None, None, None, "pass", missing="absent", status="absent")
        assert score.truth == "pass"
        assert score.margin_ft is None
        assert score.error_to_margin is None
        assert score.agrees is True


class TestDecidedWithoutItsMeasurement:
    # A pass or fail although the run's measurement is missing as failed or unsupported.

    @pytest.mark.parametrize("missing", ["failed", "unsupported"])
    def test_pass_on_a_failing_survey_is_flagged_and_still_unsafe(self, missing):
        score = check_score("2.5", "0.02", None, None, "pass", missing=missing)
        assert score.decided_without_measurement is True
        assert (score.truth, score.unsafe_pass, score.agrees) == ("fail", True, False)
        assert score.abstention is None

    def test_fail_on_a_passing_survey_is_flagged_and_still_a_false_rejection(self):
        score = check_score("5", "0.02", None, None, "fail", missing="unsupported")
        assert score.decided_without_measurement is True
        assert (score.false_rejection, score.over_caution) == (True, True)

    def test_correct_decision_is_flagged_but_agrees(self):
        score = check_score("2.5", "0.02", None, None, "fail", missing="failed")
        assert (score.decided_without_measurement, score.agrees) == (True, True)

    def test_flagged_even_when_the_survey_outcome_is_unknown(self):
        score = check_score(None, None, None, None, "pass", missing="failed", status="not_measured")
        assert score.truth == "unknown"
        assert score.agrees is None
        assert score.decided_without_measurement is True

    def test_unsure_without_a_measurement_is_not_flagged(self):
        score = check_score("2.5", "0.02", None, None, "unsure", missing="failed")
        assert score.decided_without_measurement is False
        assert score.abstention == "justified"

    def test_pass_on_a_claimed_absence_is_not_flagged(self):
        agreed = check_score(None, None, None, None, "pass", missing="absent", status="absent")
        assert agreed.decided_without_measurement is False
        wrongly_absent = check_score("2.5", "0.02", None, None, "pass", missing="absent")
        assert wrongly_absent.decided_without_measurement is False
        assert wrongly_absent.unsafe_pass is True

    @pytest.mark.parametrize(
        "survey_status, truth_value, truth_pm",
        [
            ("absent", None, None),
            ("measured", "5", "0.02"),
            ("not_measured", None, None),
        ],
    )
    def test_at_least_fail_on_claimed_absence_lacks_a_deciding_distance(
        self, survey_status, truth_value, truth_pm
    ):
        score = check_score(
            truth_value, truth_pm, None, None, "fail", missing="absent", status=survey_status
        )
        assert score.decided_without_measurement is True
        if survey_status == "absent":
            assert score.false_rejection is True
        elif survey_status == "not_measured":
            assert score.agrees is None

    @pytest.mark.parametrize("outcome", ["pass", "fail"])
    def test_absent_route_cannot_support_an_at_most_decision(self, outcome):
        measurement = score_measurement(
            survey("12", "0.05"), reported(None, None, missing="absent"), scale_reference=False
        )
        score = score_check(ROUTE, MAX, measurement, outcome, REVIEW)
        assert score.truth == "pass"
        assert score.decided_without_measurement is True
        assert score.false_rejection is (outcome == "fail")

    def test_absent_route_is_flagged_even_when_survey_is_unknown(self):
        measurement = score_measurement(
            survey(None, None, status="not_measured"),
            reported(None, None, missing="absent"),
            scale_reference=False,
        )
        score = score_check(ROUTE, MAX, measurement, "pass", REVIEW)
        assert score.truth == "unknown"
        assert score.agrees is None
        assert score.decided_without_measurement is True

    def test_decision_with_a_measurement_is_not_flagged(self):
        assert check_score("5", "0.02", "5.1", "0.3", "pass").decided_without_measurement is False

    def test_run_without_decisions_is_not_judged(self):
        score = check_score("5", "0.02", None, None, None, missing="failed")
        assert score.decided_without_measurement is None


REVIEW = threshold("15", "at_most", "review_route_ft")
MAX = threshold("20", "at_most", "max_route_ft")
ROUTE = Check("c1", "route", "m", "max_route_ft", "review_route_ft")


def route_outcome(value: str, plus_minus: str = "0"):
    return truth_outcome(survey(value, plus_minus), MAX, REVIEW)


class TestRouteBand:
    # Strict: pass when length + u < 15, fail when length - u > 20, review otherwise, so a
    # length exactly on either line, or exactly u from it, is review.

    @pytest.mark.parametrize(
        ("length", "expected"),
        [
            ("10", "pass"),
            ("14.999", "pass"),
            ("15", "review"),  # on the review line
            ("15.001", "review"),
            ("17.5", "review"),
            ("19.999", "review"),
            ("20", "review"),  # on the max line: review, not fail
            ("20.001", "fail"),
            ("25", "fail"),
        ],
    )
    def test_bands_and_boundaries_without_uncertainty(self, length, expected):
        assert route_outcome(length) == expected

    @pytest.mark.parametrize(
        ("length", "plus_minus", "expected"),
        [
            ("14.699", "0.3", "pass"),  # 14.999 < 15
            ("14.7", "0.3", "review"),  # 14.7 + 0.3 = 15, on the review line
            ("14.701", "0.3", "review"),
            ("20.299", "0.3", "review"),  # 19.999, not past max
            ("20.3", "0.3", "review"),  # 20.3 - 0.3 = 20, on the max line
            ("20.301", "0.3", "fail"),
            ("19.9", "0.3", "review"),  # its +- reaches past max, but a fail needs all of it past
        ],
    )
    def test_uncertainty_must_clear_each_line(self, length, plus_minus, expected):
        assert route_outcome(length, plus_minus) == expected

    def test_band_does_not_change_a_single_threshold_check(self):
        assert truth_outcome(survey("20", "0.01"), MAX) == "borderline"

    def route_check(self, truth_value, run_value, outcome, *, missing=None):
        measurement = score_measurement(
            survey(truth_value, "0.05"),
            reported(run_value, None if run_value is None else "0.3", missing=missing),
            scale_reference=False,
        )
        return score_check(ROUTE, MAX, measurement, outcome, REVIEW)

    def categories(self, score):
        return (score.unsafe_pass, score.missed_review, score.over_caution)

    def test_pass_where_the_survey_fails_is_unsafe(self):
        score = self.route_check("22", "19", "pass")
        assert score.truth == "fail"
        assert self.categories(score) == (True, False, False)

    def test_pass_where_the_survey_is_review_is_a_missed_review(self):
        score = self.route_check("17", "14", "pass")
        assert score.truth == "review"
        assert score.expected == "unsure"
        assert self.categories(score) == (False, True, False)
        assert score.agrees is False

    def test_unsure_where_the_survey_passes_is_over_caution(self):
        score = self.route_check("12", "16", "unsure")
        assert self.categories(score) == (False, False, True)
        assert score.false_rejection is False
        assert score.abstention == "avoidable"

    def test_fail_where_the_survey_passes_is_over_caution_and_a_false_rejection(self):
        score = self.route_check("12", "21", "fail")
        assert self.categories(score) == (False, False, True)
        assert score.false_rejection is True

    def test_unsure_in_the_band_agrees_and_is_justified(self):
        score = self.route_check("17", "17.2", "unsure")
        assert score.agrees is True
        assert score.abstention == "justified"
        assert self.categories(score) == (False, False, False)

    def test_fail_in_the_band_is_none_of_the_three(self):
        score = self.route_check("17", "21", "fail")
        assert score.agrees is False
        assert self.categories(score) == (False, False, False)
        assert score.false_rejection is False

    def test_correct_pass_and_fail_agree(self):
        assert self.route_check("12", "12.2", "pass").agrees is True
        assert self.route_check("22", "22.2", "fail").agrees is True

    def test_margins_and_ratio_use_the_nearest_line(self):
        # Survey 19.9: 0.1 inside max, 4.9 past review. Run 19.5, error 0.4: 0.4 / 0.1 = 4.
        score = self.route_check("19.9", "19.5", "pass")
        assert (score.margin_ft, score.review_margin_ft) == (D("0.1"), D("-4.9"))
        assert score.error_to_margin == D("4")
        assert score.could_flip is True
        # Survey 12: 3 inside review, 8 inside max. Error 0.25: 0.25 / 3.
        near_review = self.route_check("12", "12.25", "pass")
        assert near_review.error_to_margin == D("0.25") / D("3")
        assert near_review.could_flip is False

    def test_survey_on_the_review_line_with_no_uncertainty(self):
        measurement = score_measurement(
            survey("15", "0"), reported("15.1", "0.3"), scale_reference=False
        )
        score = score_check(ROUTE, MAX, measurement, "pass", REVIEW)
        assert score.truth == "review"
        assert score.error_to_margin == AT_THRESHOLD
        assert score.could_flip is True
        assert score.missed_review is True


GAS = threshold("3", "at_least")
GAS_CHECK = Check("c1", "gas", "m", "gas_clearance_ft")


def single_or_banded(kind: str, truth_value: str, outcome: str):
    """Score one outcome on a single-threshold gas check or the banded route check."""
    measurement = score_measurement(
        survey(truth_value, "0.05"), reported(truth_value, "0.3"), scale_reference=False
    )
    if kind == "single":
        return score_check(GAS_CHECK, GAS, measurement, outcome)
    return score_check(ROUTE, MAX, measurement, outcome, REVIEW)


# (kind, survey value, survey outcome). Gas is at_least 3; route passes to 15 and fails past 20.
SURVEYS = {
    ("single", "pass"): "5",
    ("single", "borderline"): "3.02",
    ("single", "fail"): "2",
    ("banded", "pass"): "12",
    ("banded", "review"): "17",
    ("banded", "fail"): "22",
}


class TestCategoriesAreTheSameForEveryCheck:
    """unsafe pass: pass on a failing survey. missed review: pass on an unsure (borderline) or
    review survey. over-caution: unsure or fail on a passing survey."""

    @pytest.mark.parametrize(
        ("kind", "truth", "outcome", "unsafe", "missed", "cautious"),
        [
            ("single", "fail", "pass", True, False, False),
            ("banded", "fail", "pass", True, False, False),
            ("single", "borderline", "pass", False, True, False),
            ("banded", "review", "pass", False, True, False),
            ("single", "pass", "unsure", False, False, True),
            ("banded", "pass", "unsure", False, False, True),
            ("single", "pass", "fail", False, False, True),
            ("banded", "pass", "fail", False, False, True),
            ("single", "pass", "pass", False, False, False),
            ("banded", "pass", "pass", False, False, False),
            ("single", "borderline", "unsure", False, False, False),
            ("banded", "review", "unsure", False, False, False),
            ("single", "borderline", "fail", False, False, False),
            ("banded", "review", "fail", False, False, False),
            ("single", "fail", "unsure", False, False, False),
            ("banded", "fail", "fail", False, False, False),
        ],
    )
    def test_category(self, kind, truth, outcome, unsafe, missed, cautious):
        score = single_or_banded(kind, SURVEYS[(kind, truth)], outcome)
        assert score.truth == truth
        assert (score.unsafe_pass, score.missed_review, score.over_caution) == (
            unsafe,
            missed,
            cautious,
        )


def run_score(scale_value: str, *, outcomes=None):
    measurements = {
        "scale": survey("5", "0.005", id="scale", candidate=None),
        "a": survey("10", "0.01", id="a"),
        "b": survey("10", "0.01", id="b"),
        "c": survey("10", "0.01", id="c"),
        "d": survey("10", "0.01", id="d"),
        "e": survey("10", "0.01", id="e"),
    }
    truth = Truth(
        path=Path("truth.json"),
        house="h1",
        captures=("cap",),
        scale_reference="scale",
        candidates={"c1": Candidate("c1", "tape", "wall")},
        measurements=measurements,
        checks=(Check("c1", "gas", "a", "gas_clearance_ft"),),
    )
    runs = {
        "scale": PipelineMeasurement("scale", D(scale_value), None, None),
        "a": PipelineMeasurement("a", D("10.1"), D("0.3"), None),  # 1.2 in, inside
        "b": PipelineMeasurement("b", D("9.5"), D("0.3"), None),  # 6 in, outside
        "c": PipelineMeasurement("c", D("10.25"), None, None),  # 3 in, no +-
        "d": PipelineMeasurement("d", D("10.2"), D("0.2"), None),  # 2.4 in, inside at the edge
        "e": PipelineMeasurement("e", None, None, "unsupported"),
    }
    results = Results(
        path=Path("results.json"),
        pipeline="p",
        capture="cap",
        rules_sha256="0" * 64,
        scale_source="scale_reference",
        measurements=runs,
        outcomes=outcomes,
        capture_seconds=None,
        processing_seconds=None,
    )
    return score_run(truth, results, {"gas_clearance_ft": threshold("3")})


class TestRunScore:
    def test_error_statistics_over_scored_distances_only(self):
        run = run_score("5")
        # Scored errors in inches: 1.2, 6, 3, 2.4. Sorted 1.2, 2.4, 3, 6: median (2.4 + 3) / 2.
        assert sorted(run.scored_errors_in) == [D("1.2"), D("2.4"), D("3.00"), D("6.0")]
        assert run.median_abs_error_in == D("2.7")
        assert run.max_abs_error_in == D("6")
        assert run.within_reported == (2, 3)
        assert run.count("scored") == 4
        assert run.count("missing_unsupported") == 1
        assert run.denominator == 5

    def test_scale_reference_error_does_not_enter_the_statistics(self):
        # A 12 in scale error would be the maximum and move the median if it were counted.
        honest, off = run_score("5"), run_score("6")
        assert off.median_abs_error_in == honest.median_abs_error_in == D("2.7")
        assert off.max_abs_error_in == honest.max_abs_error_in == D("6")
        assert off.denominator == 5
        assert off.count("scale_reference") == 1

    def test_decision_counts(self):
        run = run_score("5", outcomes={("c1", "gas"): "pass"})
        assert run.makes_decisions
        assert (run.judged, run.agreements, run.unsafe_passes) == (1, 1, 0)
        assert run.decided_without_measurement == 0
        assert run_score("5").makes_decisions is False
        assert run_score("5").agreements == 0
