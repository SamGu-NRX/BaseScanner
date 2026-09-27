import copy
import hashlib
import json
from dataclasses import replace

import pytest

from hsverify.resultcheck import (
    Need,
    RuleSet,
    assumption_mismatches,
    battery_error,
    chain_ends_s,
    comparable,
    coverage_problems,
    expectation_problems,
    invariant_problems,
    less_coverage_problems,
    margin_problem,
    mirror_scene,
    missing_evidence_problems,
    more_error_problems,
    observed,
    outcome_at,
    outcome_lengths,
    run_starts,
    tape_to_tap,
    with_ground_short_of,
    with_less_coverage,
    with_more_error,
    with_requests_captured,
)

# Small radii keep the geometry checkable by hand: a battery 31 x 22 in, gas and openings 1 ft.
RULES = RuleSet(
    width_ft=31 / 12,
    depth_ft=22 / 12,
    needs={
        "ground_surface": (Need("ground", 0.0),),
        "gas_clearance": (Need("ground", 1.0),),
        "opening_clearance": (Need("wall", 1.0, height=6.5),),
    },
    errors={
        "tap": 0.3,
        "vlm": 1.5,
        "tape": 0.05,
        "wall": 0.3,
        "mesh": 0.5,
        "plane": 0.75,
        "meter": 0.3,
        "drift_per_ft": 0.16,
    },
    step_ft=1 / 6,  # the server's 2 in
)

SCENE = {
    "meter": {"pos": [0.0, 4.0, 0.0], "wall_id": "w1"},
    # An explicit zero error keeps the reach arithmetic in these tests to the radii alone.
    "walls": [{"id": "w1", "baseline": [[-12.0, 0.0], [12.0, 0.0]], "plus_minus_ft": 0.0}],
    "objects": [
        {
            "type": "gas_meter",
            "wall_id": "w1",
            "span_ft": [-6.0, -5.0],
            "source": "tap",
            "footprint": [[-6.0, 0.5], [-5.0, 1.0]],
        },
    ],
    "coverage": {
        "ends": {"left": {"kind": "limit"}, "right": {"kind": "unexplored"}},
        "observed": [
            {"band": "wall", "span_ft": [-12.0, 10.0]},
            {"band": "ground", "span_ft": [-12.0, 10.0], "out_ft": 3.0},
            {"band": "ground", "span_ft": [10.0, 12.0], "out_ft": 1.0},
        ],
    },
}


def check(outcome="pass", measured=5.0, error=0.3, threshold=3.0, cmp="at_least", cause=None):
    c = {
        "id": "gas_clearance",
        "label": "Gas",
        "outcome": outcome,
        "reason": "",
        "measured_ft": measured,
        "plus_minus_ft": error,
        "threshold_ft": threshold,
        "comparison": cmp,
        "rule": {"key": "gas_clearance_ft", "source": "", "placeholder": False},
    }
    if cause:
        c["unsure_cause"] = cause
    return c


def result(decision="manual_review", spot=True, checks=None, sweep=None, sent=b"{}"):
    s = None
    if spot:
        s = {
            "outcome": "pass",
            "wall_id": "w1",
            "segment": 0,
            "span_ft": [1.0, 1.0 + 31 / 12],
            "width_ft": 31 / 12,
            "depth_ft": 22 / 12,
            "height_ft": 3.3,
            "footprint": [[1, 0], [3.58, 0], [3.58, 1.83], [1, 1.83]],
            "center": [2.29, 0.92],
            "along": [1, 0],
            "outward": [0, 1],
            "meter_offset_ft": [2.29, 0.92],
            "route_length_ft": 1.0,
        }
    return {
        "schema_version": "1.0",
        "decision": decision,
        "summary": "",
        "reasons": [] if decision == "pass" else [{"code": "policy_not_approved", "message": ""}],
        "policy": {
            "id": None,
            "version": None,
            "auto_approve": decision != "manual_review",
            "sources": ["public"],
            "rules_sha256": "0" * 64,
        },
        "spot": s,
        "route": None if s is None else {"outcome": "pass"},
        "checks": [check()] if checks is None else checks,
        "missing_evidence": [],
        "ends": {},
        "sweep": sweep
        if sweep is not None
        else [
            {
                "wall_id": "w1",
                "start_ft": [1.0, 1.0],
                "outcome": "pass",
                "failing": [],
                "unsure": [],
            },
        ],
        "stats": {
            "candidates": 1,
            "pass": 1,
            "unsure": 0,
            "fail": 0,
            "elapsed_ms": 3.0,
            "input_sha256": hashlib.sha256(sent).hexdigest(),
        },
    }


def test_consistent_result_has_no_problems():
    assert invariant_problems(SCENE, result(), sent=b"{}", rules=RULES) == []


@pytest.mark.parametrize(
    ("cmp", "measured", "error", "threshold", "expected"),
    [
        ("at_least", 3.31, 0.3, 3.0, "pass"),
        ("at_least", 3.3, 0.3, 3.0, "unsure"),  # margin equals the error
        ("at_least", 2.7, 0.3, 3.0, "unsure"),
        ("at_least", 2.69, 0.3, 3.0, "fail"),
        ("at_most", 19.69, 0.3, 20.0, "pass"),
        ("at_most", 19.7, 0.3, 20.0, "unsure"),
        ("at_most", 20.31, 0.3, 20.0, "fail"),
    ],
)
def test_margin_rule(cmp, measured, error, threshold, expected):
    for outcome in ("pass", "fail", "unsure"):
        problem = margin_problem(check(outcome, measured, error, threshold, cmp))
        assert (problem is None) == (outcome == expected), (outcome, problem)


def test_unsure_for_another_cause_may_sit_on_passing_numbers_but_not_failing_ones():
    assert margin_problem(check("unsure", 5.9, 0.6, 3.0, cause="unobserved")) is None
    assert margin_problem(check("unsure", 3.1, 0.6, 3.0, cause="unknown_attribute")) is None
    problem = margin_problem(check("unsure", 1.0, 0.6, 3.0, cause="unobserved"))
    assert problem is not None and "should be fail" in problem
    # A margin-caused unsure must really be inside the band.
    assert margin_problem(check("unsure", 5.9, 0.6, 3.0, cause="margin")) is not None


def route(outcome, measured, error=0.0, cause=None):
    c = check(outcome, measured, error, 20.0, "at_most", cause)
    c["review_threshold_ft"] = 15.0
    return c


def test_review_band_blocks_a_pass_and_is_not_a_margin():
    assert margin_problem(route("pass", 14.0)) is None
    assert "should be unsure" in margin_problem(route("pass", 16.0))
    assert margin_problem(route("unsure", 16.0, cause="rule_requires_review")) is None
    assert "not within its error of any line" in margin_problem(
        route("unsure", 16.0, cause="margin")
    )
    # Within error of either line, margin is the right cause.
    assert margin_problem(route("unsure", 15.2, 0.3, cause="margin")) is None
    assert margin_problem(route("unsure", 19.9, 0.3, cause="margin")) is None
    assert margin_problem(route("unsure", 15.0, cause="margin")) is None  # on the line
    assert margin_problem(route("fail", 20.4, 0.3)) is None


def test_margin_rule_skips_checks_without_numbers():
    assert margin_problem(check("unsure", measured=None, cause="unobserved")) is None


def test_decision_consistency():
    bad_pass = result("pass", checks=[check("unsure", 3.2, cause="margin")])
    msgs = invariant_problems(SCENE, bad_pass)
    assert any("checks not passing" in m for m in msgs)
    reject_with_spot = result("reject")
    assert any("reject but a spot" in m for m in invariant_problems(SCENE, reject_with_spot))
    auto_off = result("pass")
    auto_off["policy"]["auto_approve"] = False
    assert any("auto_approve" in m for m in invariant_problems(SCENE, auto_off))


def test_unsure_cause_bookkeeping():
    msgs = invariant_problems(SCENE, result(checks=[check("unsure", 3.2)]))
    assert any("unsure without unsure_cause" in m for m in msgs)
    msgs = invariant_problems(SCENE, result(checks=[check("pass", cause="margin")]))
    assert any("unsure_cause on a pass check" in m for m in msgs)


def test_counts_hash_and_offset():
    r = result()
    r["stats"]["fail"] = 2
    r["spot"]["meter_offset_ft"] = [2.0, 0.92]
    msgs = invariant_problems(SCENE, r, sent=b"other bytes")
    assert any(m.startswith("stats: pass") for m in msgs)
    assert any("input_sha256" in m for m in msgs)
    assert any("meter_offset_ft" in m for m in msgs)


def test_observed_merges_and_filters_ground_depth():
    assert observed(SCENE, "wall") == [(-12.0, 10.0)]
    assert observed(SCENE, "ground", min_out_ft=2.0) == [(-12.0, 10.0)]
    assert observed(SCENE, "ground", min_out_ft=0.5) == [(-12.0, 12.0)]
    assert observed({"meter": {}}, "wall") == []


def with_ground(out_ft: float, span: list[float]) -> dict:
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"][1:] = [{"band": "ground", "span_ft": span, "out_ft": out_ft}]
    return scene


def test_a_pass_needs_ground_out_to_depth_plus_each_radius():
    # Start 1 covers [1, 3.58]. Gas (radius 1) needs ground out to 1.83 + 1 = 2.83 ft.
    msgs = invariant_problems(with_ground(2.5, [-12.0, 10.0]), result(), rules=RULES)
    needs = "gas_clearance needs ground [1.00, 3.58] observed out to 2.83 ft, seen 2.50 ft"
    assert any(needs in m for m in msgs)
    assert invariant_problems(with_ground(2.84, [-12.0, 10.0]), result(), rules=RULES) == []


def test_past_the_battery_the_ground_needed_shrinks_with_distance():
    # d past the battery's left end at 1, gas needs ground out to 1 - d: 0.5 for [0, 0.5].
    scene = with_ground(2.84, [1.0, 10.0])
    scene["coverage"]["observed"] += [
        {"band": "ground", "span_ft": [0.0, 0.5], "out_ft": 0.55},
        {"band": "ground", "span_ft": [0.5, 1.0], "out_ft": 1.0},
    ]
    assert invariant_problems(scene, result(), rules=RULES) == []
    scene["coverage"]["observed"][-1]["out_ft"] = 0.9
    msgs = invariant_problems(scene, result(), rules=RULES)
    assert any("ground [0.50, 1.00] observed out to 1.00 ft, seen 0.90 ft" in m for m in msgs)


def test_a_pass_needs_ground_along_the_wall_to_each_radius_without_slack():
    # Ground from 0.1: the 1 ft gas radius around [1, 3.58] reaches back to 0.
    msgs = invariant_problems(with_ground(3.0, [0.1, 10.0]), result(), rules=RULES)
    assert any("gas_clearance needs ground [0.00, 0.10] observed, none seen" in m for m in msgs)


def test_a_passing_opening_check_needs_the_wall_to_its_radius():
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"][0]["span_ft"] = [0.0, 4.0]  # radius needs [0, 4.58]
    r = result(
        checks=[
            check(),
            {**check(), "id": "opening_clearance", "measured_ft": None, "plus_minus_ft": None},
        ]
    )
    msgs = invariant_problems(scene, r, rules=RULES)
    needs = "check opening_clearance passes but needs wall [0.00, 4.58] observed"
    assert any(needs in m for m in msgs)


def test_pass_whose_route_crosses_unobserved_wall_is_flagged():
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"][0]["span_ft"] = [0.5, 10.0]  # the wall at s = [0, 0.5] unseen
    msgs = invariant_problems(scene, result(), rules=RULES)
    assert any("wall and cable route" in m for m in msgs)


def test_no_coverage_never_passes():
    scene = {k: v for k, v in SCENE.items() if k != "coverage"}
    msgs = invariant_problems(scene, result("pass"), rules=RULES)
    assert any("no coverage at all" in m for m in msgs)


def test_photo_request_for_an_observed_area_is_flagged():
    r = result()
    r["missing_evidence"] = [
        {"kind": "band", "band": "wall", "span_ft": [-3.0, -1.0], "message": ""}
    ]
    assert any("lists as observed" in m for m in invariant_problems(SCENE, r, rules=RULES))


def test_every_unobserved_check_needs_a_request_naming_it():
    unseen = check("unsure", None, cause="unobserved")
    r = result(checks=[unseen])
    # No unobserved_area reason: every position fails anyway, so no photo is owed.
    assert missing_evidence_problems(SCENE, r) == []
    r["reasons"] = [{"code": "unobserved_area", "message": ""}]
    assert missing_evidence_problems(SCENE, r) == [
        "reason unobserved_area but missing_evidence is empty"
    ]
    r["missing_evidence"] = [
        {"kind": "band", "band": "wall", "span_ft": [11, 12], "checks": ["x"], "message": ""}
    ]
    assert missing_evidence_problems(SCENE, r) == [
        "check gas_clearance is unsure (unobserved) but no missing_evidence entry names it"
    ]
    r["missing_evidence"] = [
        {
            "kind": "band",
            "band": "ground",
            "span_ft": [11, 12],
            "checks": ["gas_clearance"],
            "message": "",
        }
    ]
    assert missing_evidence_problems(SCENE, r) == []


def test_the_reach_widens_by_the_battery_position_error():
    # Default wall error at the far edge 3.58: 0.3 + 0.16 x 3.58 = 0.87; gas reach 1.87 ft, so
    # ground out to 1.83 + 1.87 = 3.71 ft in front.
    scene = with_ground(3.6, [-12.0, 10.0])
    del scene["walls"][0]["plus_minus_ft"]
    msgs = invariant_problems(scene, result(), rules=RULES)
    assert any("gas_clearance needs ground [1.00, 3.58] observed out to 3.71 ft" in m for m in msgs)
    scene["coverage"]["observed"][1]["out_ft"] = 3.72
    assert invariant_problems(scene, result(), rules=RULES) == []


def test_a_clearance_is_named_under_each_band_it_lacks():
    two_band = replace(
        RULES,
        needs=RULES.needs | {"gas_clearance": (Need("ground", 1.0), Need("wall", 1.0, height=6.5))},
    )
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"] = []  # nothing seen: both bands missing around the spot
    r = result(checks=[check("unsure", None, cause="unobserved")])
    r["reasons"] = [{"code": "unobserved_area", "message": ""}]
    ground_only = {"kind": "band", "band": "ground", "span_ft": [0, 5], "checks": ["gas_clearance"]}
    r["missing_evidence"] = [ground_only | {"message": ""}]
    assert missing_evidence_problems(scene, r, two_band) == [
        "check gas_clearance is unsure and needs wall [0.00, 4.58] observed higher than 6.5 ft, "
        "but no wall request names it"
    ]
    r["missing_evidence"].append(ground_only | {"band": "wall", "message": ""})
    assert missing_evidence_problems(scene, r, two_band) == []


def test_rules_come_from_rules_yaml_and_a_missing_one_is_loud():
    text = """
battery: {width_ft: {value: 2.5}, depth_ft: {value: 1.5}, height_ft: {value: 3.25}}
errors: {tap_ft: {value: 0.3}, vlm_ft: {value: 1.5}, tape_ft: {value: 0.05},
         wall_ft: {value: 0.3}, mesh_ft: {value: 0.5}, plane_ft: {value: 0.75},
         meter_ft: {value: 0.3}, drift_per_ft: {value: 0.16}}
clearances: {gas_ft: {value: 3}, ac_ft: {value: 3}, battery_ft: {value: 3}, drive_ft: {value: 5},
             pool_ft: {value: 10}, opening_ft: {value: 3}, wall_equipment_ft: {value: 0}}
openings: {exempt_bottom_above_ft: null}
facing: {min_ft: {value: 3}}
headroom: {min_ft: {value: 6.5}}
route: {height_ft: {value: 1}}
sweep: {step_ft: {value: 0.166666666667}}
"""
    rules = RuleSet.from_yaml(text)
    assert rules.needs["pool_clearance"] == (Need("ground", 10.0),)
    assert rules.needs["gas_clearance"] == (Need("ground", 3.0), Need("wall", 3.0, 6.5))
    assert rules.needs["battery_clearance"] == (Need("ground", 3.0), Need("wall", 3.0, 6.5))
    assert rules.needs["opening_clearance"] == (Need("wall", 3.0, 6.5),)
    assert rules.needs["wall_backing"] == (Need("wall", 0.0, 3.25, widen=False),)
    assert rules.needs["facing_gap"] == (Need("facing", 0.0, 4.5),)
    assert rules.needs["headroom"] == (Need("overhead", 0.0, 6.5),)
    assert (rules.width_ft, rules.errors["plane"], rules.route_height_ft) == (2.5, 0.75, 1.0)
    lower = RuleSet.from_yaml(
        text.replace("exempt_bottom_above_ft: null", "exempt_bottom_above_ft: 2")
    )
    assert lower.needs["opening_clearance"] == (Need("wall", 3.0, 2.0),)
    with pytest.raises(ValueError, match=r"rules\.yaml has no clearances\.pool_ft"):
        RuleSet.from_yaml(text.replace("pool_ft: {value: 10}, ", ""))


def test_expectations():
    r = result(
        sweep=[
            {
                "wall_id": "w1",
                "start_ft": [-9.0, -4.0],
                "outcome": "fail",
                "failing": ["gas_clearance"],
                "unsure": [],
            },
            {
                "wall_id": "w1",
                "start_ft": [1.0, 1.0],
                "outcome": "pass",
                "failing": [],
                "unsure": [],
            },
        ]
    )
    ok = {
        "decision_not": ["pass"],
        "spot": {"wall_id": "w1", "span_within": [0.0, 4.0]},
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [-8, -5], "outcome": "fail", "failing_match": "gas"}
        ],
        "checks": [{"match": "gas", "outcome": "pass"}],
        "missing_evidence_empty": True,
    }
    assert expectation_problems(ok, r) == []
    bad = {
        "decision_in": ["reject"],
        "spot": None,
        "sweep_runs": [{"wall_id": "w1", "start_ft": [0, 2], "outcome": "fail"}],
        "checks": [{"match": "route", "outcome": "pass"}],
    }
    msgs = expectation_problems(bad, r)
    assert len(msgs) == 4, msgs


def test_outcome_not_rules_out_one_outcome_and_tolerates_no_runs():
    r = result(
        sweep=[
            {
                "wall_id": "w1",
                "start_ft": [0.0, 2.0],
                "outcome": "unsure",
                "failing": [],
                "unsure": [],
            },
            {
                "wall_id": "w1",
                "start_ft": [2.1, 3.0],
                "outcome": "pass",
                "failing": [],
                "unsure": [],
            },
        ]
    )
    ok = {
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [0.5, 1.5], "outcome_not": "pass"},
            {"wall_id": "w9", "start_ft": [0, 9], "outcome_not": "pass"},
        ]
    }
    assert expectation_problems(ok, r) == []
    bad = {
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [0.5, 2.5], "outcome_not": "pass", "reason": "window"}
        ]
    }
    assert expectation_problems(bad, r) == [
        "sweep w1 starts [2.1, 3.0] is pass, which this case rules out (window)"
    ]


def test_pinned_check_numbers():
    r = result()
    assert expectation_problems({"checks": [{"match": "gas", "measured_ft": 5.0000004}]}, r) == []
    msgs = expectation_problems({"checks": [{"match": "gas", "measured_ft": 4.5}]}, r)
    assert msgs == ["check gas_clearance: measured_ft 5.0, expected 4.5"]


def test_assumption_mismatch():
    assert assumption_mismatches({"gas": 3.0}, result()) == []
    assert assumption_mismatches({"gas": 4.0}, result())


def test_mirror_negates_s_and_keeps_baselines_left_to_right():
    m = mirror_scene(SCENE)
    assert m["walls"][0]["baseline"] == [[-12.0, 0.0], [12.0, 0.0]]
    assert m["objects"][0]["span_ft"] == [5.0, 6.0]
    assert m["objects"][0]["footprint"] == [[6.0, 0.5], [5.0, 1.0]]
    assert m["coverage"]["observed"][0]["span_ft"] == [-10.0, 12.0]
    assert m["coverage"]["ends"] == {"left": {"kind": "unexplored"}, "right": {"kind": "limit"}}
    assert mirror_scene(m) == json.loads(json.dumps(SCENE))  # an involution
    assert SCENE["objects"][0]["span_ft"] == [-6.0, -5.0]  # input untouched


def test_mirror_reverses_a_wall_chain():
    scene = {
        "meter": {"pos": [0.0, 4.0, 0.0], "wall_id": "w1"},
        "walls": [
            {"id": "w1", "baseline": [[-4.0, 0.0], [4.0, 0.0]]},
            {"id": "w2", "baseline": [[4.0, 0.0], [4.0, 12.0]]},
        ],
    }
    m = mirror_scene(scene)
    assert [w["id"] for w in m["walls"]] == ["w2", "w1"]
    assert m["walls"][0]["baseline"] == [[-4.0, 12.0], [-4.0, 0.0]]
    assert m["walls"][1]["baseline"] == [[-4.0, 0.0], [4.0, 0.0]]
    # Chain stays connected: w2 ends where w1 starts.
    assert m["walls"][0]["baseline"][-1] == m["walls"][1]["baseline"][0]


def test_outcome_lengths_and_comparable():
    r = result(
        sweep=[
            {
                "wall_id": "w1",
                "start_ft": [0.0, 2.0],
                "outcome": "pass",
                "failing": [],
                "unsure": [],
            },
            {
                "wall_id": "w1",
                "start_ft": [2.0, 3.0],
                "outcome": "fail",
                "failing": [],
                "unsure": [],
            },
        ]
    )
    assert outcome_lengths(r) == {"pass": 2.0, "unsure": 0.0, "fail": 1.0}
    other = copy.deepcopy(r)
    other["stats"]["elapsed_ms"] = 99.0
    assert comparable(r) == comparable(other)


def run(a, b, outcome, wall="w1"):
    return {"wall_id": wall, "start_ft": [a, b], "outcome": outcome, "failing": [], "unsure": []}


def swept(*runs, decision="manual_review"):
    r = result(decision=decision, sweep=list(runs))
    return r


def test_start_outcomes_expectation():
    r = swept(run(0.0, 2.0, "fail"), run(2.1667, 5.0, "unsure"))
    assert outcome_at(r, "w1", 1.0) == "fail" and outcome_at(r, "w1", 2.1) is None
    ok = {"start_outcomes": [{"wall_id": "w1", "start_ft": 3.0, "outcome": "unsure"}]}
    assert expectation_problems(ok, r) == []
    bad = {
        "start_outcomes": [
            {"wall_id": "w1", "start_ft": 1.0, "outcome": "unsure", "why": "inside the error band"}
        ]
    }
    assert expectation_problems(bad, r) == [
        "start w1 1.0 is fail, expected unsure (inside the error band)"
    ]


@pytest.mark.parametrize(
    ("before", "after", "allowed"),
    [
        ("pass", "unsure", True),
        ("fail", "unsure", True),
        ("unsure", "unsure", True),
        ("unsure", "fail", False),
        ("unsure", "pass", False),
        ("fail", "pass", False),
        ("pass", "fail", False),
    ],
)
def test_more_error_only_moves_toward_unsure(before, after, allowed):
    msgs = more_error_problems(swept(run(0, 4, before)), swept(run(0, 4, after)), "more error")
    assert (msgs == []) == allowed, msgs


def test_less_coverage_never_creates_a_pass():
    assert less_coverage_problems(swept(run(0, 4, "pass")), swept(run(0, 4, "unsure")), "x") == []
    msgs = less_coverage_problems(swept(run(0, 4, "unsure")), swept(run(0, 4, "pass")), "x")
    assert msgs and all("went from unsure to pass" in m for m in msgs)


def test_transforms():
    scene = copy.deepcopy(SCENE)
    scene["objects"].append({"type": "ac", "wall_id": "w1", "span_ft": [5, 6], "source": "tape"})
    more = with_more_error(scene, RULES)
    # A 24 ft chain: a tap default can drift to 0.3 + 0.16 * 24 = 4.14; tape does not drift.
    assert [o["plus_minus_ft"] for o in more["objects"]] == pytest.approx([4.64, 0.55])
    assert more["walls"][0]["plus_minus_ft"] == 0.5
    default_wall = copy.deepcopy(scene)
    del default_wall["walls"][0]["plus_minus_ft"]
    assert with_more_error(default_wall, RULES)["walls"][0]["plus_minus_ft"] == pytest.approx(4.64)
    assert more["meter"]["plus_minus_ft"] == 0.8
    assert [o["source"] for o in tape_to_tap(scene)["objects"]] == ["tap", "tap"]
    assert tape_to_tap(SCENE) is None
    less = with_less_coverage(scene)
    assert less["coverage"]["observed"][0]["span_ft"] == [-11.5, 9.5]
    assert less["coverage"]["observed"][1]["out_ft"] == 2.5
    short = with_ground_short_of(scene, RULES)  # largest ground radius 1: out to 2.73
    assert [e.get("out_ft") for e in short["coverage"]["observed"]] == [
        None,
        pytest.approx(22 / 12 + 1 - 0.1),
        1.0,
    ]
    assert with_ground_short_of(short, RULES) is None  # nothing left beyond the radius
    r = result()
    r["missing_evidence"] = [
        {"kind": "band", "band": "ground", "span_ft": [12, 11], "message": ""},
        {"kind": "past_end", "side": "left", "message": ""},
    ]
    captured = with_requests_captured(scene, r)
    assert captured["coverage"]["observed"][-1] == {
        "band": "ground",
        "span_ft": [11, 12],
        "out_ft": 40.0,
    }
    assert with_requests_captured(scene, result()) is None


def test_a_ground_request_is_redundant_only_as_far_out_as_it_asks():
    r = result()
    ask = {"kind": "band", "band": "ground", "span_ft": [-3.0, -1.0], "message": ""}
    r["missing_evidence"] = [ask | {"out_ft": 2.5}]  # SCENE saw this ground 3 ft out
    assert any("lists as observed" in m for m in invariant_problems(SCENE, r, rules=RULES))
    r["missing_evidence"] = [ask | {"out_ft": 3.5}]
    assert not any("lists as observed" in m for m in invariant_problems(SCENE, r, rules=RULES))


# --- Every band's reach, and the wall's source ---------------------------------------------------

PASS_RUN = {"wall_id": "w1", "start_ft": [1.0, 1.0], "outcome": "pass", "failing": [], "unsure": []}


def passing(check_id: str) -> dict:
    return {**check(), "id": check_id, "measured_ft": None, "plus_minus_ft": None}


def with_wall_seen(out_ft: float | None) -> dict:
    scene = copy.deepcopy(SCENE)
    wall = scene["coverage"]["observed"][0]
    wall.pop("out_ft", None)
    if out_ft is not None:
        wall["out_ft"] = out_ft
    return scene


def test_a_wall_seen_too_low_does_not_settle_an_opening():
    r = result(checks=[check(), passing("opening_clearance")])
    msgs = invariant_problems(with_wall_seen(1.0), r, rules=RULES)
    needs = "check opening_clearance passes but needs wall [0.00, 4.58] observed higher than 6.5 ft"
    assert any(needs in m for m in msgs)
    assert invariant_problems(with_wall_seen(7.0), r, rules=RULES) == []
    assert invariant_problems(with_wall_seen(None), r, rules=RULES) == []  # seen to headroom


def test_a_request_to_see_higher_than_the_view_reached_is_not_redundant():
    r = result()
    r["missing_evidence"] = [
        {"kind": "band", "band": "wall", "span_ft": [-3.0, -1.0], "out_ft": 6.6, "message": ""}
    ]
    low = invariant_problems(with_wall_seen(1.0), r, rules=RULES)
    assert not any("lists as observed" in m for m in low)
    full = invariant_problems(with_wall_seen(None), r, rules=RULES)
    assert any("lists as observed" in m for m in full)


BAND_RULES = replace(
    RULES,
    needs=RULES.needs
    | {
        "facing_gap": (Need("facing", 0.0, 22 / 12 + 3.0),),
        "headroom": (Need("overhead", 0.0, 6.5),),
        "battery_clearance": (Need("ground", 100.0),),
    },
)


def test_facing_and_headroom_passes_need_their_bands():
    r = result(checks=[check(), passing("facing_gap"), passing("headroom")])
    msgs = invariant_problems(SCENE, r, rules=BAND_RULES)
    assert any(
        "facing_gap passes but needs facing [1.00, 3.58] observed, none seen" in m for m in msgs
    )
    assert any(
        "headroom passes but needs overhead [1.00, 3.58] observed, none seen" in m for m in msgs
    )


def test_a_short_facing_view_needs_a_measurement():
    r = result(checks=[check(), passing("facing_gap")])
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"].append({"band": "facing", "span_ft": [0.0, 5.0], "out_ft": 3.0})
    msgs = invariant_problems(scene, r, rules=BAND_RULES)
    assert any("out to 4.83 ft or measured, seen 3.00 ft" in m for m in msgs)
    scene["facing"] = [{"wall_id": "w1", "span_ft": [0.0, 5.0], "depth_ft": 8.0}]
    assert invariant_problems(scene, r, rules=BAND_RULES) == []


def test_an_overhead_seen_clear_all_the_way_up_settles_headroom():
    r = result(checks=[check(), passing("headroom")])
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"].append({"band": "overhead", "span_ft": [0.0, 5.0]})
    assert invariant_problems(scene, r, rules=BAND_RULES) == []
    scene["coverage"]["observed"][-1]["out_ft"] = 5.0  # clear only to 5 ft, under 6.5
    assert any("overhead [1.00, 3.58]" in m for m in invariant_problems(scene, r, rules=BAND_RULES))


def test_a_check_the_server_did_not_evaluate_needs_nothing():
    evaluated = result(checks=[check()], sweep=[PASS_RUN])
    assert not any(
        "battery_clearance" in m for m in invariant_problems(SCENE, evaluated, rules=BAND_RULES)
    )
    with_battery = result(checks=[check(), passing("battery_clearance")], sweep=[PASS_RUN])
    assert any(
        "battery_clearance" in m for m in invariant_problems(SCENE, with_battery, rules=BAND_RULES)
    )


@pytest.mark.parametrize(
    ("wall", "error"),
    [
        ({}, 0.3),
        ({"source": "tap"}, 0.3),
        ({"source": "mesh"}, 0.5),
        ({"source": "plane"}, 0.75),
        ({"source": "mesh", "plus_minus_ft": 0.2}, 0.2),
    ],
)
def test_the_wall_source_sets_the_default_error(wall, error):
    scene = {"walls": [{"id": "w1", "baseline": [[0, 0], [9, 0]], **wall}]}
    drift = 0.0 if "plus_minus_ft" in wall else 0.16 * 1.0  # far edge 1 ft from the meter
    assert battery_error(scene, RULES, "w1", 0.0, 1.0) == pytest.approx(error + drift)


def test_a_request_to_walk_past_the_real_end_covers_what_lies_beyond_it():
    wide = replace(
        RULES,
        needs=RULES.needs | {"gas_clearance": (Need("ground", 1.0), Need("wall", 3.0, height=6.5))},
    )
    scene = copy.deepcopy(SCENE)
    scene["walls"][0]["baseline"] = [[-1.0, 0.0], [12.0, 0.0]]  # the chain's left end is s = -1
    scene["coverage"]["ends"]["left"] = {"kind": "unexplored"}
    scene["coverage"]["observed"][0]["span_ft"] = [-1.0, 10.0]
    r = result(checks=[check("unsure", None, cause="unobserved")])
    r["reasons"] = [{"code": "unobserved_area", "message": ""}]
    r["missing_evidence"] = [
        {
            "kind": "band",
            "band": "ground",
            "span_ft": [0, 5],
            "checks": ["gas_clearance"],
            "message": "",
        }
    ]
    # The spot [1, 3.58] needs the wall over [-2, 6.58]; [-2, -1] lies past the end.
    assert any("no wall request names it" in m for m in missing_evidence_problems(scene, r, wide))

    def past_end(at: float) -> dict:
        return {"kind": "past_end", "side": "left", "span_ft": [at, at], "message": ""}

    asked = r | {"missing_evidence": [*r["missing_evidence"], past_end(-1.0)]}
    assert missing_evidence_problems(scene, asked, wide) == []
    elsewhere = r | {"missing_evidence": [*r["missing_evidence"], past_end(1.0)]}
    assert missing_evidence_problems(scene, elsewhere, wide) != []  # not the chain's end
    scene["coverage"]["ends"]["left"] = {"kind": "limit"}
    assert missing_evidence_problems(scene, asked, wide) != []  # nothing to walk past


def test_chain_ends_are_measured_from_the_meter():
    scene = {
        "meter": {"pos": [2.0, 4.0, 0.3], "wall_id": "b"},
        "walls": [
            {"id": "a", "baseline": [[-5.0, 3.0], [-5.0, 0.0]]},
            {"id": "b", "baseline": [[-5.0, 0.0], [5.0, 0.0]]},
        ],
    }
    assert chain_ends_s(scene) == pytest.approx((-10.0, 3.0))


def test_a_view_that_only_reaches_the_needed_height_is_not_higher():
    r = result(checks=[check(), passing("opening_clearance")])
    msgs = invariant_problems(with_wall_seen(6.5), r, rules=RULES)
    assert any("observed higher than 6.5 ft" in m for m in msgs)
    assert invariant_problems(with_wall_seen(6.51), r, rules=RULES) == []


def test_a_facing_view_that_only_reaches_the_needed_depth_is_not_beyond():
    r = result(checks=[check(), passing("facing_gap")])
    scene = copy.deepcopy(SCENE)
    need = 22 / 12 + 3.0
    scene["coverage"]["observed"].append({"band": "facing", "span_ft": [0.0, 5.0], "out_ft": need})
    assert any("facing [1.00, 3.58]" in m for m in invariant_problems(scene, r, rules=BAND_RULES))
    scene["coverage"]["observed"][-1]["out_ft"] = need + 0.01
    assert invariant_problems(scene, r, rules=BAND_RULES) == []


def test_each_start_in_a_sweep_run_needs_only_its_own_reach():
    # A pool radius of 10 ft with the default wall error. Start 1's battery [1, 3.58] is 0.87 ft
    # uncertain, so it needs ground out to 1.83 + 10 + 0.87 = 12.71 ft; start 10's is 2.31 ft
    # uncertain. As one battery at start 10's error, the run would ask 14.15 ft in front of start 1.
    pool = replace(RULES, needs={"pool_clearance": (Need("ground", 10.0),)})
    scene = {
        "meter": {"pos": [0.0, 4.0, 0.0], "wall_id": "w1"},
        "walls": [{"id": "w1", "baseline": [[-40.0, 0.0], [40.0, 0.0]]}],
        "objects": [],
        "coverage": {
            "ends": {"left": {"kind": "limit"}, "right": {"kind": "limit"}},
            "observed": [
                {"band": "wall", "span_ft": [-40.0, 40.0]},
                {"band": "ground", "span_ft": [-40.0, 2.0], "out_ft": 13.5},
                {"band": "ground", "span_ft": [2.0, 40.0], "out_ft": 25.0},
            ],
        },
    }
    run = {"wall_id": "w1", "start_ft": [1.0, 10.0], "outcome": "pass", "failing": [], "unsure": []}
    r = result(spot=False, checks=[check() | {"id": "pool_clearance"}], sweep=[run])
    assert coverage_problems(scene, r, pool) == []
    scene["coverage"]["observed"][1]["out_ft"] = 12.5
    assert any(
        "at start 1.00 pool_clearance needs ground [1.00, 2.00] observed out to 12.71 ft" in m
        for m in coverage_problems(scene, r, pool)
    )


def test_sweep_run_starts_are_sampled_at_the_rules_step_plus_the_ends():
    assert run_starts([1.0, 1.5], 1 / 6) == pytest.approx([1.0, 7 / 6, 8 / 6, 1.5])
    assert run_starts([2.0, 2.0], 1 / 6) == [2.0]
    with pytest.raises(ValueError, match=r"sweep\.step_ft"):
        run_starts([1.0, 2.0], None)


def test_facing_and_headroom_need_the_band_past_the_battery_by_the_wall_error():
    # The spot [1, 3.58] on a wall with 0.3 ft of error needs facing seen over [0.7, 3.88].
    r = result(checks=[passing("facing_gap")])
    scene = copy.deepcopy(SCENE)
    scene["walls"][0]["plus_minus_ft"] = 0.3
    scene["coverage"]["observed"].append({"band": "facing", "span_ft": [1.0, 3.6]})
    assert any("facing [0.70, 1.00]" in m for m in invariant_problems(scene, r, rules=BAND_RULES))
    scene["coverage"]["observed"][-1]["span_ft"] = [0.7, 3.9]
    assert invariant_problems(scene, r, rules=BAND_RULES) == []


def test_facing_and_headroom_widen_by_the_default_error_with_drift():
    # The caretaker's repro: no explicit wall error, views over [5.7, 8.88] out 9 ft. At start 6
    # the battery [6, 8.58] is 0.3 + 0.16 x 8.58 = 1.67 ft uncertain, so both bands are needed
    # over [4.33, 10.25]; the error without drift (0.3) would ask only [5.7, 8.88].
    r = result(checks=[passing("facing_gap"), passing("headroom")], spot=False)
    r["sweep"][0]["start_ft"] = [6.0, 6.0]
    scene = copy.deepcopy(SCENE)
    del scene["walls"][0]["plus_minus_ft"]
    for band in ("facing", "overhead"):
        scene["coverage"]["observed"].append(
            {"band": band, "span_ft": [5.7, 6 + 31 / 12 + 0.3], "out_ft": 9.0}
        )
    problems = coverage_problems(scene, r, BAND_RULES)
    assert any("facing [4.33, 5.70] observed, none seen" in m for m in problems)
    assert any("overhead [4.33, 5.70] observed, none seen" in m for m in problems)
