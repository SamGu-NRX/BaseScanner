"""What missing_evidence asks a homeowner for: nothing but ground past the end of the wall
(issue #78), and no view whose size only a placeholder distance sets (issue #75). Synthetic scenes
shaped like the build 4.1 field runs; no real home data."""

import pytest
from helpers import (
    GOLDEN_RULES,
    D,
    check,
    golden_rules,
    observed_band,
    pads_ground,
    run,
    shared_fixture,
)

from rules import deep_merge, public_rules_dict, rules_from_dict
from solver import UNSURE

# Test settings, not Base policy.
END = 12.0  # the wall's right end, a limit ("Something blocks it")


def spot_beside_a_limit_end() -> dict:
    """The meter wall ends at a limit 12 ft right of the meter; the only lawn pad runs up to that
    end, and the wall and the ground were seen only up to 5 ft right of the meter."""
    raw = shared_fixture()
    raw["walls"][0]["baseline"] = [[-40, 0], [END, 0]]
    raw["overheads"][0]["span_ft"] = raw["facing"][0]["span_ft"] = [-40, END]
    raw["ground"] = pads_ground([(9, END)], hi=END + 20)
    raw["coverage"]["ends"]["right"] = {"kind": "limit"}
    observed_band(raw, "wall", [(-40, 5)])
    observed_band(raw, "ground", [(-40, 5)])
    return raw


def band_requests(result: dict, band: str) -> list[dict]:
    return [m for m in result["missing_evidence"] if m.get("band") == band]


def test_no_wall_request_runs_past_a_limit_end() -> None:
    # Before: the gas and opening clearances' 3 ft radius asked for the wall to 3 ft past the
    # end, where there is no wall, and the app dropped the whole request.
    result = run(spot_beside_a_limit_end())
    assert result["spot"]["span_ft"][1] > END - 1  # the spot stands beside the end
    walls = band_requests(result, "wall")
    assert walls, result["missing_evidence"]
    assert all(m["span_ft"][1] <= END + 1e-6 for m in walls), walls
    # The request is clipped at the end, not dropped.
    assert max(m["span_ft"][1] for m in walls) >= END - 1e-6
    assert not any("past the" in m["message"] for m in walls)


def test_no_facing_or_overhead_request_runs_past_a_limit_end() -> None:
    # The gap in front and the space overhead are asked for over the battery's stretch widened
    # by the wall's error, which beside the end reaches past it: the spot ends 0.4 ft short of
    # the end, and the wall is known to 1 ft.
    raw = spot_beside_a_limit_end()
    raw["walls"][0]["plus_minus_ft"] = 1.0
    raw["ground"] = pads_ground([(10, END + 5)], hi=END + 20)
    observed_band(raw, "facing", [(-40, 5)])
    observed_band(raw, "overhead", [(-40, 5)])
    result = run(raw)
    assert result["spot"]["span_ft"][1] > END - 1
    asked = [m for band in ("facing", "overhead") for m in band_requests(result, band)]
    assert {m["band"] for m in asked} == {"facing", "overhead"}, result["missing_evidence"]
    assert all(m["span_ft"][1] <= END + 1e-6 for m in asked), asked


def test_ground_past_a_limit_end_is_still_asked_for_and_says_why() -> None:
    result = run(spot_beside_a_limit_end())
    (ground,) = band_requests(result, "ground")
    assert ground["span_ft"][1] > END + 1  # an AC unit behind the fence still counts
    assert "Part of it is past the right end" in ground["message"]
    assert "to check for" in ground["message"] and "an AC unit" in ground["message"]
    # The pool's distance is a placeholder in these rules, so it doesn't ask (issue #75).
    assert "pool" not in ground["message"]


def test_a_request_inside_the_ends_has_no_past_end_hint() -> None:
    raw = shared_fixture()
    observed_band(raw, "ground", [(-40, 5), (15, 40)])
    ground = band_requests(run(raw, golden_rules()), "ground")
    assert ground and not any("past the" in m["message"] for m in ground)


# --- #75: placeholder distances don't size the requests ------------------------------------------


def ground_seen_out_to(out: float) -> dict:
    """The shared fixture with the ground in front of the whole wall seen only `out` ft out."""
    raw = shared_fixture()
    observed_band(raw, "ground", [(-40, 40)], out=out)
    return raw


def test_a_band_only_placeholder_checks_need_raises_no_request() -> None:
    # Ground seen 6 ft out covers the 3 ft gas and AC clearances in front of the 22 in deep
    # battery, but not the placeholder driveway (5 ft) and pool (10 ft) ones. Before: "Show the
    # ground ... at least 11 ft 10 in out from the wall", sized by the pool's placeholder alone.
    result = run(ground_seen_out_to(6))
    assert [m for m in result["missing_evidence"] if m["kind"] == "band"] == []
    for check_id in ("drive_clearance", "pool_clearance"):
        placeholder = check(result, check_id)
        assert (placeholder["outcome"], placeholder["unsure_cause"]) == (UNSURE, "unobserved")
        assert placeholder["rule"]["placeholder"] is True
    unsure = next(r for r in result["reasons"] if r["code"] == "unsure_checks")
    assert {"drive_clearance", "pool_clearance"} <= set(unsure["checks"])
    # Nothing is asked for, so the summary sends them to a person instead of asking for views.
    assert result["summary"].startswith("A person needs to check the best spot"), result["summary"]
    assert "distance from a pool" in result["summary"]


def test_a_real_rules_depth_is_kept() -> None:
    # Ground seen 4 ft out: the gas and AC clearances still ask for theirs, 3 ft past the
    # battery's front, and nothing deeper.
    result = run(ground_seen_out_to(4))
    (ground,) = band_requests(result, "ground")
    assert D + 3 - 1e-6 <= ground["out_ft"] <= D + 3 + 0.05, ground
    assert {"ac_clearance", "gas_clearance"} <= set(ground["checks"])
    assert not {"drive_clearance", "pool_clearance"} & set(ground["checks"]), ground


@pytest.mark.parametrize("private", [False, True], ids=["flag-cleared", "private-file"])
def test_a_real_pool_rule_brings_its_request_back(private: bool) -> None:
    # A pool value that is real: one whose rules clear the flag, or one a private file sets,
    # which is real although the public flag merges under it.
    pool: dict = {"value": 10.0, "source": "test"}
    if not private:
        pool["placeholder"] = False
    merged = deep_merge(
        deep_merge(public_rules_dict(), GOLDEN_RULES), {"clearances": {"pool_ft": pool}}
    )
    loaded = (
        rules_from_dict(merged, ("public", "private"), frozenset({"clearances.pool_ft"}))
        if private
        else rules_from_dict(merged)
    )
    assert loaded.rules.clearances.pool_ft.placeholder is private
    result = run(ground_seen_out_to(6), loaded)
    (ground,) = band_requests(result, "ground")
    assert ground["checks"] == ["pool_clearance"]
    assert ground["out_ft"] >= D + 10 - 1e-6
    assert result["summary"].startswith("More views are needed"), result["summary"]
