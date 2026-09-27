"""Options for occlusion in the app's coverage map, on section 7's wall and truth (README section 7b).

Each option runs the app's CoverageMap (HouseScanKit at `coverage.KIT_COMMIT`, unedited) through
`coverage_driver/`, which models the rule change around it:
- position baseline b and angle diversity theta: no LiDAR; the driver's copy of `record` checks
  both, and at theta = 0, b = 0.25 m it must reproduce the app's own answer;
- depth test: the laser scan stands in for LiDAR depth. A keyframe's row is dropped from its
  sightings when either of the row's two samples is hidden (the truth's own test) or, for the
  5 m setting, beyond the LiDAR's reach.
"""

from __future__ import annotations

import json

from evals.coverage import (
    FEET,
    HIDE_ABS_M,
    PASS_FT,
    RESULTS,
    Setup,
    check_kit,
    photo_truth,
    row_points,
    run_app,
    setup_scene,
)

SCENE = "electro"
# Pre-registered: 0-45 degrees and 0.25-2 m. 60 and 75 degrees and 5 m were added after that grid
# left the false-observed length unchanged, to find where it first drops.
ANGLES_DEG = (0, 15, 30, 45, 60, 75)
BASELINES_M = (0.25, 0.5, 1.0, 2.0, 5.0)
APP_BASELINE_M = 0.25
LIDAR_REACH_M = 5.0  # Apple's stated range for the iPhone LiDAR scanner
# (label, rows per band, depth reach, how much nearer than the tapped plane still counts as wall)
DEPTH_OPTIONS = (
    ("depth test, true depth to 6 m, 3 rows", 3, None, HIDE_ABS_M),
    ("depth test, true depth to 6 m, 9 rows", 9, None, HIDE_ABS_M),
    ("depth test, no depth past 5 m, 9 rows", 9, LIDAR_REACH_M, HIDE_ABS_M),
)
# Added after the run above showed the pilasters (0.36 m proud) rejected: how much wall relief a
# depth test can allow before the footings pass. Chosen on this one wall, so not a setting to ship.
RELIEF_M = (0.2, 0.3, 0.4, 0.5)


def depth_hidden(
    setup: Setup, sightings: list[dict], rows: int, reach: float | None, relief: float
) -> list[dict]:
    """Rows of each keyframe's sightings that a depth test would reject."""
    cfg = {**setup.cfg, "rowsPerBand": rows}
    names = [v.name for v in setup.views]
    out = []
    for x in sightings:
        i = names.index(x["keyframe"])
        pts = row_points(setup.wall, x["band"], x["index"], cfg)[x["rows"]]
        t = photo_truth(
            setup.views[i],
            setup.R,
            setup.zbufs[i],
            setup.missing[i],
            pts,
            True,
            setup.cfg["maxDistance"] if reach is None else reach,
            relief,
        )
        bad = (t.hidden | ~t.in_range).any(axis=1)
        if bad.any():
            out.append({**x, "rows": [r for r, b in zip(x["rows"], bad, strict=True) if b]})
    return out


def _row(label: str, bands: dict, lidar: bool) -> dict:
    wall = bands["wall"]
    return {
        "option": label,
        "needs_lidar": lidar,
        "claimed_ft": wall["claimed_ft"],
        "false_observed_ft": wall["false_observed_ft"],
        "missed_ft": wall["missed_ft"],
        "ground_claimed_ft": bands["ground"]["claimed_ft"],
        "ground_false_observed_ft": bands["ground"]["false_observed_ft"],
        "passes": bool(wall["false_observed_ft"] <= PASS_FT),
    }


def evaluate() -> dict:
    setup = setup_scene(SCENE)
    if setup is None:
        raise SystemExit(f"{SCENE}: no wall within range")
    rows, grid = [], []
    for b in BASELINES_M:
        for theta in ANGLES_DEG:
            app = run_app(setup.wall, setup.cams, {"coveringBaseline": b, "minAngleDeg": theta})
            if theta == 0 and app["diverseCovered"] != app["covered"]:
                raise SystemExit(f"b = {b}: the driver's copy of record disagrees with the app")
            covered = app["covered"] if theta == 0 else app["diverseCovered"]
            bands = setup.score({**app, "covered": covered}, causes=False)
            label = f"b = {b:g} m, theta = {theta} deg"
            r = _row(label, bands, lidar=False)
            grid.append({"b_m": b, "theta_deg": theta, **r})
            if b == APP_BASELINE_M and theta == 0:
                rows.append({**r, "option": "the app today (b = 0.25 m, theta = 0)"})

    def depth_option(label: str, n_rows: int, reach: float | None, relief: float) -> dict:
        first = run_app(setup.wall, setup.cams, {"rowsPerBand": n_rows})
        hidden = depth_hidden(setup, first["sightings"], n_rows, reach, relief)
        app = run_app(setup.wall, setup.cams, {"rowsPerBand": n_rows}, hidden)
        return _row(label, setup.score(app, causes=False), lidar=True)

    for option in DEPTH_OPTIONS:
        rows.append(depth_option(*option))
    relief = [
        depth_option(f"depth test, true depth to 6 m, 9 rows, {r:g} m of relief", 9, None, r)
        for r in RELIEF_M
    ]
    return {
        "scene": SCENE,
        "wall_ft": (setup.wall.right - setup.wall.left) / FEET,
        "grid": grid,
        "options": rows,
        "relief": relief,
    }


def markdown(res: dict) -> str:
    lines = [
        "# Options for occlusion in the coverage map (generated by `make coverage-options`)",
        "",
        f"ETH3D {res['scene']}, the {res['wall_ft']:.1f} ft wall of section 7. Feet along the wall. "
        "False-observed: claimed wall with 10 cm or more of band no photo saw (pass <= "
        f"{PASS_FT} ft). Missed: wall band seen from two positions 0.25 m apart but not claimed.",
        "",
        "## Position baseline b and angle diversity theta (no LiDAR): false-observed / missed",
        "",
        "| b \\ theta | " + " | ".join(f"{t} deg" for t in ANGLES_DEG) + " |",
        "| --- |" + " --- |" * len(ANGLES_DEG),
    ]
    for b in BASELINES_M:
        cells = [
            f"{g['false_observed_ft']:.1f} / {g['missed_ft']:.1f}"
            for g in res["grid"]
            if g["b_m"] == b
        ]
        lines.append(f"| {b:g} m | " + " | ".join(cells) + " |")
    lines += [
        "",
        "## Options",
        "",
        "The last four rows allow that much wall relief in front of the tapped plane, a setting "
        "chosen after seeing this wall; see README section 7b.",
        "",
        "| Option | Needs LiDAR | Claimed | False-observed | Pass | Missed | Ground claimed |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for r in res["options"] + res["relief"]:
        lines.append(
            f"| {r['option']} | {'yes' if r['needs_lidar'] else 'no'} | {r['claimed_ft']:.1f} | "
            f"{r['false_observed_ft']:.1f} | {'yes' if r['passes'] else 'no'} | "
            f"{r['missed_ft']:.1f} | {r['ground_claimed_ft']:.1f} |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    check_kit()
    res = evaluate()
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "coverage_options.json").write_text(json.dumps(res, indent=1))
    md = markdown(res)
    (RESULTS / "coverage_options.md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
