"""AR-placed positions without their own plus_minus_ft get an error that grows with the distance
walked from the meter (rules.yaml errors.drift_per_ft, from S1's real-data drift evals)."""

import pytest
from helpers import W, at_start, golden_rules, parsed, shared_fixture

RULES = golden_rules(
    errors={
        "tap_ft": {"value": 0.3, "source": "t"},
        "vlm_ft": {"value": 1.5, "source": "t"},
        "tape_ft": {"value": 0.05, "source": "t"},
        "wall_ft": {"value": 0.3, "source": "t"},
        "drift_per_ft": {"value": 0.16, "source": "t"},
    }
)


def obj(source, span, **extra):
    return {"type": "window", "wall_id": "w1", "span_ft": span, "source": source, **extra}


def test_object_default_error_grows_with_distance_walked() -> None:
    raw = shared_fixture()
    raw["objects"] = [
        obj("tap", [2, 3]),
        obj("tap", [-10, -9]),
        obj("vlm", [2, 3]),
        obj("tape", [9, 10]),
        obj("tap", [9, 10], plus_minus_ft=0.1),
    ]
    errors = [o.plus_minus for o in parsed(raw, RULES).objects]
    assert errors == pytest.approx([0.3 + 0.16 * 3, 0.3 + 0.16 * 10, 1.5 + 0.16 * 3, 0.05, 0.1])


def test_wall_default_error_is_taken_at_the_batterys_far_edge() -> None:
    raw = shared_fixture()
    del raw["walls"][0]["plus_minus_ft"]
    for s0 in (6.0, 12.0, -12.0):
        reach = at_start(raw, s0, "route_length", RULES)
        far = max(abs(s0), abs(s0 + W))
        # The meter is exact in the fixture, so the route's error is the wall's at the far edge.
        assert reach.plus_minus == pytest.approx(0.3 + 0.16 * far)


def test_explicit_wall_error_does_not_drift() -> None:
    # The fixture's wall has plus_minus_ft 0.
    reach = at_start(shared_fixture(), 12.0, "route_length", RULES)
    assert reach.plus_minus == pytest.approx(0.0)
