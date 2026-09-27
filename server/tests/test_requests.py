"""What missing_evidence asks a homeowner for: nothing but ground past the end of the wall
(issue #78), and no view whose size only a placeholder distance sets (issue #75). Synthetic scenes
shaped like the build 4.1 field runs; no real home data."""

import copy

import pytest
from helpers import (
    GOLDEN_RULES,
    D,
    at_start,
    check,
    golden_rules,
    observed_band,
    pads_ground,
    run,
    shared_fixture,
)

from rules import deep_merge, public_rules_dict, rules_from_dict
from scene import SEAM_FT, SEEN_GROWTH_FT
from solver import _LOOKS_FOR, UNSURE, _either

# Test settings, not Base policy.
END = 12.0  # the wall's right end, a limit ("Something blocks it")
# Seen ground grows this far each side, so a ground request asks for this much less than the
# depth a check needs (scene.SEEN_GROWTH_FT and SEAM_FT).
GROWTH = SEEN_GROWTH_FT + SEAM_FT


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


def named(result: dict) -> set[str]:
    """The checks the band requests name: those capturing them settles."""
    return {i for m in result["missing_evidence"] if m["kind"] == "band" for i in m["checks"]}


def unseen(result: dict) -> set[str]:
    return {c["id"] for c in result["checks"] if c.get("unsure_cause") == "unobserved"}


def captured_exactly(raw: dict, result: dict) -> dict:
    """The next round of the gap loop: the homeowner shows exactly what the answer asked for."""
    out = copy.deepcopy(raw)
    out["coverage"]["observed"] += [
        {
            "band": m["band"],
            "span_ft": m["span_ft"],
            **({"out_ft": m["out_ft"]} if "out_ft" in m else {}),
        }
        for m in result["missing_evidence"]
        if m["kind"] == "band"
    ]
    return out


def facing_and_overhead_past_the_end() -> dict:
    """The gap in front and the space overhead are needed over the battery's stretch widened by
    the wall's error, which beside the end reaches past it: the spot ends 0.4 ft short of the
    end, and the wall is known to 1 ft."""
    raw = spot_beside_a_limit_end()
    raw["walls"][0]["plus_minus_ft"] = 1.0
    raw["ground"] = pads_ground([(10, END + 5)], hi=END + 20)
    observed_band(raw, "facing", [(-40, 5)])
    observed_band(raw, "overhead", [(-40, 5)])
    return raw


def test_no_wall_request_runs_past_a_limit_end() -> None:
    # Before: the gas and opening clearances' 3 ft radius asked for the wall to 3 ft past the
    # end, where there is no wall, and the app dropped the whole request.
    result = run(spot_beside_a_limit_end())
    assert result["spot"]["span_ft"][1] > END - 1  # the spot stands beside the end
    walls = band_requests(result, "wall")
    # The wall the other checks need beside the battery is still asked for.
    assert walls, result["missing_evidence"]
    assert all(m["span_ft"][1] <= END + 1e-6 for m in walls), walls
    assert not any("past the" in m["message"] for m in walls)


def test_a_check_that_needs_the_wall_past_a_limit_end_is_left_to_a_person() -> None:
    # The gas and opening clearances need the wall past the end, which still counts as unseen,
    # so no request can settle them. Before, a request clipped at the end still named them,
    # and capturing it left both unseen (the Codex review of c8d3c9d).
    result = run(spot_beside_a_limit_end())
    assert {"gas_clearance", "opening_clearance"} <= unseen(result)
    assert not {"gas_clearance", "opening_clearance"} & named(result), result["missing_evidence"]
    assert result["summary"].startswith("More views are needed"), result["summary"]
    assert "a person also needs to check" in result["summary"]
    assert "distance from gas equipment" in result["summary"]


def test_no_facing_or_overhead_request_runs_past_a_limit_end() -> None:
    result = run(facing_and_overhead_past_the_end())
    assert result["spot"]["span_ft"][1] > END - 1
    # Their stretch runs past the end, so they are left to a person, not asked for.
    assert {"facing_gap", "headroom"} <= unseen(result)
    assert not {"facing_gap", "headroom"} & named(result), result["missing_evidence"]
    assert band_requests(result, "facing") == band_requests(result, "overhead") == []
    asked = [m for m in result["missing_evidence"] if m["kind"] == "band" and m["band"] != "ground"]
    assert all(m["span_ft"][1] <= END + 1e-6 for m in asked), asked


def test_ground_past_a_limit_end_is_still_asked_for_and_says_why() -> None:
    result = run(spot_beside_a_limit_end())
    (ground,) = band_requests(result, "ground")
    assert ground["span_ft"][1] > END + 1  # an AC unit behind the fence still counts
    assert "Part of it is past the right end" in ground["message"]
    assert "to check for an AC unit" in ground["message"]
    # The gas clearance needs the wall past the end too, so it asks for nothing, and the pool's
    # distance is a placeholder in these rules (issue #75).
    assert "gas" not in ground["message"] and "pool" not in ground["message"]


def test_the_past_end_hint_joins_its_alternatives_with_one_or() -> None:
    # Before: "a gas meter or pipe or an AC unit".
    looks_for = [_LOOKS_FOR[i] for i in ("gas_clearance", "ac_clearance", "pool_clearance")]
    assert _either(looks_for) == "a gas meter, an AC unit or a pool"


def test_a_request_inside_the_ends_has_no_past_end_hint() -> None:
    raw = shared_fixture()
    observed_band(raw, "ground", [(-40, 5), (15, 40)])
    ground = band_requests(run(raw, golden_rules()), "ground")
    assert ground and not any("past the" in m["message"] for m in ground)


@pytest.mark.parametrize(
    "scene", [spot_beside_a_limit_end, facing_and_overhead_past_the_end], ids=["wall", "bands"]
)
def test_capturing_the_requests_settles_every_check_they_name(scene) -> None:
    # Round 2 of the gap loop beside a limit end. What the checks left to a person need lies
    # past the end, so before the summary read "More views are needed ... 2 checks depend on
    # areas the scan did not see" with nothing left to show.
    raw = scene()
    first = run(raw)
    assert named(first), first["missing_evidence"]
    second = run(captured_exactly(raw, first))
    assert not named(first) & unseen(second), second["checks"]
    assert second["missing_evidence"] == [], second["missing_evidence"]
    assert second["summary"].startswith("A person needs to check"), second["summary"]
    assert unseen(second)  # left for a person, not asked for


def test_a_small_ground_request_settles_its_checks() -> None:
    # Found by test_coderabbit_review's property once placeholder distances stopped sizing the
    # ground request (#75): the request was the depth at which the unseen area left fell to
    # 1e-9 sq ft, and that last speck, where the 3 ft arc meets the view's edge, lay inside the
    # radius, so the gas and AC clearances stayed unseen with nothing left to ask for.
    raw = shared_fixture()
    raw["objects"] = [
        {
            "type": "gas_meter",
            "wall_id": "w1",
            "span_ft": [0.0, 1.0],
            "bottom_ft": 0.5,
            "top_ft": 2.5,
            "source": "tape",
            "plus_minus_ft": 0.05,
            "footprint": [[0.0, 0], [1.0, 0], [1.0, 1], [0.0, 1]],
        }
    ]
    observed_band(raw, "ground", [(-40, 11.15625), (12, 40)], out=5)
    rules = golden_rules(clearances={"opening_ft": {"value": 1.0}})
    first = run(raw, rules)
    (ground,) = band_requests(first, "ground")
    assert {"ac_clearance", "gas_clearance"} <= set(ground["checks"]), ground
    raw["coverage"]["observed"].append(
        {"band": "ground", "span_ft": ground["span_ft"], "out_ft": ground["out_ft"]}
    )
    for check_id in ground["checks"]:
        after = at_start(raw, first["spot"]["span_ft"][0], check_id, rules)
        assert after.unsure_cause != "unobserved", (check_id, after.reason)


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
    # battery's front (less the seen ground's growth, as the request is the smallest depth
    # that covers the region), and nothing deeper.
    result = run(ground_seen_out_to(4))
    (ground,) = band_requests(result, "ground")
    assert D + 3 - GROWTH <= ground["out_ft"] <= D + 3 + 0.05, ground
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
    assert ground["out_ft"] >= D + 10 - GROWTH
    assert result["summary"].startswith("More views are needed"), result["summary"]
