"""Regression tests for CodeRabbit's review of #11; each failed before its fix."""

import copy
from pathlib import Path

import pytest
from helpers import at_start, golden_rules, observed_band, parsed, run, shared_fixture
from hypothesis import given, settings
from hypothesis import strategies as st

from rules import load_rules
from scene import SceneError
from solver import (
    SOLVE_BUDGET_S,
    UNSURE,
    Solver,
    evaluate_start,
    open_ends,
    settled_by_views,
)

# --- missing_evidence names every unseen band ------------------------------------------------


def both_bands_unseen() -> dict:
    """The lawn pad at s 6 to 9 is the only spot; wall and ground are unseen from 9.5 to 11,
    inside the gas clearance's reach but not behind or under the battery."""
    raw = shared_fixture()
    observed_band(raw, "wall", [(-40, 9.5), (11, 40)])
    observed_band(raw, "ground", [(-40, 9.5), (11, 40)])
    return raw


def test_a_check_reports_every_band_it_did_not_see() -> None:
    # Before: gas_clearance (ground and wall) reported only the ground, so a recapture of the
    # ground left it UNSURE on the wall.
    gas = at_start(both_bands_unseen(), 6.0, "gas_clearance")
    assert (gas.outcome, gas.unsure_cause) == (UNSURE, "unobserved")
    assert {view.band for view in gas.all_missing()} == {"ground", "wall"}


def test_missing_evidence_lists_the_check_under_each_band() -> None:
    result = run(both_bands_unseen())
    for band in ("ground", "wall"):
        item = next(m for m in result["missing_evidence"] if m.get("band") == band)
        assert "gas_clearance" in item["checks"], item


BANDS = ("wall", "ground", "overhead", "facing")


@st.composite
def partly_seen_scenes(draw: st.DrawFn) -> dict:
    """The shared wall with random gaps in each band's coverage and a gas meter somewhere."""
    raw = shared_fixture()
    gas_at = draw(st.floats(min_value=-12, max_value=20))
    raw["objects"] = [
        {
            "type": "gas_meter",
            "wall_id": "w1",
            "span_ft": [gas_at, gas_at + 1],
            "bottom_ft": 0.5,
            "top_ft": 2.5,
            "source": "tape",
            "plus_minus_ft": 0.05,
            "footprint": [[gas_at, 0], [gas_at + 1, 0], [gas_at + 1, 1], [gas_at, 1]],
        }
    ]
    for band in BANDS:
        # Pairs of cuts: each pair is a gap in the band's coverage.
        cuts = draw(st.lists(st.floats(min_value=-15, max_value=25), max_size=4))
        edges = [-40.0, *sorted(cuts[: len(cuts) // 2 * 2]), 40.0]
        spans = [(a, b) for a, b in zip(edges[::2], edges[1::2], strict=True) if b > a]
        out = draw(st.floats(min_value=1, max_value=30))
        observed_band(raw, band, spans or [(-40.0, -39.0)], out)
        if band in ("facing", "overhead") and draw(st.booleans()):
            for o in raw["coverage"]["observed"]:
                if o["band"] == band:
                    o["out_ft"] = draw(st.floats(1, 12))
    return raw


@settings(max_examples=60, deadline=None)
@given(raw=partly_seen_scenes())
def test_capturing_what_missing_evidence_asks_for_settles_coverage(raw: dict) -> None:
    # With equal gas and opening clearances, the opening check asks for the same stretch of wall
    # and hides a gas check that forgets it; rules may set them apart.
    rules = golden_rules(clearances={"opening_ft": {"value": 1.0}})
    result = run(raw, rules)
    # missing_evidence is the list of views that would settle a manual review; a pass or a
    # reject lists none.
    spot = result["spot"]
    if result["decision"] != "manual_review" or spot is None:
        return
    # The capture shows exactly what each request names, depth included.
    captured = copy.deepcopy(raw)
    for item in result["missing_evidence"]:
        if item["kind"] == "band":
            depth = {"out_ft": item["out_ft"]} if "out_ft" in item else {}
            captured["coverage"]["observed"].append(
                {"band": item["band"], "span_ft": item["span_ft"], **depth}
            )
    # The answer rounds the spot to 6 decimals; evaluate the exact start the solver chose, since
    # a start rounded down can reach a sliver of a stretch that was never missing.
    exact = min(
        (c.s0 for c in Solver(parsed(raw, rules), rules).candidates(SOLVE_BUDGET_S)),
        key=lambda s0: abs(s0 - spot["span_ft"][0]),
    )
    scene = parsed(captured, rules)
    after = evaluate_start(scene, rules, exact)
    # Checks views can't settle ask for nothing, and a person settles those: on a placeholder
    # distance (issue #75) or needing the wall past a limit end (issue #78).
    reachable = open_ends(Solver(scene, rules))
    unseen = [
        c.id
        for c in after.checks
        if c.outcome == UNSURE
        and c.unsure_cause == "unobserved"
        and settled_by_views(c, scene, reachable)
    ]
    assert unseen == [], (unseen, result["missing_evidence"])


# --- duplicate keys in rules files --------------------------------------------------------------


def test_a_duplicate_key_in_the_private_rules_is_refused(tmp_path: Path) -> None:
    private = tmp_path / "rules.yaml"
    private.write_text(
        "clearances:\n  gas_ft: {value: 4.0, source: 'first'}\n"
        "clearances:\n  ac_ft: {value: 4.0, source: 'second'}\n"
    )
    with pytest.raises(ValueError, match=r"duplicate key 'clearances'"):
        load_rules(private)


def test_a_duplicate_nested_key_is_refused(tmp_path: Path) -> None:
    private = tmp_path / "rules.yaml"
    private.write_text(
        "clearances:\n  gas_ft: {value: 4.0, source: 'a'}\n  gas_ft: {value: 5.0, source: 'b'}\n"
    )
    with pytest.raises(ValueError, match=r"duplicate key 'gas_ft'"):
        load_rules(private)


# --- attrs rejects unknown keys -------------------------------------------------------------------


def test_a_misspelled_attribute_is_refused() -> None:
    # Before: {"operabel": false} passed and read as unknown, so a typo sent the spot to review.
    raw = shared_fixture()
    raw["objects"] = [
        {
            "type": "window",
            "wall_id": "w1",
            "span_ft": [-14, -11],
            "bottom_ft": 3,
            "top_ft": 7,
            "attrs": {"operabel": False},
            "source": "tap",
        }
    ]
    with pytest.raises(SceneError) as caught:
        parsed(raw)
    assert caught.value.path == "/objects/0/attrs"
