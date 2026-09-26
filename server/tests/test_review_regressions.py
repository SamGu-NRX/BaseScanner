"""Regressions from the solver review. Synthetic scenes built on the shared fixture in helpers.py.

Thresholds are the golden test settings (GOLDEN_RULES), not Base policy: facing 5 ft from the
wall, headroom 6.5, clearances 3, confident reach 15, maximum 20, every default error 0.
"""

import math
import time

import pytest
from helpers import (
    check,
    everything_observed,
    golden_rules,
    pads_ground,
    parsed,
    rect,
    run,
    shared_fixture,
)

from scene import SceneError
from solver import evaluate_start

W = 31 / 12  # battery width (31 in)
D = 11 / 6  # battery depth (22 in)


def at_start(raw, s0, check_id, rules=None):
    candidate = evaluate_start(parsed(raw, rules), rules or golden_rules(), s0)
    return next(c for c in candidate.checks if c.id == check_id)


def observed_band(raw, band, spans, out=30):
    """Replace one coverage band with the given observed spans."""
    extra = {"out_ft": out} if band == "ground" else {}
    raw["coverage"]["observed"] = [o for o in raw["coverage"]["observed"] if o["band"] != band] + [
        {"band": band, "span_ft": list(s), **extra} for s in spans
    ]


# --- 1. unexplored end ----------------------------------------------------------------------------


def test_unexplored_end_next_to_spot_is_not_a_pass() -> None:
    # Before: the area past an unexplored end counted as seen, so a spot 0.02 ft from it passed.
    raw = shared_fixture()
    raw["walls"][0]["baseline"] = [[-40, 0], [10, 0]]
    raw["ground"] = pads_ground([(7.4, 30)], hi=30)
    raw["coverage"] = everything_observed(-40, 30)
    raw["coverage"]["ends"]["right"] = {"kind": "unexplored"}
    result = run(raw)
    assert result["decision"] != "pass"
    assert any(
        c["outcome"] == "unsure" and c.get("unsure_cause") == "unobserved" for c in result["checks"]
    )


def test_limit_end_with_wall_beyond_spot_still_passes() -> None:
    # Control for the test above: the same spot on a wall that continues and ends at a real limit.
    raw = shared_fixture()
    raw["ground"] = pads_ground([(7.4, 10)])
    assert run(raw)["decision"] == "pass"


# --- 2. doors with a footprint ------------------------------------------------------------------


def test_garage_door_with_footprint_still_blocks_route() -> None:
    # Before: a door given a footprint 0.35 ft off the wall was treated as standing off it.
    raw = shared_fixture()
    raw["ground"] = pads_ground([(10, 13)])
    raw["objects"].append(
        {
            "type": "garage_door",
            "wall_id": "w1",
            "span_ft": [3, 7],
            "bottom_ft": 0,
            "top_ft": 7,
            "source": "tap",
            "plus_minus_ft": 0.3,
            "footprint": [[3, 0.35], [7, 0.35]],
        }
    )
    assert run(raw)["decision"] == "reject"
    assert at_start(raw, 10.0, "route_path").outcome == "fail"


# --- 3. measurement span edges carry their error ------------------------------------------------


def test_headroom_span_edge_error_counts() -> None:
    # Before: a 5 ft overhead ending at s = 9 (± 0.5) was ignored for a battery starting at 9.
    raw = shared_fixture()
    raw["ground"] = pads_ground([(9, 12)])
    raw["overheads"] = [
        {"wall_id": "w1", "span_ft": [-40, 9], "clearance_ft": 5, "plus_minus_ft": 0.5},
        {"wall_id": "w1", "span_ft": [9, 40], "clearance_ft": 9, "plus_minus_ft": 0.5},
    ]
    assert run(raw)["decision"] != "pass"
    assert at_start(raw, 9.0, "headroom").outcome in {"unsure", "fail"}
    assert at_start(raw, 9.6, "headroom").outcome == "pass"


def test_facing_span_edge_error_counts() -> None:
    # Before: a 1 ft facing gap ending at s = 9 (± 0.5) was ignored for a battery starting at 9.
    raw = shared_fixture()
    raw["ground"] = pads_ground([(9, 12)])
    raw["facing"] = [
        {"wall_id": "w1", "span_ft": [-40, 9], "depth_ft": 1, "plus_minus_ft": 0.5},
        {"wall_id": "w1", "span_ft": [9, 40], "depth_ft": 9, "plus_minus_ft": 0.5},
    ]
    assert at_start(raw, 9.0, "facing_gap").outcome != "pass"
    assert at_start(raw, 9.6, "facing_gap").outcome == "pass"


# --- 4. meter past its wall's end ----------------------------------------------------------------


def test_meter_past_wall_end_is_refused() -> None:
    # Before: the meter was clamped to the wall end, silently shortening every route by 2.5 ft.
    raw = shared_fixture()
    raw["meter"]["pos"] = [42.5, 5, 0]
    with pytest.raises(SceneError, match="past"):
        parsed(raw)


def test_meter_past_wall_end_within_error_is_accepted() -> None:
    raw = shared_fixture()
    raw["meter"]["pos"] = [40.2, 5, 0]
    raw["meter"]["plus_minus_ft"] = 0.3
    parsed(raw)


# --- 5. coverage radius -------------------------------------------------------------------------


def test_coverage_radius_includes_wall_error() -> None:
    # Before: coverage was checked to exactly 3 ft, though the wall itself is only known to ± 0.3.
    raw = shared_fixture()
    raw["walls"][0]["plus_minus_ft"] = 0.3
    edge = 6 + W + 3.05
    observed_band(raw, "wall", [(-40, edge)])
    observed_band(raw, "ground", [(-40, edge)])
    for check_id in ("gas_clearance", "ac_clearance", "opening_clearance"):
        c = at_start(raw, 6.0, check_id)
        assert (c.outcome, c.unsure_cause) == ("unsure", "unobserved"), check_id


# --- 6. detour error ----------------------------------------------------------------------------


def test_detour_error_flows_into_route_error() -> None:
    # Before: a detour around a ± 1.5 ft photo detection added length but no error to the route.
    rules = golden_rules(errors={"vlm_ft": {"value": 1.5, "source": "t"}})
    raw = shared_fixture()
    raw["ground"] = pads_ground([(13, 16)])
    raw["objects"].append(
        {
            "type": "elec_box",
            "wall_id": "w1",
            "span_ft": [2, 3],
            "bottom_ft": 0.5,
            "top_ft": 2,
            "source": "vlm",
        }
    )
    result = run(raw, rules)
    assert result["route"]["plus_minus_ft"] >= 2 * 1.5
    assert result["decision"] == "manual_review"


# --- 7. gaps between walls ----------------------------------------------------------------------


def two_wall_scene(w2_start, w2_end, pad):
    raw = shared_fixture()
    raw["walls"] = [
        {"id": "w1", "baseline": [[-40, 0], [3, 0]], "plus_minus_ft": 0.5},
        {"id": "w2", "baseline": [[w2_start, 0], [w2_end, 0]], "plus_minus_ft": 0.5},
    ]
    raw["ground"] = pads_ground([pad], hi=w2_end)
    raw["facing"] = [
        {"wall_id": "w1", "span_ft": [-40, 3], "depth_ft": 9, "plus_minus_ft": 0},
        {"wall_id": "w2", "span_ft": [w2_start, w2_end], "depth_ft": 9, "plus_minus_ft": 0},
    ]
    raw["overheads"] = [
        {"wall_id": "w1", "span_ft": [-40, 3], "clearance_ft": 9, "plus_minus_ft": 0},
        {"wall_id": "w2", "span_ft": [w2_start, w2_end], "clearance_ft": 9, "plus_minus_ft": 0},
    ]
    raw["coverage"] = everything_observed(-40, w2_end)
    return raw


def test_gap_within_wall_error_is_manual_review() -> None:
    # Before: a 0.7 ft gap between walls each ± 0.5 rejected, though the walls may meet.
    raw = two_wall_scene(3.7, 40.7, (9.5, 13.5))
    result = run(raw)
    assert result["decision"] == "manual_review"
    assert check(result, "route_path")["outcome"] == "unsure"


def test_gap_beyond_wall_error_rejects() -> None:
    raw = two_wall_scene(5, 40, (11, 15))
    assert run(raw)["decision"] == "reject"
    assert at_start(raw, 11.0, "route_path").outcome == "fail"


# --- 8. collinear baseline points ---------------------------------------------------------------


@pytest.mark.parametrize(
    "baseline",
    [
        [[-40, 0], [7.5, 0], [40, 0]],
        [[x, 0] for x in range(-40, 41, 2)],
    ],
    ids=["one-mid-point", "every-2-ft"],
)
def test_collinear_baseline_points_are_not_corners(baseline) -> None:
    # Before: a point in the middle of a straight wall split it, failing backing across the point.
    raw = shared_fixture()
    raw["walls"][0]["baseline"] = baseline
    result = run(raw)
    assert result["decision"] == "pass"
    assert result["spot"]["span_ft"] == pytest.approx([6, 6 + W], abs=1e-6)


# --- 9. starts from object edges ----------------------------------------------------------------


def test_start_window_between_slanted_pipes_is_found() -> None:
    # Before: only grid starts were tried, so a 0.025 ft pass window between two pipes was missed.
    rules = golden_rules(
        route={
            "confident_reach_ft": {"value": 30, "source": "t"},
            "max_ft": {"value": 40, "source": "t"},
        }
    )
    lo, hi = 14.005, 14.03
    c_right = hi + W + 3 * math.sqrt(2)
    c_left = lo - 3 * math.sqrt(2)
    raw = shared_fixture()
    raw["ground"] = pads_ground([(8, 17)])
    for c, pipe in (
        (c_right, [[c_right - 10, -10], [c_right + 30, 30]]),
        (c_left, [[c_left + 10, -10], [c_left - 30, 30]]),
    ):
        raw["objects"].append(
            {
                "type": "gas_meter",
                "wall_id": "w1",
                "span_ft": [c, c],
                "bottom_ft": 3,
                "top_ft": 4,
                "source": "tap",
                "plus_minus_ft": 0,
                "footprint": pipe,
            }
        )
    assert evaluate_start(parsed(raw, rules), rules, (lo + hi) / 2).outcome == "pass"
    result = run(raw, rules)
    assert result["decision"] == "pass"
    assert lo < result["spot"]["span_ft"][0] < hi


# --- 10. sweep runs at corners ------------------------------------------------------------------


def test_sweep_runs_split_at_corners() -> None:
    # Before: pass runs on both segments of one wall merged into a run spanning the corner.
    raw = shared_fixture()
    raw["walls"][0]["baseline"] = [[-40, 0], [8, 0], [8, -32]]
    raw["ground"] = [
        {"type": "lawn", "polygon": rect(-40, 8, 0, 30), "plus_minus_ft": 0},
        {"type": "lawn", "polygon": rect(8, 40, -40, 30), "plus_minus_ft": 0},
    ]
    result = run(raw)
    passing = [r for r in result["sweep"] if r["outcome"] == "pass"]
    assert passing
    assert all("segment" in r for r in passing)
    assert not [r for r in passing if r["start_ft"][0] < 8 - W and r["start_ft"][1] > 8 - W + 1e-6]
    assert at_start(raw, 7.0, "wall_backing").outcome == "fail"


# --- 11. non-finite and absurd numbers ----------------------------------------------------------


def _set_meter_nan(raw):
    raw["meter"]["pos"][0] = float("nan")


def _set_baseline_inf(raw):
    raw["walls"][0]["baseline"][1] = [float("inf"), 0]


def _set_coverage_nan(raw):
    raw["coverage"]["observed"][0]["span_ft"] = [-40, float("nan")]


def _set_baseline_huge(raw):
    raw["walls"][0]["baseline"][1] = [2e5, 0]


@pytest.mark.parametrize(
    "mutate",
    [_set_meter_nan, _set_baseline_inf, _set_coverage_nan, _set_baseline_huge],
    ids=["nan-meter", "inf-baseline", "nan-coverage", "huge-baseline"],
)
def test_non_finite_or_huge_numbers_are_refused(mutate) -> None:
    # Before: NaN and infinity passed the schema and crashed or poisoned the geometry.
    raw = shared_fixture()
    mutate(raw)
    with pytest.raises(SceneError):
        parsed(raw)


# --- 12. reach bound ----------------------------------------------------------------------------


def test_long_wall_is_bounded_by_reach() -> None:
    # Before: every start along a 2000 ft wall was fully evaluated, far past the cable's reach.
    raw = shared_fixture()
    raw["walls"][0]["baseline"] = [[-1000, 0], [1000, 0]]
    raw["ground"] = [{"type": "lawn", "polygon": rect(-1000, 1000, 0, 30), "plus_minus_ft": 0}]
    raw["overheads"][0]["span_ft"] = [-1000, 1000]
    raw["facing"][0]["span_ft"] = [-1000, 1000]
    raw["coverage"] = everything_observed(-1000, 1000)
    started = time.perf_counter()
    result = run(raw)
    assert time.perf_counter() - started < 1.5
    assert result["decision"] == "pass"
    far = [
        r for r in result["sweep"] if r["outcome"] == "fail" and r["failing"] == ["route_length"]
    ]
    assert any(r["start_ft"][0] >= 20 for r in far)
    assert any(r["start_ft"][1] <= -20 for r in far)


# --- 13. route length rule citation -------------------------------------------------------------


def test_route_length_cites_confident_reach_on_pass() -> None:
    # Before: a pass inside the confident reach cited the maximum as its rule.
    result = run(shared_fixture())
    assert result["decision"] == "pass"
    assert check(result, "route_length")["rule"]["key"] == "route.confident_reach_ft"


def test_route_length_cites_maximum_on_reject() -> None:
    raw = shared_fixture()
    raw["ground"] = pads_ground([(21, 24)])
    assert run(raw)["decision"] == "reject"
    # The result's nearest considered spot is a deck spot by the meter (it also fails only one
    # check, with a shorter route), so check the length-rejected start on the pad directly.
    reach = at_start(raw, 21.0, "route_length")
    assert (reach.outcome, reach.rule_key) == ("fail", "route.max_ft")


# --- 14. gas clearance needs the wall ------------------------------------------------------------


def test_gas_clearance_needs_the_wall_observed() -> None:
    # Before: gas clearance checked only the ground band, missing an unseen wall-mounted meter.
    rules = golden_rules(clearances={"gas_ft": {"value": 5, "source": "t"}})
    raw = shared_fixture()
    observed_band(raw, "wall", [(-40, 5), (12, 40)])
    result = run(raw, rules)
    assert result["decision"] == "manual_review"
    gas = check(result, "gas_clearance")
    assert (gas["outcome"], gas.get("unsure_cause")) == ("unsure", "unobserved")
