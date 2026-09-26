import copy
import hashlib
import json

import pytest

from hsverify.resultcheck import (
    RuleSet,
    assumption_mismatches,
    comparable,
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
    radii={
        "ground_surface": ("ground", 0.0),
        "gas_clearance": ("ground", 1.0),
        "opening_clearance": ("wall", 1.0),
    },
    errors={"tap": 0.3, "vlm": 1.5, "tape": 0.05, "wall": 0.3, "meter": 0.3},
)

SCENE = {
    "meter": {"pos": [0.0, 4.0, 0.0], "wall_id": "w1"},
    "walls": [{"id": "w1", "baseline": [[-12.0, 0.0], [12.0, 0.0]]}],
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
    assert any("gas_clearance needs ground [0.00, 4.58], 2.83 ft out observed" in m for m in msgs)
    assert invariant_problems(with_ground(2.84, [-12.0, 10.0]), result(), rules=RULES) == []


def test_a_pass_needs_ground_along_the_wall_to_each_radius_without_slack():
    # Ground from 0.1: the 1 ft gas radius around [1, 3.58] reaches back to 0.
    msgs = invariant_problems(with_ground(3.0, [0.1, 10.0]), result(), rules=RULES)
    assert any("gas_clearance needs ground [0.00, 4.58]" in m for m in msgs)


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
    assert any("check opening_clearance passes but needs wall [0.00, 4.58]" in m for m in msgs)


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
    r["reasons"] = [{"code": "unobserved_area", "message": ""}]
    assert missing_evidence_problems(r) == [
        "check gas_clearance is unsure (unobserved) but no missing_evidence entry names it",
        "reason unobserved_area but missing_evidence is empty",
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
    assert missing_evidence_problems(r) == []


def test_rules_come_from_rules_yaml_and_a_missing_one_is_loud():
    text = """
battery: {width_ft: {value: 2.5}, depth_ft: {value: 1.5}}
errors: {tap_ft: {value: 0.3}, vlm_ft: {value: 1.5}, tape_ft: {value: 0.05},
         wall_ft: {value: 0.3}, meter_ft: {value: 0.3}}
clearances: {gas_ft: {value: 3}, ac_ft: {value: 3}, drive_ft: {value: 5},
             pool_ft: {value: 10}, opening_ft: {value: 3}}
"""
    rules = RuleSet.from_yaml(text)
    assert rules.radii["pool_clearance"] == ("ground", 10.0)
    assert rules.radii["opening_clearance"] == ("wall", 3.0)
    assert (rules.width_ft, rules.errors["tape"]) == (2.5, 0.05)
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
    assert [o["plus_minus_ft"] for o in more["objects"]] == [0.8, 0.55]
    assert more["walls"][0]["plus_minus_ft"] == 0.8 and more["meter"]["plus_minus_ft"] == 0.8
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
