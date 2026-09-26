"""The capture contract (README, "What settles each check"): supplying exactly what a request
names settles it, and the depth a walked path or a tilt-up view proves is credited."""

import copy
import json
from pathlib import Path

import jsonschema
from helpers import D, at_start, observed_band, parsed, shared_fixture
from test_s4_round import PUBLIC, answer

from solver import PASS, UNSURE, evaluate_start

RESULT_SCHEMA = json.loads(
    (Path(__file__).resolve().parents[1] / "schemas" / "result.schema.json").read_text()
)
FACING_NEED = D + 3.0  # battery depth plus facing.min_ft
HEADROOM_NEED = 6.5  # headroom.min_ft


def supplied(raw: dict, result: dict) -> dict:
    """The scene after the app supplies exactly the coverage each band request names."""
    out = copy.deepcopy(raw)
    for item in result["missing_evidence"]:
        if item["kind"] == "band":
            depth = {"out_ft": item["out_ft"]} if "out_ft" in item else {}
            out["coverage"]["observed"].append(
                {"band": item["band"], "span_ft": item["span_ft"], **depth}
            )
    return out


def seen_clear(raw: dict, band: str, out_ft: float) -> None:
    observed_band(raw, band, [])
    raw["coverage"]["observed"].append({"band": band, "span_ft": [-40, 40], "out_ft": out_ft})


def walked(out_ft: float) -> dict:
    """No facing measurements; the facing band is known clear only as far as the homeowner
    walked from the wall."""
    raw = shared_fixture()
    raw["facing"] = []
    seen_clear(raw, "facing", out_ft)
    return raw


def test_a_walked_path_far_enough_out_settles_the_facing_gap() -> None:
    facing = at_start(walked(FACING_NEED + 0.5), 6.0, "facing_gap", PUBLIC)
    assert facing.outcome == PASS


def test_a_walked_path_too_close_is_unsure_and_asks_how_far() -> None:
    raw = walked(FACING_NEED - 1)
    facing = at_start(raw, 6.0, "facing_gap", PUBLIC)
    assert (facing.outcome, facing.unsure_cause) == (UNSURE, "unobserved")
    request = next(m for m in answer(raw)["missing_evidence"] if m.get("band") == "facing")
    assert request["out_ft"] > FACING_NEED


def test_supplying_the_facing_request_settles_it() -> None:
    raw = walked(FACING_NEED - 1)
    after = answer(supplied(raw, answer(raw)))
    assert next(c for c in after["checks"] if c["id"] == "facing_gap")["outcome"] == PASS


def test_a_measured_gap_is_not_capped_by_a_shorter_walk() -> None:
    # A mesh measurement over the whole stretch says where the obstruction is; how far the
    # homeowner walked adds nothing there.
    raw = walked(2.0)
    raw["facing"] = [{"wall_id": "w1", "span_ft": [-40, 40], "depth_ft": 9, "plus_minus_ft": 0}]
    assert at_start(raw, 6.0, "facing_gap", PUBLIC).outcome == PASS


def tilted_up(out_ft: float) -> dict:
    raw = shared_fixture()
    raw["overheads"] = []
    seen_clear(raw, "overhead", out_ft)
    return raw


def test_a_tilt_up_view_high_enough_settles_headroom() -> None:
    assert at_start(tilted_up(HEADROOM_NEED + 0.5), 6.0, "headroom", PUBLIC).outcome == PASS


def test_supplying_the_overhead_request_settles_it() -> None:
    raw = tilted_up(HEADROOM_NEED - 2)
    result = answer(raw)
    request = next(m for m in result["missing_evidence"] if m.get("band") == "overhead")
    assert request["out_ft"] > HEADROOM_NEED
    after = answer(supplied(raw, result))
    assert next(c for c in after["checks"] if c["id"] == "headroom")["outcome"] == PASS


def shallow_ground() -> dict:
    """The app's current export: ground seen 1.2 m (3.94 ft) out everywhere."""
    raw = shared_fixture()
    observed_band(raw, "ground", [(-40, 40)], out=3.94)
    return raw


def test_a_ground_request_names_how_far_out() -> None:
    result = answer(shallow_ground())
    request = next(m for m in result["missing_evidence"] if m.get("band") == "ground")
    # The pool clearance reaches its 10 ft radius past the battery's depth.
    assert request["out_ft"] >= D + 10.0
    jsonschema.validate(result, RESULT_SCHEMA)


def test_supplying_the_ground_request_settles_it() -> None:
    raw = shallow_ground()
    after = answer(supplied(raw, answer(raw)))
    unseen = [c["id"] for c in after["checks"] if c.get("unsure_cause") == "unobserved"]
    assert unseen == []


# --- a corner the homeowner marks -----------------------------------------------------------------


def around_a_corner(next_wall_ft: float, right_end: str) -> dict:
    """The meter wall turns a convex corner 10 ft right of the meter, and the app sends the next
    wall as the next piece of the chain, as far as the homeowner followed it."""
    raw = shared_fixture()
    raw["walls"] = [
        {"id": "w1", "baseline": [[-20, 0], [10, 0]], "plus_minus_ft": 0},
        {"id": "w2", "baseline": [[10, 0], [10, -next_wall_ft]], "plus_minus_ft": 0},
    ]
    top = 10 + next_wall_ft
    raw["overheads"] = [{"wall_id": "w1", "span_ft": [-20, 10], "clearance_ft": 9}]
    raw["facing"] = [{"wall_id": "w1", "span_ft": [-20, 10], "depth_ft": 9}]
    raw["ground"] = [
        {"type": "lawn", "polygon": [[-40, 0], [40, 0], [40, 30], [-40, 30]], "plus_minus_ft": 0},
        {"type": "lawn", "polygon": [[10, 0], [40, 0], [40, -40], [10, -40]], "plus_minus_ft": 0},
    ]
    raw["coverage"] = {
        "ends": {"left": {"kind": "limit"}, "right": {"kind": right_end}},
        "observed": [
            {"band": "wall", "span_ft": [-20, top]},
            {"band": "ground", "span_ft": [-20 - 20, top + 20], "out_ft": 30},
            {"band": "overhead", "span_ft": [-20, top]},
            {"band": "facing", "span_ft": [-20, top]},
        ],
    }
    return raw


def test_a_corner_sent_as_the_next_piece_asks_for_no_walk() -> None:
    # Followed round the corner past cable reach, the chain has no open end within reach.
    result = answer(around_a_corner(20.0, "unexplored"))
    assert result["ends"]["right"]["beyond_reach"] is True
    assert not [m for m in result["missing_evidence"] if m["kind"] == "past_end"]


def test_a_corner_left_unexplored_within_reach_is_a_walk_request_when_no_spot_passes() -> None:
    # Stopping at the corner: the wall continues, so a spot round it may exist within reach.
    raw = around_a_corner(20.0, "unexplored")
    raw["walls"] = raw["walls"][:1]
    raw["ground"] = [{"type": "deck", "polygon": [[-40, 0], [40, 0], [40, 30], [-40, 30]]}]
    result = answer(raw)
    assert result["ends"]["right"]["beyond_reach"] is False
    assert any(m["kind"] == "past_end" for m in result["missing_evidence"])


# --- the README's table, exactly ------------------------------------------------------------------

S0 = 6.0
S1 = S0 + 31 / 12
# The README's coverage for a battery at [S0, S1] on a wall with no position error (e = 0).
EXACT = {
    "wall": (0.0, S1 + 3),  # route from the meter, and gas and openings 3 ft either side
    "ground": (S0 - 10, S1 + 10, D + 10),  # the pool clearance reaches furthest
    "facing": (S0, S1),
    "overhead": (S0, S1),
}


def readme_coverage(**trim: float) -> dict:
    raw = shared_fixture()
    observed = []
    for band, span in EXACT.items():
        cut = trim.get(band, 0.0)
        if band == "ground":
            a, b, out = span
            observed.append({"band": band, "span_ft": [a, b], "out_ft": out - cut})
        else:
            observed.append({"band": band, "span_ft": [span[0], span[1] - cut]})
    raw["coverage"]["observed"] = observed
    return raw


def unobserved_at_spot(raw: dict) -> list[str]:
    candidate = evaluate_start(parsed(raw, PUBLIC), PUBLIC, S0)
    return [c.id for c in candidate.checks if c.unsure_cause == "unobserved"]


def test_the_readme_coverage_settles_every_check() -> None:
    assert unobserved_at_spot(readme_coverage()) == []


def test_less_than_the_readme_coverage_leaves_a_check_unseen() -> None:
    for band in EXACT:
        assert unobserved_at_spot(readme_coverage(**{band: 0.01})) != [], band
