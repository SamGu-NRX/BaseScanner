"""Builders for synthetic test scenes and rules. Everything here is synthetic; no real home data.

`shared_fixture()` is the public golden tests' shared fixture (docs/research/t3-lane-c-review.md on
t3/research): wall w1 is straight with s = x, the meter at 0 and outward +z; the only usable pad is
level ground at s = [6, 9]; both ends observed; facing gap and headroom 9; exact geometry.
"""

import copy
from typing import Any

from rules import LoadedRules, deep_merge, public_rules_dict, rules_from_dict
from scene import Scene, parse_scene
from solver import solve

# Test settings, not Base policy.
GOLDEN_RULES: dict[str, Any] = {
    "policy": {"id": "golden-test", "version": "1", "auto_approve": True, "allow_reject": True},
    "errors": {
        k: {"value": 0.0, "source": "exact test geometry"}
        for k in ("tap_ft", "vlm_ft", "mesh_ft", "tape_ft", "wall_ft", "meter_ft")
    },
    "facing": {"min_ft": {"value": 5.0, "source": "test"}, "measured_from": "wall"},
    "route": {
        "confident_reach_ft": {"value": 15.0, "source": "test"},
        "max_ft": {"value": 20.0, "source": "test"},
        "corner_allowance_ft": {"value": 0.0, "source": "test"},
    },
}


def golden_rules(**overrides: Any) -> LoadedRules:
    return rules_from_dict(deep_merge(deep_merge(public_rules_dict(), GOLDEN_RULES), overrides))


def rect(x0: float, x1: float, z0: float, z1: float) -> list[list[float]]:
    return [[x0, z0], [x1, z0], [x1, z1], [x0, z1]]


def everything_observed(lo: float = -60, hi: float = 60, out: float = 30) -> dict[str, Any]:
    return {
        "ends": {"left": {"kind": "limit"}, "right": {"kind": "limit"}},
        "observed": [
            {"band": "wall", "span_ft": [lo, hi]},
            {"band": "ground", "span_ft": [lo, hi], "out_ft": out},
            {"band": "overhead", "span_ft": [lo, hi]},
            {"band": "facing", "span_ft": [lo, hi]},
        ],
    }


def pads_ground(
    pads: list[tuple[float, float]], lo: float = -40, hi: float = 40, depth: float = 30
) -> list[dict[str, Any]]:
    """Lawn over each pad [x0, x1] on a straight wall along z = 0 (outward +z); deck elsewhere."""
    ground = []
    edges = [lo]
    for x0, x1 in sorted(pads):
        ground.append({"type": "lawn", "polygon": rect(x0, x1, 0, depth), "plus_minus_ft": 0})
        edges += [x0, x1]
    edges.append(hi)
    for a, b in zip(edges[::2], edges[1::2], strict=True):
        if b > a:
            ground.append({"type": "deck", "polygon": rect(a, b, 0, depth), "plus_minus_ft": 0})
    return ground


def shared_fixture() -> dict[str, Any]:
    return {
        "meter": {"pos": [0.0, 5.0, 0.0], "wall_id": "w1", "plus_minus_ft": 0},
        "walls": [
            {"id": "w1", "baseline": [[-40, 0], [40, 0]], "height_ft": 9, "plus_minus_ft": 0}
        ],
        "objects": [],
        "ground": pads_ground([(6, 9)]),
        "overheads": [
            {"wall_id": "w1", "span_ft": [-40, 40], "clearance_ft": 9, "plus_minus_ft": 0}
        ],
        "facing": [{"wall_id": "w1", "span_ft": [-40, 40], "depth_ft": 9, "plus_minus_ft": 0}],
        "coverage": everything_observed(-40, 40),
    }


def run(raw: dict[str, Any], rules: LoadedRules | None = None) -> dict[str, Any]:
    loaded = rules or golden_rules()
    return solve(parse_scene(copy.deepcopy(raw), loaded.rules), loaded)


def parsed(raw: dict[str, Any], rules: LoadedRules | None = None) -> Scene:
    loaded = rules or golden_rules()
    return parse_scene(copy.deepcopy(raw), loaded.rules)


def check(result: dict[str, Any], check_id: str) -> dict[str, Any]:
    return next(c for c in result["checks"] if c["id"] == check_id)
