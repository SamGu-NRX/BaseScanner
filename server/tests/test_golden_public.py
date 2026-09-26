"""The 14 public golden tests from docs/research/t3-lane-c-review.md (branch t3/research).

Thresholds are the test settings in tests/helpers.py (GOLDEN_RULES), not Base policy. Every scene
starts from the shared fixture: wall w1 along z = 0 with s = x, the meter at 0, outward +z, a lawn
pad at s = [6, 9] and deck everywhere else, both ends observed, facing gap and headroom 9, exact
geometry. Where the review writes a scene whose walls run right to left (test 04), the walls are
listed left to right as scene.schema.json requires; the expected plan positions are unchanged.
"""

import json
import math
from pathlib import Path

import pytest
from helpers import (
    D,
    W,
    at_start,
    check,
    everything_observed,
    golden_rules,
    observed_band,
    pads_ground,
    parsed,
    rect,
    run,
    shared_fixture,
)
from jsonschema import Draft202012Validator

from solver import Solver, evaluate_start

RESULT = Draft202012Validator(
    json.loads((Path(__file__).parents[1] / "schemas" / "result.schema.json").read_text())
)


def solve_valid(raw, rules=None):
    result = run(raw, rules)
    RESULT.validate(result)
    return result


def flat(values):
    return [v for x in values for v in (flat(x) if isinstance(x, list) else [x])]


def approx(values, expected):
    assert flat(values) == pytest.approx(flat(expected), abs=1e-6)


def pad_runs_fail_only(result, check_id, pad=(6, 9)):
    """Every sweep run of starts on the pad fails exactly this one check."""
    runs = [
        r
        for r in result["sweep"]
        if r["start_ft"][0] >= pad[0] - 1e-5 and r["start_ft"][1] <= pad[1] - W + 1e-5
    ]
    return bool(runs) and all(r["failing"] == [check_id] for r in runs)


def with_gas(raw, geometry, span=(7, 7.5), plus_minus=0.0):
    raw["objects"].append(
        {
            "type": "gas_meter",
            "wall_id": raw["walls"][0]["id"],
            "span_ft": list(span),
            "source": "tap",
            "plus_minus_ft": plus_minus,
            "footprint": geometry,
        }
    )
    return raw


def test_01_fully_observed_spot_passes_without_unrelated_views() -> None:
    raw = shared_fixture()
    raw["objects"].append(
        {
            "type": "garage_door",
            "wall_id": "w1",
            "span_ft": [-12, -8],
            "bottom_ft": 0,
            "top_ft": 7,
            "source": "tap",
            "plus_minus_ft": 0,
        }
    )
    # The wall past the garage, on the far side of the meter, was never seen.
    raw["coverage"] = everything_observed(-8, 40)
    raw["coverage"]["ends"]["left"] = {"kind": "unexplored"}
    result = solve_valid(raw)
    assert result["decision"] == "pass"
    approx(result["spot"]["span_ft"], [6, 103 / 12])
    approx(result["spot"]["footprint"], [[6, 0], [103 / 12, 0], [103 / 12, D], [6, D]])
    approx([result["route"]["length_ft"]], [6])
    assert result["missing_evidence"] == []


def test_02_no_selected_policy_means_no_automatic_approval() -> None:
    rules = golden_rules(policy={"id": None, "auto_approve": False})
    result = solve_valid(shared_fixture(), rules)
    assert result["decision"] == "manual_review"
    assert "policy_not_approved" in [r["code"] for r in result["reasons"]]
    assert result["spot"]["outcome"] == "pass"


def test_03_negative_s_uses_the_near_edge() -> None:
    raw = shared_fixture()
    raw["ground"] = pads_ground([(-9, -6), (7, 10)])
    result = solve_valid(raw)
    assert result["decision"] == "pass"
    approx(result["spot"]["span_ft"], [-103 / 12, -6])
    approx([result["route"]["length_ft"]], [6])


def corner_scene():
    # Review's test 04 with the walls listed left to right seen from outside: w2 comes down x = 4
    # from z = 12 to the corner, then w1 runs along z = 0 to x = -12 (outward -z).
    return {
        "meter": {"pos": [0, 5, 0], "wall_id": "w1", "plus_minus_ft": 0},
        "walls": [
            {"id": "w2", "baseline": [[4, 12], [4, 0]], "plus_minus_ft": 0},
            {"id": "w1", "baseline": [[4, 0], [-12, 0]], "plus_minus_ft": 0},
        ],
        "objects": [],
        "ground": [
            {"type": "lawn", "polygon": rect(4, 30, 2, 5), "plus_minus_ft": 0},
            {"type": "deck", "polygon": rect(4, 30, 5, 30), "plus_minus_ft": 0},
            {"type": "deck", "polygon": rect(4, 30, -30, 2), "plus_minus_ft": 0},
            {"type": "deck", "polygon": rect(-40, 4, -30, 0), "plus_minus_ft": 0},
        ],
        "overheads": [],
        "facing": [],
        "coverage": everything_observed(-40, 40),
    }


def test_04_corner_allows_adjacent_wall_not_a_bent_battery() -> None:
    raw = corner_scene()
    result = solve_valid(raw)
    assert result["decision"] == "pass"
    spot = result["spot"]
    assert spot["wall_id"] == "w2"
    xs = [p[0] for p in spot["footprint"]]
    zs = [p[1] for p in spot["footprint"]]
    approx([min(xs), max(xs)], [4, 35 / 6])
    approx([min(zs), max(zs)], [2, 55 / 12])
    approx([result["route"]["length_ft"]], [6])

    # The review's candidate s = [3, 67/12] runs 1 ft along w1 and 19/12 ft round the corner.
    # Listed left to right that is s = [-67/12, -3]: it must fail backing, not bend.
    corner = evaluate_start(parsed(raw), golden_rules(), -67 / 12)
    backing = next(c for c in corner.checks if c.id == "wall_backing")
    assert backing.outcome == "fail"
    assert corner.outcome == "fail"


def test_05_inside_corner_gas_distance_is_euclidean() -> None:
    raw = {
        "meter": {"pos": [-6, 5, 0], "wall_id": "w1", "plus_minus_ft": 0},
        "walls": [
            {"id": "w1", "baseline": [[-6, 0], [4, 0]], "plus_minus_ft": 0},
            {"id": "w2", "baseline": [[4, 0], [4, 20]], "plus_minus_ft": 0},
        ],
        "objects": [],
        "ground": [
            {"type": "lawn", "polygon": rect(0, 3, 0, 30), "plus_minus_ft": 0},
            {"type": "deck", "polygon": rect(-40, 0, 0, 30), "plus_minus_ft": 0},
            {"type": "deck", "polygon": rect(3, 4, 0, 30), "plus_minus_ft": 0},
        ],
        "overheads": [],
        "facing": [],
        "coverage": everything_observed(-40, 60),
    }
    with_gas(raw, [[4, 4]], span=(10, 10))
    result = solve_valid(raw)
    assert result["decision"] == "reject"
    assert result["spot"] is None
    assert pad_runs_fail_only(result, "gas_clearance", pad=(6, 9))
    all_fail = next(r for r in result["reasons"] if r["code"] == "all_spots_fail")
    assert "gas_clearance" in all_fail["checks"]
    gas = at_start(raw, 6, "gas_clearance")
    assert gas.outcome == "fail"
    # Straight-line distance from the footprint x = [0, 31/12], z = [0, 11/6] to the gas at
    # [4, 4], not the 65/12 ft measured along the unrolled wall.
    assert gas.measured == pytest.approx(math.hypot(17 / 12, 13 / 6))
    assert gas.measured < 3 < 65 / 12


def test_06_every_part_of_an_object_counts() -> None:
    # Gas meter body 10 ft out, its regulator pipe reaching x = 7, z = 23/6.
    raw = with_gas(shared_fixture(), [[7.5, 10], [7, 23 / 6]])
    result = solve_valid(raw)
    assert result["decision"] == "reject"
    gas = at_start(raw, 6, "gas_clearance")
    assert gas.outcome == "fail"
    assert gas.measured == pytest.approx(2)
    assert pad_runs_fail_only(result, "gas_clearance")


@pytest.mark.parametrize(
    ("underside", "plus_minus", "expected"),
    [
        (6.5 - 1, 0.5, "reject"),
        (6.5 + 0.7, 0.5, "pass"),
        (6.5 + 0.3, 0.5, "manual_review"),
    ],
)
def test_07_headroom_covers_the_whole_footprint(underside, plus_minus, expected) -> None:
    raw = shared_fixture()
    # The ray 1 ft out reads 9 (the base overhead entry); a landing spans the whole pad.
    raw["overheads"].append(
        {"wall_id": "w1", "span_ft": [6, 9], "clearance_ft": underside, "plus_minus_ft": plus_minus}
    )
    assert solve_valid(raw)["decision"] == expected


def test_07_unobserved_headroom_is_manual_review() -> None:
    raw = shared_fixture()
    observed_band(raw, "overhead", [(-40, 5), (10, 40)])
    result = solve_valid(raw)
    assert result["decision"] == "manual_review"
    head = check(result, "headroom")
    assert head["outcome"] == "unsure"
    assert head["unsure_cause"] == "unobserved"
    assert any(m.get("band") == "overhead" for m in result["missing_evidence"])


def test_08_route_across_a_garage_decides_the_result() -> None:
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
            "plus_minus_ft": 0,
        }
    )
    result = solve_valid(raw)
    assert result["decision"] == "reject"
    assert pad_runs_fail_only(result, "route_path", pad=(10, 13))


def test_08_no_route_interpolates_across_missing_wall() -> None:
    raw = shared_fixture()
    raw["ground"] = pads_ground([(10, 13)])
    raw["walls"] = [
        {"id": "w1", "baseline": [[-40, 0], [3, 0]], "plus_minus_ft": 0},
        {"id": "w1b", "baseline": [[4, 0], [40, 0]], "plus_minus_ft": 0},
    ]
    raw["facing"][0]["span_ft"] = [-40, 3]
    raw["overheads"][0]["span_ft"] = [-40, 3]
    raw["facing"].append({"wall_id": "w1b", "span_ft": [4, 40], "depth_ft": 9, "plus_minus_ft": 0})
    raw["overheads"].append(
        {"wall_id": "w1b", "span_ft": [4, 40], "clearance_ft": 9, "plus_minus_ft": 0}
    )
    scene = parsed(raw)
    assert [(g.s0, g.s1) for g in scene.gaps] == [(3, 4)]
    result = solve_valid(raw)
    assert result["decision"] == "reject"
    assert pad_runs_fail_only(result, "route_path", pad=(10, 13))


def reach_scene(start, meter_error=0.0):
    raw = shared_fixture()
    raw["meter"]["plus_minus_ft"] = meter_error
    raw["ground"] = pads_ground([(start, start + 3)])
    return raw


@pytest.mark.parametrize(
    ("start", "meter_error", "expected"),
    [
        (15 - 1, 0.0, "pass"),  # confident reach - 1
        (15, 0.0, "manual_review"),  # on the confident-reach line
        (15 + 1, 0.0, "manual_review"),
        (20, 0.0, "manual_review"),  # on the maximum
        (20 + 1, 0.0, "reject"),
        (20 + 0.2, 0.3, "manual_review"),  # not clearly over the maximum
        (20 + 0.4, 0.3, "reject"),
    ],
)
def test_09_reach_uses_routed_length(start, meter_error, expected) -> None:
    result = solve_valid(reach_scene(start, meter_error))
    assert result["decision"] == expected


def test_09_vertical_run_counts_toward_reach() -> None:
    # Pad at confident reach - 4; a window reaching the ground forces the cable 2.5 ft up and back.
    raw = reach_scene(15 - 4)
    raw["objects"].append(
        {
            "type": "window",
            "wall_id": "w1",
            "span_ft": [2, 5],
            "bottom_ft": 0,
            "top_ft": 3.5,
            "source": "tap",
            "plus_minus_ft": 0,
        }
    )
    result = solve_valid(raw)
    assert result["decision"] == "manual_review"
    route = result["route"]
    approx([route["length_ft"]], [15 + 1])
    approx([d["extra_ft"] for d in route["detours"]], [5])


def gas_gap_scene(gap, gas_error, wall_error=0.0):
    raw = shared_fixture()
    raw["walls"][0]["plus_minus_ft"] = wall_error
    # A gas pipe parallel to the wall: every start on the pad has the same gap.
    return with_gas(raw, [[-40, D + gap], [40, D + gap]], span=(-40, 40), plus_minus=gas_error)


@pytest.mark.parametrize("e", [0.3, 0.5, 1.5])
@pytest.mark.parametrize(
    ("offset", "expected"),
    [
        (lambda e: e + 0.01, "pass"),
        (lambda e: e, "manual_review"),
        (lambda e: -e, "manual_review"),
        (lambda e: -e - 0.01, "reject"),
    ],
    ids=["T+e+0.01", "T+e", "T-e", "T-e-0.01"],
)
def test_10_margins_cover_equality(e, offset, expected) -> None:
    result = solve_valid(gas_gap_scene(3 + offset(e), e))
    assert result["decision"] == expected


def test_10_compound_error_adds() -> None:
    # Gap 3.5 derived from two positions each ±0.3 (the gas pipe and the wall): error ±0.6.
    result = solve_valid(gas_gap_scene(3.5, 0.3, wall_error=0.3))
    assert result["decision"] == "manual_review"
    gas = check(result, "gas_clearance")
    assert gas["outcome"] == "unsure"
    assert gas["plus_minus_ft"] == pytest.approx(0.6)
    assert gas["unsure_cause"] == "margin"


def l_scene(variant):
    """w1 along z = 0 to a corner at s = 12, then w2 down x = 12 (outward +x) to s = 32 (s = 12 - z
    on w2). A gas pipe 1 ft in front of the battery's front face fails every spot it runs along."""
    raw = shared_fixture()
    raw["facing"], raw["overheads"] = [], []
    walls = [{"id": "w1", "baseline": [[-40, 0], [12, 0]], "plus_minus_ft": 0}]
    ground = [
        {"type": "lawn", "polygon": rect(-9, -6, 0, 30), "plus_minus_ft": 0},
        {"type": "deck", "polygon": rect(-40, -9, 0, 30), "plus_minus_ft": 0},
        {"type": "deck", "polygon": rect(-6, 40, 0, 30), "plus_minus_ft": 0},
    ]
    front = D + 1
    # (d) adds a valid pad before the gate: the pipe along w1 stops 4 ft short of it.
    with_gas(raw, [[-2 if variant == "d" else -40, front], [12 + front, front]], span=(-40, 12))
    if variant == "a":
        raw["coverage"] = everything_observed(-40, 12)
        raw["coverage"]["ends"]["right"] = {"kind": "unexplored"}
    elif variant == "b":
        walls.append({"id": "w2", "baseline": [[12, 0], [12, -20]], "plus_minus_ft": 0})
        ground.append({"type": "deck", "polygon": rect(12, 40, -20, 0), "plus_minus_ft": 0})
        with_gas(raw, [[12 + front, front], [12 + front, -20]], span=(12, 32))
        raw["coverage"] = everything_observed(-40, 40)
    else:
        # A closed gate hides the ground along w2 from s = 14 to 20, within cable reach. Past the
        # gate the wall is seen again to its real end.
        walls.append({"id": "w2", "baseline": [[12, 0], [12, -20]], "plus_minus_ft": 0})
        ground.append({"type": "deck", "polygon": rect(12, 40, -2, 0), "plus_minus_ft": 0})
        ground.append({"type": "deck", "polygon": rect(12, 40, -40, -8), "plus_minus_ft": 0})
        with_gas(raw, [[12 + front, front], [12 + front, -1]], span=(12, 13))
        raw["coverage"] = everything_observed(-40, 40)
        observed_band(raw, "ground", [(-40, 14), (20, 40)])
    raw["walls"], raw["ground"] = walls, ground
    return raw


def test_11a_unseen_wall_past_a_tapped_corner_is_manual_review() -> None:
    result = solve_valid(l_scene("a"))
    assert result["decision"] == "manual_review"
    assert [m.get("side") for m in result["missing_evidence"] if m["kind"] == "past_end"] == [
        "right"
    ]


def test_11b_reject_records_both_real_wall_ends() -> None:
    result = solve_valid(l_scene("b"))
    assert result["decision"] == "reject"
    assert result["spot"] is None
    assert result["missing_evidence"] == []
    assert result["ends"]["left"]["kind"] == "limit"
    assert result["ends"]["right"]["kind"] == "limit"
    approx([result["ends"]["left"]["s_ft"], result["ends"]["right"]["s_ft"]], [-40, 32])


def test_11c_ground_hidden_behind_a_gate_is_manual_review() -> None:
    result = solve_valid(l_scene("c"))
    assert result["decision"] == "manual_review"
    grounds = [m for m in result["missing_evidence"] if m.get("band") == "ground"]
    assert grounds
    assert all(m["span_ft"][1] > 14 and m["span_ft"][0] < 20 for m in grounds)


def test_11d_valid_pad_before_the_gate_passes_without_photo_request() -> None:
    result = solve_valid(l_scene("d"))
    assert result["decision"] == "pass"
    approx(result["spot"]["span_ft"], [-103 / 12, -6])
    assert result["missing_evidence"] == []


def two_ft_rules():
    return golden_rules(battery={"width_ft": {"value": 2.0, "source": "test battery"}})


def test_12_sub_grid_interval_is_found() -> None:
    raw = shared_fixture()
    raw["ground"] = pads_ground([(4, 12.1)])
    for span in ([3, 4], [12.1, 13.1]):
        raw["objects"].append(
            {
                "type": "window",
                "wall_id": "w1",
                "span_ft": span,
                "bottom_ft": 3,
                "top_ft": 6,
                "attrs": {"operable": True},
                "source": "tap",
                "plus_minus_ft": 0,
            }
        )
    result = solve_valid(raw, two_ft_rules())
    assert result["decision"] == "pass"
    s0, s1 = result["spot"]["span_ft"]
    assert 7 < s0 < 7.1
    assert s1 == pytest.approx(s0 + 2)


def test_12_last_start_is_enumerated() -> None:
    raw = shared_fixture()
    raw["walls"] = [
        {"id": "w0", "baseline": [[-3, 0], [3, 0]], "plus_minus_ft": 0},
        {"id": "w1", "baseline": [[6, 0], [8, 0]], "plus_minus_ft": 0},
    ]
    raw["meter"]["wall_id"] = "w0"
    raw["facing"], raw["overheads"] = [], []
    loaded = two_ft_rules()
    scene = parsed(raw, loaded)
    piece = next(p for p in scene.walls if p.wall_id == "w1")
    assert Solver(scene, loaded).starts(piece) == [6.0]


def f_and_s_scene(with_s=True):
    raw = shared_fixture()
    raw["ground"] = pads_ground([(6, 9), (10, 13)] if with_s else [(6, 9)])
    # Gas 3.2 ± 0.3 from every footprint on pad F; well clear of pad S.
    return with_gas(raw, [[7.5, D + 3.2]], span=(7.5, 7.5), plus_minus=0.3)


def test_13_unsure_spot_never_outranks_a_pass() -> None:
    result = solve_valid(f_and_s_scene())
    assert result["decision"] == "pass"
    assert result["spot"]["span_ft"][0] == pytest.approx(10)
    approx([result["route"]["length_ft"]], [10])


def test_13_margin_only_review_asks_for_no_photos() -> None:
    result = solve_valid(f_and_s_scene(with_s=False))
    assert result["decision"] == "manual_review"
    assert check(result, "gas_clearance")["unsure_cause"] == "margin"
    assert result["missing_evidence"] == []


def test_14_result_records_its_measurements() -> None:
    result = solve_valid(shared_fixture())
    assert result["decision"] == "pass"
    assert result["policy"]["id"] == "golden-test"
    assert result["policy"]["version"] == "1"
    assert len(result["policy"]["rules_sha256"]) == 64
    spot = result["spot"]
    approx(spot["meter_offset_ft"], [6 + W / 2, D / 2])
    approx([result["route"]["length_ft"], result["route"]["plus_minus_ft"]], [6, 0])
    facing = check(result, "facing_gap")
    head = check(result, "headroom")
    approx([facing["measured_ft"], head["measured_ft"]], [9, 9])
    for c in result["checks"]:
        assert c["outcome"] == "pass"
        assert c["rule"]["source"]
    assert result["missing_evidence"] == []


def test_result_is_stable_for_the_same_input() -> None:
    a = run(shared_fixture())
    b = run(shared_fixture())
    a["stats"].pop("elapsed_ms")
    b["stats"].pop("elapsed_ms")
    assert a == b
