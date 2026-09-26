"""Regression tests for the real-phone run 2 (issues #44, #45, #42); each failed before its fix."""

import copy

import pytest
from helpers import W, at_start, observed_band, parsed, rect, shared_fixture
from hypothesis import given, settings
from hypothesis import strategies as st
from test_s4_round import PUBLIC, answer

from solver import FAIL, PASS, SOLVE_BUDGET_S, UNSURE, Solver, estimate_fails

# --- #44: a spot whose best estimate overlaps the meter's working space ----------------------


def meter_known_loosely(meter_error: float = 0.792, wall_error: float = 0.713) -> dict:
    """Run 2's numbers: the meter and wall errors are large, so a spot against the meter is only
    UNSURE for the working space. Headroom is unseen everywhere. Right of the meter the ground is
    seen but its surface wasn't recorded, so the spots that clear the working space are UNSURE
    for as many checks as the one against the meter, and further from it. (The lawn also runs
    past the left limit end, behind the wall's line, where that ground counts too.)"""
    raw = shared_fixture()
    raw["meter"]["plus_minus_ft"] = meter_error
    raw["walls"][0]["baseline"] = [[-3, 0], [20, 0]]
    raw["walls"][0]["plus_minus_ft"] = wall_error
    raw["overheads"] = []
    raw["facing"][0]["span_ft"] = [-3, 20]
    raw["ground"] = [{"type": "lawn", "polygon": rect(-40, 1.0, -30, 30), "plus_minus_ft": 0}]
    raw["coverage"]["ends"] = {"left": {"kind": "limit"}, "right": {"kind": "limit"}}
    observed_band(raw, "overhead", [])
    return raw


def test_a_spot_over_the_meters_working_space_does_not_win() -> None:
    # Before: the spot from -2.58 to 0 won on its 0 ft route although its best estimate
    # overlapped the working space by 1.25 ft.
    result = answer(meter_known_loosely())
    meter = next(c for c in result["checks"] if c["id"] == "meter_working_space")
    assert meter["measured_ft"] >= 0, (result["spot"]["span_ft"], meter)


@settings(max_examples=40, deadline=None)
@given(
    meter_error=st.floats(min_value=0.1, max_value=2.0),
    wall_error=st.floats(min_value=0.0, max_value=1.5),
)
def test_an_estimate_past_a_rule_never_outranks_one_that_clears(
    meter_error: float, wall_error: float
) -> None:
    raw = meter_known_loosely(meter_error, wall_error)
    scene = parsed(raw, PUBLIC)
    candidates = Solver(scene, PUBLIC).candidates(SOLVE_BUDGET_S)
    unsures = [c for c in candidates if c.outcome == UNSURE]
    result = answer(raw)
    if result["decision"] != "manual_review" or not any(not estimate_fails(c) for c in unsures):
        return
    chosen = min(unsures, key=lambda c: abs(c.s0 - result["spot"]["span_ft"][0]))
    assert not estimate_fails(chosen)


def test_an_overlap_past_the_walls_error_fails_the_working_space() -> None:
    # Before: -1.25 against the meter's 0.792 plus the wall's 0.713 was UNSURE. The meter's
    # error no longer excuses an overlap, so the numbers give FAIL: -1.25 + 0.713 < 0.
    c = at_start(meter_known_loosely(), -W, "meter_working_space", PUBLIC)
    assert c.measured == pytest.approx(-1.25)
    assert c.outcome == FAIL
    assert c.plus_minus == pytest.approx(0.713)


@pytest.mark.parametrize(
    ("s1", "outcome"),
    [
        (-1.25 - 0.792 - 0.713 - 0.1, PASS),  # clear by more than both errors
        (-1.25 - 0.1, UNSURE),  # clear, but by less than both
        (-1.25 + 0.713 - 0.1, UNSURE),  # an overlap within the wall's error
    ],
)
def test_the_meters_error_still_holds_back_a_working_space_pass(s1: float, outcome: str) -> None:
    c = at_start(meter_known_loosely(), s1 - W, "meter_working_space", PUBLIC)
    assert c.outcome == outcome
    assert c.plus_minus == pytest.approx(0.792 + 0.713)


# --- #45: the summary counts only unseen checks -----------------------------------------------


def test_the_summary_counts_unseen_checks_and_names_the_rest() -> None:
    # Before: "10 checks depend on areas the scan did not see", one of them too close to call.
    raw = shared_fixture()
    observed_band(raw, "overhead", [])  # headroom unseen
    raw["walls"][0]["plus_minus_ft"] = 0.2
    raw["objects"] = [  # an AC unit 3.1 ft from the pad's spot: within the 0.2 ft error
        {
            "type": "ac",
            "wall_id": "w1",
            "span_ft": [6 + 31 / 12 + 3.1, 6 + 31 / 12 + 5.1],
            "source": "tape",
            "plus_minus_ft": 0,
            "footprint": rect(6 + 31 / 12 + 3.1, 6 + 31 / 12 + 5.1, 0, 2),
        }
    ]
    summary = answer(raw)["summary"]
    assert "1 check depends on areas the scan did not see, and 1 needs a person to judge" in (
        summary
    ), summary


# --- #42: an object past an unexplored end ----------------------------------------------------


def window_past_the_end(end: str, footprint: bool = False) -> dict:
    """A window with no footprint 5 ft past the wall's right end at 12 ft."""
    raw = shared_fixture()
    raw["walls"][0]["baseline"] = [[-40, 0], [12, 0]]
    raw["overheads"][0]["span_ft"] = raw["facing"][0]["span_ft"] = [-40, 12]
    raw["coverage"]["ends"]["right"] = {"kind": end}
    window = {
        "type": "window",
        "wall_id": "w1",
        "span_ft": [17, 20],
        "bottom_ft": 3,
        "top_ft": 7,
        "source": "tap",
        "plus_minus_ft": 0.1,
    }
    if footprint:
        window["footprint"] = [[17, 0], [20, 0]]
    raw["objects"] = [window]
    return raw


def test_a_mark_past_an_unexplored_end_is_set_aside_and_named() -> None:
    # Before: the window was placed on the wall's straight extension, which may not exist.
    scene = parsed(window_past_the_end("unexplored"), PUBLIC)
    assert scene.objects == []
    result = answer(window_past_the_end("unexplored"))
    assert [o["object"] for o in result["objects_not_used"]] == ["objects[0] window"]
    assert "right end" in result["objects_not_used"][0]["message"]


def test_past_a_limit_end_the_wall_line_still_holds_it() -> None:
    assert len(parsed(window_past_the_end("limit"), PUBLIC).objects) == 1
    assert answer(window_past_the_end("limit"))["objects_not_used"] == []


def test_a_mark_with_its_own_footprint_is_measured_where_it_is() -> None:
    assert len(parsed(window_past_the_end("unexplored", footprint=True), PUBLIC).objects) == 1


def test_a_mark_across_the_end_keeps_the_part_on_the_wall() -> None:
    raw = window_past_the_end("unexplored")
    raw["objects"][0]["span_ft"] = [10, 14]
    (window,) = parsed(copy.deepcopy(raw), PUBLIC).objects
    xs = [x for x, _ in window.geom.coords]
    assert min(xs) == 10 and max(xs) <= 12 + 1e-6
