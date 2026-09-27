"""A battery already on the wall (issue #27): `battery` objects keep a new battery
clearances.battery_ft away, measured in plan like the AC clearance, under the strict rule."""

import json
from pathlib import Path

import pytest
from helpers import W, at_start, rect, shared_fixture
from jsonschema import Draft202012Validator
from test_s4_round import PUBLIC, answer

from rules import load_rules
from solver import FAIL, PASS, UNSURE

S0 = 6.0  # the new battery at [S0, S0 + W] on the shared wall's lawn pad
S1 = S0 + W
DEPTH = 22 / 12


def existing_battery(gap: float, plus_minus: float = 0.1, top: float | None = 3.29) -> dict:
    """An existing battery standing against the wall `gap` ft right of the new one."""
    raw = shared_fixture()
    x0 = S1 + gap
    item = {
        "type": "battery",
        "wall_id": "w1",
        "span_ft": [x0, x0 + W],
        "bottom_ft": 0,
        "source": "tap",
        "plus_minus_ft": plus_minus,
        "footprint": rect(x0, x0 + W, 0, DEPTH),
    }
    if top is not None:
        item["top_ft"] = top
    raw["objects"] = [item]
    return raw


@pytest.mark.parametrize(
    ("gap", "outcome"),
    [
        (1.0, FAIL),  # misses the 3 ft rule by more than the 0.1 ft error
        (4.0, PASS),  # clears it by more than the error
        (3.05, UNSURE),  # within the error either way
    ],
)
def test_an_existing_battery_is_held_to_the_rule(gap: float, outcome: str) -> None:
    check = at_start(existing_battery(gap), S0, "battery_clearance", PUBLIC)
    assert check.outcome == outcome
    assert check.threshold == PUBLIC.rules.clearances.battery_ft.value == 3.0
    if outcome == UNSURE:
        assert check.unsure_cause == "margin"


def test_exactly_at_the_rule_with_no_error_is_unsure() -> None:
    # The strict rule: equality neither clears nor misses by more than the (zero) error.
    check = at_start(existing_battery(3.0, plus_minus=0.0), S0, "battery_clearance", PUBLIC)
    assert check.outcome == UNSURE


def test_the_answer_cites_the_rule() -> None:
    result = answer(existing_battery(1.0))
    check = next(c for c in result["checks"] if c["id"] == "battery_clearance")
    assert check["rule"]["key"] == "clearances.battery_ft"
    assert "other batteries" in check["rule"]["source"]


def test_a_scene_without_one_has_no_battery_check() -> None:
    # It would repeat the AC check's coverage (same band, same 3 ft), so answers stay as before.
    assert "battery_clearance" not in {c["id"] for c in answer(shared_fixture())["checks"]}


def test_the_cable_detours_over_an_existing_battery() -> None:
    # Between the meter (s = 0) and the new battery: the cable goes over it at route height.
    raw = existing_battery(0.0)
    raw["objects"][0]["span_ft"] = [2.0, 2.0 + W]
    raw["objects"][0]["footprint"] = rect(2.0, 2.0 + W, 0, DEPTH)
    route = at_start(raw, S0, "route_path", PUBLIC)
    assert route.outcome == PASS
    detours = at_start(raw, S0, "route_length", PUBLIC)
    assert detours.measured == pytest.approx(S0 + 2 * (3.29 - 1.0), abs=1e-6)


def test_the_public_value_applies_when_private_rules_do_not_set_it(tmp_path: Path) -> None:
    private = tmp_path / "rules.yaml"
    private.write_text("clearances:\n  gas_ft: {value: 4.0, source: 'test'}\n")
    assert load_rules(private).rules.clearances.battery_ft.value == 3.0


def test_the_schema_accepts_the_type() -> None:
    schema = Path(__file__).resolve().parents[1] / "schemas" / "scene.schema.json"
    Draft202012Validator(json.loads(schema.read_text())).validate(existing_battery(4.0))
