"""How high up the wall the capture saw (`out_ft` on a wall entry), against the height each check
needs from rules.yaml. Absent `out_ft` means seen up to headroom height, as before."""

import copy
import itertools

from helpers import at_start, observed_band, parsed, shared_fixture
from hypothesis import given, settings
from hypothesis import strategies as st
from test_s4_round import PUBLIC, answer

from solver import SOLVE_BUDGET_S, UNSURE, Solver, evaluate_start

RULES = PUBLIC.rules
BATTERY_TOP = RULES.battery.height_ft.value  # the wall behind the battery
ROUTE = RULES.route.height_ft.value  # where the cable runs
HEADROOM = RULES.headroom.min_ft.value  # boxes, vents, openings and gas on the wall


def wall_seen_to(height: float | None) -> dict:
    raw = shared_fixture()
    observed_band(raw, "wall", [(-40, 40)])
    if height is not None:
        raw["coverage"]["observed"][-1]["out_ft"] = height
    return raw


def unseen(raw: dict, check_id: str) -> bool:
    check = at_start(raw, 6.0, check_id, PUBLIC)
    return check.outcome == UNSURE and check.unsure_cause == "unobserved"


def without_timing(result: dict) -> dict:
    return result | {"stats": {k: v for k, v in result["stats"].items() if k != "elapsed_ms"}}


def test_absent_out_ft_is_seen_all_the_way_up() -> None:
    absent, far = answer(wall_seen_to(None)), answer(wall_seen_to(100.0))
    # Only the input hash differs: the scenes differ by that one field.
    far["stats"]["input_sha256"] = absent["stats"]["input_sha256"]
    assert without_timing(absent) == without_timing(far)


def test_each_check_needs_its_own_height() -> None:
    # Seen 2 ft up: enough for the cable at 1 ft, not for the battery's back or anything above it.
    raw = wall_seen_to(2.0)
    assert ROUTE < 2.0 < BATTERY_TOP
    assert not unseen(raw, "route_path")
    for check_id in ("wall_backing", "wall_equipment_above", "opening_clearance", "gas_clearance"):
        assert unseen(raw, check_id), check_id


def test_the_battery_height_settles_its_back_but_not_what_is_above() -> None:
    raw = wall_seen_to(BATTERY_TOP + 0.1)
    assert not unseen(raw, "wall_backing")
    assert unseen(raw, "wall_equipment_above")


def test_a_wall_request_names_the_height_that_settles_it() -> None:
    request = next(m for m in answer(wall_seen_to(2.0))["missing_evidence"] if m["band"] == "wall")
    assert request["out_ft"] > HEADROOM
    assert "up the wall" in request["message"]


def supplied(raw: dict, result: dict, shortfall: float = 0.0) -> dict:
    out = copy.deepcopy(raw)
    for item in result["missing_evidence"]:
        if item["kind"] == "band":
            depth = {"out_ft": item["out_ft"] - shortfall} if "out_ft" in item else {}
            out["coverage"]["observed"].append(
                {"band": item["band"], "span_ft": item["span_ft"], **depth}
            )
    return out


@settings(max_examples=40, deadline=None)
@given(
    heights=st.lists(st.floats(min_value=0.2, max_value=9.0), min_size=1, max_size=4),
    cuts=st.lists(st.floats(min_value=-15, max_value=25), min_size=3, max_size=3),
)
def test_supplying_the_requested_height_settles_it_and_less_does_not(
    heights: list[float], cuts: list[float]
) -> None:
    raw = shared_fixture()
    edges = [-40.0, *sorted(cuts), 40.0]
    observed_band(raw, "wall", [])
    # Each stretch between cuts seen to its own height (the heights repeat if there are fewer).
    for (a, b), height in zip(itertools.pairwise(edges), heights * 4, strict=False):
        raw["coverage"]["observed"].append({"band": "wall", "span_ft": [a, b], "out_ft": height})
    result = answer(raw)
    requests = [m for m in result["missing_evidence"] if m.get("band") == "wall"]
    if not requests or result["spot"] is None:
        return
    # The exact start the solver chose; the answer's is rounded to 6 decimals.
    s0 = min(
        (c.s0 for c in Solver(parsed(raw, PUBLIC), PUBLIC).candidates(SOLVE_BUDGET_S)),
        key=lambda start: abs(start - result["spot"]["span_ft"][0]),
    )

    def unseen_at_spot(scene: dict) -> list[str]:
        candidate = evaluate_start(parsed(scene, PUBLIC), PUBLIC, s0)
        return [c.id for c in candidate.checks if c.unsure_cause == "unobserved"]

    assert unseen_at_spot(supplied(raw, result)) == []
    assert unseen_at_spot(supplied(raw, result, shortfall=0.05)) != []
