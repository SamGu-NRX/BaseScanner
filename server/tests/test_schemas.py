import copy
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

SERVER = Path(__file__).resolve().parents[1]
SCENE_SCHEMA = json.loads((SERVER / "schemas" / "scene.schema.json").read_text())
RESULT_SCHEMA = json.loads((SERVER / "schemas" / "result.schema.json").read_text())
EXAMPLE = json.loads((SERVER / "tests" / "fixtures" / "example-scene.json").read_text())


@pytest.mark.parametrize("schema", [SCENE_SCHEMA, RESULT_SCHEMA], ids=["scene", "result"])
def test_schema_is_valid_draft_2020_12(schema) -> None:
    Draft202012Validator.check_schema(schema)


def test_example_scene_validates() -> None:
    Draft202012Validator(SCENE_SCHEMA).validate(EXAMPLE)


def test_docs01_minimal_scene_validates() -> None:
    # The docs/01 fields alone, without any optional addition, are a valid scene.
    minimal = {
        "meter": {"pos": [0, 5, 0], "wall_id": "w1"},
        "walls": [{"id": "w1", "baseline": [[-10, 0], [10, 0]], "height_ft": 9}],
        "objects": [
            {
                "type": "window",
                "wall_id": "w1",
                "span_ft": [2, 4],
                "bottom_ft": 3.1,
                "top_ft": 6.2,
                "attrs": {"operable": True, "well": False},
                "source": "vlm",
                "conf": 0.8,
            }
        ],
        "ground": [{"type": "lawn", "polygon": [[-10, 0], [10, 0], [10, 5]]}],
        "overheads": [{"wall_id": "w1", "span_ft": [1, 2], "clearance_ft": 3.0}],
        "facing": [{"wall_id": "w1", "span_ft": [1, 2], "depth_ft": 4.5}],
    }
    Draft202012Validator(SCENE_SCHEMA).validate(minimal)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda s: s["objects"][0].update(plusminus_ft=0.3), "Additional properties"),
        (lambda s: s["coverage"]["observed"][1].pop("out_ft"), "'out_ft' is a required property"),
        (lambda s: s["objects"][0].update(type="fence"), "is not one of"),
        (lambda s: s["walls"][0].update(baseline=[[0, 0]]), "is too short"),
    ],
)
def test_scene_schema_rejects_loudly(mutate, message: str) -> None:
    scene = copy.deepcopy(EXAMPLE)
    mutate(scene)
    errors = [e.message for e in Draft202012Validator(SCENE_SCHEMA).iter_errors(scene)]
    assert any(message in e for e in errors), errors
