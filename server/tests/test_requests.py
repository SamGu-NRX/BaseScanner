"""What missing_evidence asks a homeowner for: nothing but ground past the end of the wall
(issue #78). Synthetic scenes shaped like the build 4.1 field runs; no real home data."""

from helpers import golden_rules, observed_band, pads_ground, run, shared_fixture

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


def test_a_request_inside_the_ends_has_no_past_end_hint() -> None:
    raw = shared_fixture()
    observed_band(raw, "ground", [(-40, 5), (15, 40)])
    ground = band_requests(run(raw, golden_rules()), "ground")
    assert ground and not any("past the" in m["message"] for m in ground)
