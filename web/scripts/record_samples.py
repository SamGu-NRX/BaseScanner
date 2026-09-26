"""Record the bundled sample scenes and the placement server's answers to them.

The web page ships three synthetic scenes, one per decision, with the answer and site plan the
server gave, so it can show a saved answer when no server is reachable. Rerun after the solver or
the result schema changes:

    cd server && PYTHONPATH=. uv run python ../web/scripts/record_samples.py

The answers use the public rules alone, as the hosted server does, so a saved answer says what the
live server says. Those rules are not approved for automatic decisions, so every sample is
recorded as manual review; the reasons and checks still differ.
"""

import json
from pathlib import Path

from rules import public_rules_dict, rules_from_dict
from scene import parse_scene
from siteplan import render
from solver import solve

OUT = Path(__file__).resolve().parents[1] / "src" / "samples"
RULES = rules_from_dict(public_rules_dict())


def rect(x0, x1, z0, z1):
    return [[x0, z0], [x1, z0], [x1, z1], [x0, z1]]


def side_wall(right_end="limit", wall_end=24.0, seen_to=30.0):
    """A 44 ft side wall with the meter at x = 0, a gas meter to its left and mulch in front."""
    return {
        "schema_version": "1.0",
        "meter": {"pos": [0.0, 5.0, 0.0], "wall_id": "side", "plus_minus_ft": 0.1},
        "walls": [
            {"id": "side", "baseline": [[-20.0, 0.0], [wall_end, 0.0]], "plus_minus_ft": 0.1}
        ],
        "objects": [
            {
                "type": "gas_meter", "wall_id": "side", "span_ft": [-6.0, -5.0],
                "bottom_ft": 0.5, "top_ft": 2.5, "source": "tap", "plus_minus_ft": 0.1,
                "footprint": rect(-6.0, -5.0, 0.0, 1.0),
            },
            {
                "type": "window", "wall_id": "side", "span_ft": [-14.0, -11.0],
                "bottom_ft": 3.0, "top_ft": 7.0, "attrs": {"operable": True}, "source": "tap",
                "plus_minus_ft": 0.1,
            },
        ],
        "ground": [
            {"type": "mulch", "polygon": rect(-40.0, 40.0, 0.0, 4.0), "plus_minus_ft": 0.1},
            {"type": "lawn", "polygon": rect(-40.0, 40.0, 4.0, 20.0), "plus_minus_ft": 0.1},
        ],
        "overheads": [],
        "facing": [
            {"wall_id": "side", "span_ft": [-20.0, wall_end], "depth_ft": 16.0,
             "plus_minus_ft": 0.2}
        ],
        "coverage": {
            "ends": {"left": {"kind": "limit"}, "right": {"kind": right_end}},
            "observed": [
                {"band": "wall", "span_ft": [-20.0, seen_to]},
                {"band": "ground", "span_ft": [-20.0, seen_to], "out_ft": 20.0},
                {"band": "overhead", "span_ft": [-20.0, seen_to]},
                {"band": "facing", "span_ft": [-20.0, seen_to]},
            ],
        },
    }


def fits():
    return side_wall()


def corner_not_walked():
    """The walk stopped at a corner 9 ft right of the meter, and the only room is next to it."""
    scene = side_wall(right_end="unexplored", wall_end=9.0, seen_to=9.0)
    scene["walls"][0]["baseline"][0] = [-3.0, 0.0]
    scene["objects"] = []
    scene["facing"][0]["span_ft"] = [-3.0, 9.0]
    return scene


def garage_in_the_way():
    scene = side_wall()
    scene["objects"] += [
        {"type": "garage_door", "wall_id": "side", "span_ft": [1.5, 24.0], "bottom_ft": 0.0,
         "top_ft": 7.0, "source": "tap", "plus_minus_ft": 0.1},
        {"type": "gas_meter", "wall_id": "side", "span_ft": [-18.0, -17.0], "bottom_ft": 0.5,
         "top_ft": 2.5, "source": "tap", "plus_minus_ft": 0.1,
         "footprint": rect(-18.0, -17.0, 0.0, 1.0)},
    ]
    return scene


SAMPLES = {
    "fits": fits,
    "corner-not-walked": corner_not_walked,
    "garage-in-the-way": garage_in_the_way,
}


def main() -> None:
    for name, build in SAMPLES.items():
        raw = build()
        scene = parse_scene(json.loads(json.dumps(raw)), RULES.rules)
        result = solve(scene, RULES)
        result["stats"]["elapsed_ms"] = 0  # keeps the recorded files stable between runs
        folder = OUT / name
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "scene.json").write_text(json.dumps(raw, indent=2) + "\n")
        (folder / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        (folder / "plan.svg").write_text(render(scene, result, RULES))
        print(f"{name}: {result['decision']} - {result['summary']}")


if __name__ == "__main__":
    main()
