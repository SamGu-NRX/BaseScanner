"""The text a homeowner reads names things by what they are and roughly where, never by the ids in
`subject`, and the summary leaves the demo-rules notice to `policy.notice` (issue #74). Every
scene here is synthetic."""

import json
import re
from pathlib import Path

import pytest
from helpers import at_start, pads_ground, rect, run, shared_fixture
from hypothesis import given, settings
from test_codex_review import two_walls
from test_field_run_2 import window_past_the_end
from test_main_review import door
from test_properties import FAST, build, cluttered
from test_s4_round import PUBLIC, answer

import solver
from rules import public_rules_dict, rules_from_dict
from scene import parse_scene
from solver import SOLVE_BUDGET_S, Solver, solve

SERVER = Path(__file__).resolve().parents[1]
IDS = ("objects[", "ground[", "facing[", "overheads[")
# An indefinite article that doesn't fit the next word: "a AC unit", "a electrical box".
WRONG_ARTICLE = re.compile(r"\ba (AC|[aeio])")


def homeowner_text(result: dict) -> list[str]:
    """Every string the app shows the homeowner from an answer."""
    return [
        result["summary"],
        *(r["message"] for r in result["reasons"]),
        *(c["reason"] for c in result["checks"]),
        *(m["message"] for m in result["missing_evidence"]),
        *(o["message"] for o in result["objects_not_used"]),
    ]


def assert_readable(texts: list[str]) -> None:
    for text in texts:
        assert not any(i in text for i in IDS), text
        assert "_" not in text, text  # no check id ("route_length") or type ("gas_meter") either
        assert not WRONG_ARTICLE.search(text), text


def assert_answer_readable(result: dict) -> None:
    assert_readable(homeowner_text(result))
    notice = result["policy"]["notice"]
    assert not notice or notice not in result["summary"], result["summary"]


# --- scenes that reach each kind of reason ------------------------------------------------------


def ac_too_close_to_call() -> dict:
    """Run 2's case: an AC unit 3.1 ft from the only spot, within the wall's 0.2 ft error."""
    raw = shared_fixture()
    raw["walls"][0]["plus_minus_ft"] = 0.2
    a = 6 + 31 / 12 + 3.1
    raw["objects"] = [
        {
            "type": "ac",
            "wall_id": "w1",
            "span_ft": [a, a + 2],
            "source": "tape",
            "plus_minus_ft": 0,
            "footprint": rect(a, a + 2, 0, 2),
        }
    ]
    return raw


def ground_seen_close_in() -> dict:
    """Run 3's case: the ground seen only 2 ft out, so an AC unit could hide nearby."""
    raw = shared_fixture()
    for o in raw["coverage"]["observed"]:
        if o["band"] == "ground":
            o["out_ft"] = 2.0
    return raw


def vent_of_unknown_height() -> dict:
    """A vent across the cable's route whose top was not recorded."""
    raw = shared_fixture()
    raw["objects"] = [
        {"type": "vent", "wall_id": "w1", "span_ft": [2, 3], "source": "tape", "plus_minus_ft": 0}
    ]
    return raw


def on_the_driveway() -> dict:
    """Driveway everywhere but a pad too narrow for the battery, which then stands on it."""
    raw = shared_fixture()
    raw["ground"] = [
        {**g, "type": "drive"} if g["type"] == "deck" else g for g in pads_ground([(6, 7)])
    ]
    return raw


SCENES = {
    "ac too close to call": ac_too_close_to_call,
    "ground seen close in": ground_seen_close_in,
    "vent of unknown height": vent_of_unknown_height,
    "on the driveway": on_the_driveway,
    "door across the route": lambda: door([1.0, 4.0]),
    "door that may reach the route": lambda: door([-3.4, -0.4]),
    "gap between walls": lambda: two_walls(0.0),
    "small gap between walls": lambda: two_walls(0.4),
    "window past a limit end": lambda: window_past_the_end("limit"),
    "window past an unexplored end": lambda: window_past_the_end("unexplored"),
}


@pytest.mark.parametrize("name", sorted(SCENES))
def test_no_answer_shows_an_id_or_a_wrong_article(name: str) -> None:
    raw = SCENES[name]()
    assert_answer_readable(answer(raw))
    # Every position the solver weighed, not only the one it reports.
    for c in Solver(parse_scene(raw, PUBLIC.rules), PUBLIC).candidates(SOLVE_BUDGET_S):
        assert_readable([chk.reason for chk in c.checks])


@pytest.mark.parametrize(
    "path",
    [*sorted((SERVER / "examples").glob("*.json")), SERVER / "tests/fixtures/example-scene.json"],
    ids=lambda p: p.name,
)
def test_the_examples_read_cleanly(path: Path) -> None:
    loaded = rules_from_dict(public_rules_dict())
    result = solve(parse_scene(json.loads(path.read_text()), loaded.rules), loaded)
    assert_answer_readable(result)


@settings(max_examples=40, deadline=None, database=None)
@given(c=cluttered())
def test_random_cluttered_scenes_read_cleanly(c: dict) -> None:
    raw = build(c)
    assert_answer_readable(run(raw, FAST))
    for cand in Solver(parse_scene(raw, FAST.rules), FAST).candidates(SOLVE_BUDGET_S):
        assert_readable([chk.reason for chk in cand.checks])


# --- the wording -------------------------------------------------------------------------------


def test_an_object_is_named_by_what_and_where() -> None:
    # Before: "objects[0] ac is 3 ft 1 in (± 0 ft 2 in) from the battery against a 3 ft 0 in
    # rule: too close to call."
    ac = at_start(ac_too_close_to_call(), 6.0, "ac_clearance", PUBLIC)
    assert ac.subject == "objects[0] ac"  # still the id, for code
    assert ac.reason == (
        "The AC unit about 13 ft right of the meter is 3 ft 1 in (± 0 ft 2 in) from the battery "
        "against a 3 ft 0 in rule: too close to call."
    )


def test_an_unseen_ac_unit_takes_an() -> None:
    # Before: "... so a AC unit could hide there."
    result = answer(ground_seen_close_in())
    ac = next(c for c in result["checks"] if c["id"] == "ac_clearance")
    assert ac["reason"].endswith("so an AC unit could hide there.")


def test_the_summary_leaves_the_notice_to_the_policy() -> None:
    result = answer(ground_seen_close_in())
    assert result["policy"]["notice"]
    assert result["policy"]["notice"] not in result["summary"]
    assert "not Base's" not in result["summary"]


@pytest.mark.parametrize(
    ("noun", "expected"),
    [
        ("AC unit", "an AC unit"),
        ("gas meter or pipe", "a gas meter or pipe"),
        ("electrical box", "an electrical box"),
        ("door or window", "a door or window"),
        ("battery", "a battery"),
    ],
)
def test_the_article_fits_the_noun(noun: str, expected: str) -> None:
    assert solver._a(noun) == expected


@pytest.mark.parametrize(
    ("s", "expected"),
    [
        (0.3, "next to the meter"),
        (13.6, "about 14 ft right of the meter"),
        (-2.5, "about 3 ft left of the meter"),
    ],
)
def test_where_a_thing_is_reads_in_whole_feet(s: float, expected: str) -> None:
    assert solver._about(s) == expected


@pytest.mark.parametrize(
    ("kind", "expected"),
    [("drive", "a driveway"), ("deck", "a deck"), ("lawn", "a lawn"), ("gravel", "gravel")],
)
def test_a_surface_takes_an_article_only_if_it_is_a_thing(kind: str, expected: str) -> None:
    # Before: "stands on a gravel" under rules that leave gravel out of ground.allowed.
    assert solver._surface(kind) == expected


def test_a_mark_set_aside_is_named_by_what_it_is() -> None:
    # Before: "The elec box marked 17 ft 0 in right of the meter ...".
    raw = window_past_the_end("unexplored")
    raw["objects"][0]["type"] = "elec_box"
    (aside,) = answer(raw)["objects_not_used"]
    assert aside["message"].startswith("The electrical box marked "), aside["message"]
