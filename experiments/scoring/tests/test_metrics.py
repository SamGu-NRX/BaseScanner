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
    # at_least 3 ft: pass when value - 3 >= u, fail when value - 3 < -u, else borderline.

    def test_value_on_the_threshold_with_no_uncertainty_passes(self):
        assert truth_outcome(survey("3", "0"), threshold("3")) == "pass"

    def test_value_on_an_at_most_threshold_with_no_uncertainty_passes(self):
        assert truth_outcome(survey("20", "0"), threshold("20", "at_most")) == "pass"

    def test_value_on_the_threshold_with_uncertainty_is_borderline(self):
        assert truth_outcome(survey("3", "0.01"), threshold("3")) == "borderline"

    def test_margin_equal_to_uncertainty_passes(self):
        # 3.3 - 3.0 is 0.2999999999999998 in floats, which would be borderline.
        assert truth_outcome(survey("3.3", "0.3"), threshold("3")) == "pass"

    def test_margin_just_under_uncertainty_is_borderline(self):
        assert truth_outcome(survey("3.299", "0.3"), threshold("3")) == "borderline"

    def test_miss_equal_to_uncertainty_is_borderline(self):
        # 2.7 +- 0.3 reaches 3.0, which passes, so the survey cannot call it a fail.
        assert truth_outcome(survey("2.7", "0.3"), threshold("3")) == "borderline"

    def test_miss_beyond_uncertainty_fails(self):
        assert truth_outcome(survey("2.699", "0.3"), threshold("3")) == "fail"

    def test_just_below_the_threshold_with_no_uncertainty_fails(self):
        assert truth_outcome(survey("2.999", "0"), threshold("3")) == "fail"

    def test_at_most_direction(self):
        rule = threshold("20", "at_most")
        assert truth_outcome(survey("19.9", "0.05"), rule) == "pass"
        assert truth_outcome(survey("19.96", "0.05"), rule) == "borderline"
        assert truth_outcome(survey("20.051", "0.05"), rule) == "fail"

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

    def test_ratio_of_exactly_one_cannot_flip(self):
        assert could_flip(D("1"), D("0.5")) is False
        assert could_flip(D("1.0001"), D("0.5")) is True

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
    def test_pass_on_a_borderline_survey_is_unsafe(self):
        # Survey 3.02 +- 0.03 against at_least 3: margin 0.02 < u, borderline.
        score = check_score("3.02", "0.03", "3.35", "0.3", "pass")
        assert score.truth == "borderline"
        assert score.expected == "unsure"
        assert score.margin_ft == D("0.02")
        assert score.error_to_margin == D("11")
        assert score.could_flip is True
        assert score.agrees is False
        assert score.unsafe_pass is True
        assert score.false_rejection is False
        assert score.abstention is None

    def test_pass_on_a_failing_survey_is_unsafe(self):
        score = check_score("2.5", "0.02", "3.4", "0.3", "pass")
        assert score.truth == "fail"
        assert score.unsafe_pass is True

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
        assert score.truth == "pass"
        assert score.margin_ft == D("0")
        assert score.error_to_margin == AT_THRESHOLD
        assert score.could_flip is True
        assert score.agrees is True

    def test_absent_feature_passes_without_a_ratio(self):
        score = check_score(None, None, None, None, "pass", missing="absent", status="absent")
        assert score.truth == "pass"
        assert score.margin_ft is None
        assert score.error_to_margin is None
        assert score.agrees is True


REVIEW = threshold("15", "at_most", "review_route_ft")
MAX = threshold("20", "at_most", "max_route_ft")
ROUTE = Check("c1", "route", "m", "max_route_ft", "review_route_ft")


def route_outcome(value: str, plus_minus: str = "0"):
    return truth_outcome(survey(value, plus_minus), MAX, REVIEW)


class TestRouteBand:
    # Pass when length + u <= 15, fail when length - u > 20, review otherwise.

    @pytest.mark.parametrize(
        ("length", "expected"),
        [
            ("10", "pass"),
            ("15", "pass"),  # on the review line: pass
            ("15.001", "review"),
            ("17.5", "review"),
            ("20", "review"),  # on the max line: still review, not fail
            ("20.001", "fail"),
            ("25", "fail"),
        ],
    )
    def test_bands_and_boundaries_without_uncertainty(self, length, expected):
        assert route_outcome(length) == expected

    @pytest.mark.parametrize(
        ("length", "plus_minus", "expected"),
        [
            ("14.7", "0.3", "pass"),  # 14.7 + 0.3 = 15, on the review line
            ("14.701", "0.3", "review"),  # its +- crosses the review line
            ("14.9", "0.3", "review"),
            ("20.3", "0.3", "review"),  # 20.3 - 0.3 = 20, not past max
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
        assert score.truth == "pass"
        assert score.error_to_margin == AT_THRESHOLD
        assert score.could_flip is True


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
        assert run_score("5").makes_decisions is False
        assert run_score("5").agreements == 0
