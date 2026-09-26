import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from helpers import golden_rules, parsed, shared_fixture

from siteplan import render, short
from solver import solve

SVG = "{http://www.w3.org/2000/svg}"
EXAMPLE = json.loads((Path(__file__).parent / "fixtures" / "example-scene.json").read_text())


def draw(raw):
    loaded = golden_rules()
    scene = parsed(raw, loaded)
    result = solve(scene, loaded)
    return result, render(scene, result, loaded)


@pytest.mark.parametrize("raw", [shared_fixture(), EXAMPLE], ids=["shared", "example"])
def test_site_plan_is_well_formed_svg_with_the_key_elements(raw) -> None:
    result, svg = draw(raw)
    root = ET.fromstring(svg)
    assert root.tag == f"{SVG}svg"
    assert root.find(f"{SVG}title") is not None
    assert result["summary"] in svg
    classes = {el.get("class") for el in root.iter()}
    assert {"wall", "meter", "cable"} <= classes
    assert "battery" in classes or "battery unsure" in classes
    assert not re.search(r"(?<![a-z])nan(?![a-z])", svg.lower())


def test_site_plan_is_deterministic() -> None:
    assert draw(shared_fixture())[1] == draw(shared_fixture())[1]


def test_reject_draws_the_nearest_spot_as_unsure() -> None:
    raw = shared_fixture()
    for g in raw["ground"]:
        g["type"] = "deck"
    result, svg = draw(raw)
    assert result["spot"] is None
    assert 'class="battery unsure"' in svg


@pytest.mark.parametrize(
    ("feet", "text"), [(3.0, "3 ft"), (7 / 12, "7 in"), (9 + 8 / 12, "9 ft 8 in")]
)
def test_short_lengths(feet, text) -> None:
    assert short(feet) == text
