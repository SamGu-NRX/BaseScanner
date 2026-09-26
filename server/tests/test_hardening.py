"""Regression tests for the second review of #11 (public rules only); each failed before its fix."""

import io
import json
import time
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from helpers import W, at_start, rect, shared_fixture
from hypothesis import given, settings
from hypothesis import strategies as st

import api
from rules import deep_merge, load_rules, public_rules_dict, rules_from_dict
from scene import SceneError, parse_scene
from solver import SceneTooComplex, Solver, evaluate_start, solve

SERVER = Path(__file__).resolve().parents[1]
# Public values with automatic decisions on, so a wrong pass shows as "pass".
PUBLIC = rules_from_dict(
    deep_merge(public_rules_dict(), {"policy": {"id": "test", "auto_approve": True}})
)


def default_error_scene(ground_out: float = 30.0) -> dict:
    """A straight wall where every position takes the rules' default error (AR drift included)."""
    return {
        "meter": {"pos": [0.0, 5.0, 0.0], "wall_id": "w1"},
        "walls": [{"id": "w1", "baseline": [[-40, 0], [60, 0]]}],
        "objects": [],
        "ground": [{"type": "lawn", "polygon": rect(-60, 80, 0, 40)}],
        "overheads": [],
        "facing": [],
        "coverage": {
            "ends": {"left": {"kind": "limit"}, "right": {"kind": "limit"}},
            "observed": [
                {"band": "wall", "span_ft": [-60, 80]},
                {"band": "ground", "span_ft": [-60, 80], "out_ft": ground_out},
                {"band": "overhead", "span_ft": [-60, 80]},
                {"band": "facing", "span_ft": [-60, 80]},
            ],
        },
    }


# --- 1. unseen ground beyond the modelled outdoor area ------------------------------------------


def test_ground_seen_short_of_the_pool_radius_plus_error_is_not_clear() -> None:
    # Before: the outdoor area stopped at 12.83 ft, so ground 12.9 to 12.98 ft out counted as seen.
    raw = default_error_scene(ground_out=12.9)
    pool = at_start(raw, 2.71, "pool_clearance", PUBLIC)
    assert (pool.outcome, pool.unsure_cause) == ("unsure", "unobserved")


@settings(max_examples=25, deadline=None)
@given(
    out=st.floats(min_value=0.5, max_value=30.0),
    shrink=st.floats(min_value=0.0, max_value=0.9),
    s0=st.floats(min_value=-20.0, max_value=20.0),
)
def test_shrinking_observed_ground_never_helps(out: float, shrink: float, s0: float) -> None:
    full = evaluate_start(parse_scene(default_error_scene(out), PUBLIC.rules), PUBLIC, s0)
    less = evaluate_start(
        parse_scene(default_error_scene(out * (1 - shrink)), PUBLIC.rules), PUBLIC, s0
    )
    rank = {"pass": 0, "unsure": 1, "fail": 2}
    for before, after in zip(full.checks, less.checks, strict=True):
        assert rank[after.outcome] >= rank[before.outcome], (before.id, before, after)


# --- 2. start positions grow with boundaries times offsets --------------------------------------


def crowded_scene() -> dict:
    raw = shared_fixture()
    raw["objects"] = [
        {
            "type": "elec_box",
            "wall_id": "w1",
            "span_ft": [-39 + 0.7 * i, -38.9 + 0.7 * i],
            "bottom_ft": 4,
            "top_ft": 5,
            "source": "tap",
            "plus_minus_ft": 0.01 + 0.001 * i,
        }
        for i in range(100)
    ]
    raw["coverage"]["observed"] += [
        {"band": "wall", "span_ft": [-39.5 + 0.7 * i, -39.2 + 0.7 * i]} for i in range(100)
    ]
    return raw


def test_start_positions_grow_linearly() -> None:
    # Before: every boundary was combined with every object's error offset: 174k starts.
    scene = parse_scene(crowded_scene(), PUBLIC.rules)
    solver = Solver(scene, PUBLIC)
    assert sum(len(solver.starts(p)) for p in scene.walls) < 10_000


def test_crowded_scene_solves_quickly() -> None:
    started = time.perf_counter()
    solve(parse_scene(crowded_scene(), PUBLIC.rules), PUBLIC)
    assert time.perf_counter() - started < 10


def test_a_solve_over_budget_stops_with_a_clear_error() -> None:
    scene = parse_scene(shared_fixture(), PUBLIC.rules)
    with pytest.raises(SceneTooComplex, match="seconds"):
        solve(scene, PUBLIC, budget_s=0.0)


# --- 3. a small upload that parses to gigabytes -------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(api.app)


def test_zipped_scene_json_over_the_cap_is_refused_unread(client: TestClient) -> None:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("scene.json", '{"a": ' + " " * (11 * 1024 * 1024) + "1}")
    body = buffer.getvalue()
    assert len(body) < 100_000  # compresses to almost nothing
    resp = client.post("/v1/placements", content=body, headers={"content-type": "application/zip"})
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "scene_too_large"


def test_bare_scene_json_over_the_cap_is_refused(client, monkeypatch) -> None:
    monkeypatch.setattr(api, "MAX_SCENE_BYTES", 1024)
    body = json.dumps({"meter": {}, "pad": "x" * 2000})
    resp = client.post("/v1/placements", content=body, headers={"content-type": "application/json"})
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "scene_too_large"


# --- 4. the cable-reach cutoff --------------------------------------------------------------------


def test_starts_past_the_reach_cutoff_really_fail_route_length() -> None:
    # Before: the cutoff took drift at the near edge, so starts up to drift x W beyond it were
    # reported as route_length FAIL without evaluation; s0 = 24.62 ft actually gives UNSURE.
    raw = default_error_scene()
    scene = parse_scene(raw, PUBLIC.rules)
    limit = Solver(scene, PUBLIC).reach_limit(scene.walls[0])
    assert limit > 24.62
    for s0 in (limit + 1e-5, limit + 1, limit + 10, -limit - W - 1e-5, -limit - W - 5):
        reach = at_start(raw, s0, "route_length", PUBLIC)
        assert reach.outcome == "fail", (s0, reach.reason)
    # No run failing only route_length starts short of the cutoff (the old cutoff was 0.5 ft
    # short); runs within 1e-3 ft of it are evaluated starts that fail on their own.
    result = solve(scene, PUBLIC)
    for run in result["sweep"]:
        if run["failing"] == ["route_length"] and run["start_ft"][0] > 0:
            assert run["start_ft"][0] >= limit - 1e-3, run


def test_unexplored_end_within_drifted_reach_blocks_a_reject() -> None:
    # An end at 24.6 ft: a spot just past it has its far edge 24.6 + W out, where the drifted
    # error still leaves the route length unsure, so the end is not beyond reach.
    raw = default_error_scene()
    raw["walls"][0]["baseline"] = [[-40, 0], [24.6, 0]]
    raw["coverage"]["ends"]["right"] = {"kind": "unexplored"}
    result = solve(parse_scene(raw, PUBLIC.rules), PUBLIC)
    assert result["ends"]["right"]["beyond_reach"] is False


# --- 5. deep JSON -------------------------------------------------------------------------------


def test_deeply_nested_input_is_a_scene_error() -> None:
    raw = shared_fixture()
    deep: list = []
    for _ in range(5000):
        deep = [deep]
    raw["extra"] = deep
    with pytest.raises(SceneError):
        parse_scene(raw, PUBLIC.rules)


def test_deeply_nested_body_is_422(client: TestClient) -> None:
    body = '{"meter": ' + "[" * 5000 + "]" * 5000 + "}"
    resp = client.post("/v1/placements", content=body, headers={"content-type": "application/json"})
    assert resp.status_code == 422


# --- 6. private overrides and their citations ---------------------------------------------------


def test_private_value_without_its_own_source_is_refused(tmp_path: Path) -> None:
    private = tmp_path / "rules.yaml"
    private.write_text("clearances:\n  gas_ft: {value: 4.0}\n")
    with pytest.raises(ValueError, match=r"clearances\.gas_ft"):
        load_rules(private)


def test_private_sources_are_withheld_from_answers(tmp_path: Path) -> None:
    private = tmp_path / "rules.yaml"
    private.write_text(
        "policy: {id: p, version: '1', auto_approve: true, allow_reject: true}\n"
        "clearances:\n  gas_ft: {value: 4.0, source: 'SECRET CITATION'}\n"
    )
    loaded = load_rules(private)
    result = solve(parse_scene(shared_fixture(), loaded.rules), loaded)
    assert "SECRET CITATION" not in json.dumps(result)
    gas = next(c for c in result["checks"] if c["id"] == "gas_clearance")
    ac = next(c for c in result["checks"] if c["id"] == "ac_clearance")
    assert gas["rule"]["source"] == "Private rules"
    assert ac["rule"]["source"].startswith("Base help page")


# --- served schemas -----------------------------------------------------------------------------


@pytest.mark.parametrize("name", ["scene", "result"])
def test_schemas_are_served(client: TestClient, name: str) -> None:
    resp = client.get(f"/v1/schemas/{name}.json")
    assert resp.status_code == 200
    assert resp.json() == json.loads((SERVER / "schemas" / f"{name}.schema.json").read_text())


def test_battery_width_constant_matches_rules() -> None:
    assert pytest.approx(PUBLIC.rules.battery.width_ft.value) == W
