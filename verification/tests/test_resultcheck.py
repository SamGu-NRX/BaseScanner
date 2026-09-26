import copy
import hashlib
import json

import pytest

from hsverify.resultcheck import (
    assumption_mismatches,
    comparable,
    expectation_problems,
    invariant_problems,
    margin_problem,
    mirror_scene,
    observed,
    outcome_lengths,
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
            {"band": "ground", "span_ft": [-12.0, 4.0], "out_ft": 3.0},
            {"band": "ground", "span_ft": [4.0, 10.0], "out_ft": 1.0},
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
    assert invariant_problems(SCENE, result(), sent=b"{}") == []


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
    assert observed(SCENE, "ground", min_out_ft=22 / 12) == [(-12.0, 4.0)]
    assert observed({"meter": {}}, "wall") == []


def test_pass_over_unobserved_ground_is_flagged():
    # Starts [3, 3] put the battery over s = [3, 5.58]; ground past s = 4 was seen only 1 ft out.
    sweep = [
        {"wall_id": "w1", "start_ft": [3.0, 3.0], "outcome": "pass", "failing": [], "unsure": []}
    ]
    msgs = invariant_problems(SCENE, result(sweep=sweep))
    assert any("ground under" in m for m in msgs)


def test_pass_whose_route_crosses_unobserved_wall_is_flagged():
    scene = copy.deepcopy(SCENE)
    scene["coverage"]["observed"][0]["span_ft"] = [0.5, 10.0]  # the wall at s = [0, 0.5] unseen
    msgs = invariant_problems(scene, result())
    assert any("wall and cable route" in m for m in msgs)


def test_no_coverage_never_passes():
    scene = {k: v for k, v in SCENE.items() if k != "coverage"}
    msgs = invariant_problems(scene, result("pass"))
    assert any("no coverage at all" in m for m in msgs)


def test_photo_request_for_an_observed_area_is_flagged():
    r = result()
    r["missing_evidence"] = [
        {"kind": "band", "band": "wall", "span_ft": [-3.0, -1.0], "message": ""}
    ]
    assert any("lists as observed" in m for m in invariant_problems(SCENE, r))


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
