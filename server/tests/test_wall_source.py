"""A wall's `source` picks its default position error: tap (as when absent), mesh or plane."""

import pytest
from helpers import at_start, parsed, shared_fixture

from rules import public_rules_dict, rules_from_dict
from scene import SceneError

PUBLIC = rules_from_dict(public_rules_dict())
ERRORS = PUBLIC.rules.errors


def wall_from(source: str | None) -> dict:
    raw = shared_fixture()
    del raw["walls"][0]["plus_minus_ft"]  # take the default for the source
    if source is not None:
        raw["walls"][0]["source"] = source
    return raw


@pytest.mark.parametrize(
    ("source", "default"),
    [
        (None, ERRORS.wall_ft),
        ("tap", ERRORS.wall_ft),
        ("mesh", ERRORS.mesh_ft),
        ("plane", ERRORS.plane_ft),
    ],
)
def test_each_source_takes_its_default_error(source: str | None, default) -> None:
    meter_piece = parsed(wall_from(source), PUBLIC).meter_piece
    assert meter_piece.plus_minus == pytest.approx(default.value)


def test_a_mesh_wall_and_a_tapped_wall_get_different_error_bars() -> None:
    tapped = at_start(wall_from("tap"), 6.0, "meter_working_space", PUBLIC)
    meshed = at_start(wall_from("mesh"), 6.0, "meter_working_space", PUBLIC)
    # The same spot, measured against a wall known to 0.3 ft or to 0.5 ft (plus the same drift).
    assert meshed.plus_minus - tapped.plus_minus == pytest.approx(
        ERRORS.mesh_ft.value - ERRORS.wall_ft.value
    )


def test_an_explicit_error_overrides_the_source() -> None:
    raw = wall_from("plane")
    raw["walls"][0]["plus_minus_ft"] = 0.1
    assert parsed(raw, PUBLIC).meter_piece.plus_minus == pytest.approx(0.1)


def test_an_unknown_source_is_refused() -> None:
    with pytest.raises(SceneError) as caught:
        parsed(wall_from("lidar"), PUBLIC)
    assert caught.value.path == "/walls/0/source"
