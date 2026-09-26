"""Write the black-box placement cases in this folder, one JSON file per case.

Run from verification/: `uv run python e2e/cases/generate.py`. README.md gives the arithmetic
behind every expected number. The scenes follow server/schemas/scene.schema.json at
origin/t3/server; they were written from that schema and the lane C review, not from the
server's code or fixtures.
"""

import json
import math
from pathlib import Path

HERE = Path(__file__).parent
RESEARCH_SHA = "a7d91f1"
SERVER_SHA = "69c6c3c"

# Battery footprint from the lane C review's parameter table: 31 in wide, 22 in deep.
W = 31 / 12
D = 11 / 6
METER_Y = 4.0
# Walls placed at z = -D put a flush battery's front edge at z = 0 exactly in floating point,
# so a gas strip at z = d is measured as exactly d. The margin cases need that: 3.3 - 0.3 and
# 2.7 + 0.3 both evaluate to exactly 3.0, while 11/6 + 3.3 - 11/6 does not return 3.3.
FRONT0 = -D


def golden(n):
    return f"t3-lane-c-review.md golden {n} at origin/t3/research {RESEARCH_SHA}"


def straight(wall_id, x0, x1, z=0.0, pm=0.0):
    return {"id": wall_id, "baseline": [[x0, z], [x1, z]], "plus_minus_ft": pm}


def rect(x0, x1, z0, z1):
    return [[x0, z0], [x1, z0], [x1, z1], [x0, z1]]


def concrete(polygon):
    return {"type": "concrete", "polygon": polygon, "plus_minus_ft": 0.0}


def facing(wall_id, span, depth=9.0):
    return {"wall_id": wall_id, "span_ft": list(span), "depth_ft": depth, "plus_minus_ft": 0.0}


def coverage(span, ground=None, left="limit", right="limit", bands=("wall", "overhead", "facing")):
    """Observed bands over `span`; the ground band over `ground` (default: `span`), 10 ft out."""
    observed = [{"band": b, "span_ft": list(span)} for b in bands]
    for g in [span] if ground is None else ground:
        observed.append({"band": "ground", "span_ft": list(g), "out_ft": 10.0})
    return {"ends": {"left": {"kind": left}, "right": {"kind": right}}, "observed": observed}


def gas(wall_id, span, footprint, pm=0.0, conf=None):
    obj = {
        "type": "gas_meter",
        "wall_id": wall_id,
        "span_ft": list(span),
        "source": "tape",
        "plus_minus_ft": pm,
        "footprint": footprint,
    }
    if conf is not None:
        obj["conf"] = conf
    return obj


def opening(kind, wall_id, span, bottom, top):
    return {
        "type": kind,
        "wall_id": wall_id,
        "span_ft": list(span),
        "bottom_ft": bottom,
        "top_ft": top,
        "attrs": {"operable": True},
        "source": "tape",
        "plus_minus_ft": 0.0,
    }


def meter(x, z, wall_id="w1"):
    return {"pos": [x, METER_Y, z], "wall_id": wall_id, "plus_minus_ft": 0.0}


def polyline_wall(wall_id, s_start, segments):
    """A wall of straight segments given as (length, heading in degrees), heading 0 = +x.

    The first point sits at s = s_start. The baseline is shifted so the point at s = 0 (the
    meter) is the origin. Headings fall left to right, so every corner is an outside corner.
    """
    pts = [(0.0, 0.0)]
    s_marks = [s_start]
    for length, heading in segments:
        a = math.radians(heading)
        x, z = pts[-1]
        pts.append((x + length * math.cos(a), z + length * math.sin(a)))
        s_marks.append(s_marks[-1] + length)
    # Find the point at s = 0 and shift it to the origin.
    for i in range(len(segments)):
        if s_marks[i] <= 0 <= s_marks[i + 1]:
            t = (0 - s_marks[i]) / (s_marks[i + 1] - s_marks[i])
            ox = pts[i][0] + t * (pts[i + 1][0] - pts[i][0])
            oz = pts[i][1] + t * (pts[i + 1][1] - pts[i][1])
            break
    shifted = [[x - ox, z - oz] for x, z in pts]
    return {"id": wall_id, "baseline": shifted, "plus_minus_ft": 0.0}


def offset_ground(baseline, out=12.0):
    """Ground polygon in front of a convex wall: the baseline, then the baseline pushed out."""
    front = []
    n = len(baseline)
    for i, (x, z) in enumerate(baseline):
        normals = []
        for j in (i - 1, i):
            if 0 <= j < n - 1:
                dx = baseline[j + 1][0] - baseline[j][0]
                dz = baseline[j + 1][1] - baseline[j][1]
                length = math.hypot(dx, dz)
                normals.append((-dz / length, dx / length))
        nx = sum(v[0] for v in normals) / len(normals)
        nz = sum(v[1] for v in normals) / len(normals)
        norm = math.hypot(nx, nz)
        front.append([x + out * nx / norm, z + out * nz / norm])
    return concrete([list(p) for p in baseline] + front[::-1])


CASES = []


def case(cid, source, description, scene, expect, rules_assumed=None):
    CASES.append(
        {
            "id": cid,
            "source": source,
            "description": description,
            "scene": scene,
            "rules_assumed": rules_assumed or {},
            "expect": expect,
        }
    )


def straight_scene(x0, x1, z=0.0, meter_x=0.0, objects=(), ground=None, cov=None, wall_pm=0.0):
    scene = {
        "schema_version": "1.0",
        "meter": meter(meter_x, z),
        "walls": [straight("w1", x0, x1, z, wall_pm)],
        "objects": list(objects),
        "ground": [concrete(rect(x0, x1, z, z + 10))] if ground is None else ground,
        "facing": [facing("w1", (x0 - meter_x, x1 - meter_x))],
    }
    scene["coverage"] = coverage((x0 - meter_x, x1 - meter_x)) if cov is None else cov
    return scene


# g01: an unseen stretch behind a garage door needs no photo, since no cable can reach it.
case(
    "g01-unseen-beyond-garage",
    golden("01"),
    "The wall beyond a garage door left of the meter was never observed. No spot there can be "
    "reached by a cable, so the result asks for no photos, and every start beyond the garage "
    "fails its route.",
    straight_scene(
        -14,
        10,
        objects=[opening("garage_door", "w1", (-7, -3), 0.0, 7.0)],
        cov=coverage((-7, 10)),
    ),
    {
        "missing_evidence_empty": True,
        "sweep_runs": [
            {
                "wall_id": "w1",
                "start_ft": [-13.9, -9.7],
                "outcome": "fail",
                "failing_match": "route",
            }
        ],
    },
)

# g03: pads at s = [-9, -6] and [7, 10]; the stretch between is short segments.
seg = 13 / 7
g03_wall = polyline_wall("w1", -9, [(3, 32)] + [(seg, 24 - 8 * k) for k in range(7)] + [(3, -32)])
case(
    "g03-negative-s-near-edge",
    golden("03"),
    "Two straight 3 ft pads, s = [-9, -6] and [7, 10], joined by segments 13/7 ft long that no "
    "battery fits on. The left pad's route runs to its near edge (6 ft), so it beats the right "
    "pad (7 ft); measuring to the far edge (103/12 ft) would pick the right pad.",
    {
        "schema_version": "1.0",
        "meter": meter(0.0, 0.0),
        "walls": [g03_wall],
        "objects": [],
        "ground": [offset_ground(g03_wall["baseline"])],
        "facing": [facing("w1", (-9, 10))],
        "coverage": coverage((-9, 10)),
    },
    {
        "spot": {"wall_id": "w1", "span_within": [-9, -6]},
        "sweep_runs": [{"wall_id": "w1", "start_ft": [-8.4, 6.9], "outcome": "fail"}],
        "missing_evidence_empty": True,
    },
)

# g05: inside corner, gas meter on the return wall at [4, 4].
g05 = {
    "schema_version": "1.0",
    "meter": meter(-6.0, 0.0),
    "walls": [
        straight("w1", -7, 4),
        {"id": "w2", "baseline": [[4, 0], [4, 12]], "plus_minus_ft": 0.0},
    ],
    "objects": [gas("w2", (14, 14), [[4, 4]])],
    "ground": [concrete(rect(-7, 4, 0, 12))],
    "facing": [facing("w1", (-1, 10)), facing("w2", (10, 22))],
    "coverage": coverage((-1, 22)),
}
case(
    "g05-inside-corner-gas",
    golden("05"),
    "A gas meter on the return wall of an inside corner is 65/12 ft away along the unrolled "
    "wall but about 2.589 ft away in plan from a battery at s = [6, 6 + 31/12]. Gas clearance "
    "is measured in plan, so those starts fail.",
    g05,
    {
        "decision_not": ["pass"],
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [6, 7.4], "outcome": "fail", "failing_match": "gas"}
        ],
    },
    {"gas": 3.0},
)

# g06: gas meter body 10 ft out, regulator reaching [7, 23/6].
spike = [[6.5, 10.5], [6.5, 9.5], [6.9, 9.5], [7.0, 23 / 6], [7.1, 9.5], [7.5, 9.5], [7.5, 10.5]]
case(
    "g06-regulator-footprint",
    golden("06"),
    "The gas meter body stands 10 ft from the wall but its regulator reaches [7, 23/6], 2 ft "
    "from the front edge of any battery covering x = 7. Clearance is measured to every part of "
    "the footprint.",
    straight_scene(-3, 16, objects=[gas("w1", (6.5, 7.5), spike)])
    | {"facing": [facing("w1", (-3, 16), depth=12.0)]},
    {
        "decision_not": ["pass"],
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [3, 9], "outcome": "fail", "failing_match": "gas"}
        ],
    },
    {"gas": 3.0},
)

# g08a: garage door right of the meter, nothing usable before it.
case(
    "g08a-garage-blocks-route",
    golden("08"),
    "A garage door spans s = [1, 5] and the wall ends at s = -0.5, so every start either "
    "overlaps the door or lies beyond it, where the cable would have to cross the door.",
    straight_scene(-0.5, 12, objects=[opening("garage_door", "w1", (1, 5), 0.0, 7.0)]),
    {
        "decision_not": ["pass"],
        "spot": None,
        "missing_evidence_empty": True,
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [5, 9.4], "outcome": "fail", "failing_match": "route"}
        ],
    },
    {"opening": 3.0},
)

# g08b: a 1 ft stretch with no wall between the meter's short wall and the rest.
g08b = {
    "schema_version": "1.0",
    "meter": meter(0.0, 0.0),
    "walls": [straight("w1", -0.5, 1), straight("w2", 2, 12)],
    "objects": [],
    "ground": [concrete(rect(-0.5, 12, 0, 10))],
    "facing": [facing("w1", (-0.5, 1)), facing("w2", (2, 12))],
    "coverage": coverage((-0.5, 12)),
}
case(
    "g08b-missing-wall-blocks-route",
    golden("08"),
    "The meter's wall w1 is 1.5 ft long, too short for a battery; after a 1 ft stretch with no "
    "wall, w2 runs from s = 2 to 12. No cable can cross the gap, so every start on w2 fails "
    "its route and no spot exists.",
    g08b,
    {
        "decision_not": ["pass"],
        "spot": None,
        "missing_evidence_empty": True,
        "sweep_runs": [
            {"wall_id": "w2", "start_ft": [2, 9.4], "outcome": "fail", "failing_match": "route"}
        ],
    },
)

# g10: uniform gas gap d with error e. The strip spans past both wall ends, so every start
# on the wall sees the same perpendicular gap.
T = 3.0


def g10_scene(d, e, wall_pm=0.0):
    strip = gas("w1", (-5, 15), rect(-10, 20, d, d + 0.5), pm=e, conf=0.6)
    return straight_scene(-5, 15, z=FRONT0, objects=[strip], wall_pm=wall_pm) | {
        "ground": [concrete(rect(-5, 15, FRONT0, FRONT0 + 10))]
    }


ROWS = [
    ("pass", lambda e: round(T + e + 0.01, 2), "pass", None),
    ("upper-edge", lambda e: round(T + e, 2), "unsure", "margin"),
    ("lower-edge", lambda e: round(T - e, 2), "unsure", "margin"),
    ("fail", lambda e: round(T - e - 0.01, 2), "fail", None),
]
for e in (0.3, 0.5, 1.5):
    for name, dfun, outcome, cause in ROWS:
        d = dfun(e)
        check = {"match": "gas", "outcome": outcome, "measured_ft": d, "plus_minus_ft": e}
        if cause:
            check["unsure_cause"] = cause
        expect = {"checks": [check], "missing_evidence_empty": True}
        if outcome != "pass":
            expect["decision_not"] = ["pass"]
        if outcome == "fail":
            expect["spot"] = None
            expect["sweep_runs"] = [
                {"wall_id": "w1", "start_ft": [-5, 12.4], "outcome": "fail", "failing_match": "gas"}
            ]
        case(
            f"g10-e{round(e * 10):02d}-{name}",
            golden("10"),
            f"Every start has gas gap d = {d} ft with error {e} ft (gas meter +/- {e}, wall "
            f"exact), against a {T} ft threshold. The gas object's recognition conf of 0.6 "
            "must not change the error.",
            g10_scene(d, e),
            expect,
            {"gas": T},
        )

case(
    "g10-derived-compound-error",
    golden("10"),
    "Gas gap 3.5 ft between a gas meter at +/- 0.3 and a battery on a wall at +/- 0.3. The gap "
    "carries +/- 0.6 (linear sum), so 3.5 - 0.6 = 2.9 is not above 3: unsure by margin. A "
    "root-sum-square error of 0.424 would wrongly pass it.",
    g10_scene(3.5, 0.3, wall_pm=0.3),
    {
        "decision_not": ["pass"],
        "checks": [
            {
                "match": "gas",
                "outcome": "unsure",
                "unsure_cause": "margin",
                "measured_ft": 3.5,
                "plus_minus_ft": 0.6,
            }
        ],
        "missing_evidence_empty": True,
    },
    {"gas": T},
)

# g11a: every start fails gas, but the right end is an untapped corner.
case(
    "g11a-unexplored-corner",
    golden("11 (a)"),
    "Every start on w1 fails gas by 2 ft (gap 1 ft). The walk stopped at the corner at s = 8 "
    "without seeing the next wall, so the result cannot reject and must ask for the wall past "
    "the corner.",
    straight_scene(
        -3,
        8,
        z=FRONT0,
        objects=[gas("w1", (-3, 8), rect(-10, 20, 1.0, 1.5))],
        ground=[concrete(rect(-3, 8, FRONT0, FRONT0 + 10))],
        cov=coverage((-3, 8), right="unexplored"),
    ),
    {
        "decision_in": ["manual_review"],
        "spot": None,
        "missing_evidence_empty": False,
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [-3, 5.4], "outcome": "fail", "failing_match": "gas"}
        ],
    },
    {"gas": 3.0},
)

# g11b: both walls walked to real ends, every start fails gas.
z1 = D + 1.0
g11b = {
    "schema_version": "1.0",
    "meter": meter(0.0, 0.0),
    "walls": [
        straight("w1", -3, 8),
        {"id": "w2", "baseline": [[8, 0], [8, -6]], "plus_minus_ft": 0.0},
    ],
    "objects": [
        gas("w1", (-3, 8), rect(-10, 12, z1, z1 + 0.5)),
        gas("w2", (8, 14), [[8 + z1, -10], [8 + z1 + 0.5, -10], [8 + z1 + 0.5, 3], [8 + z1, 3]]),
    ],
    "ground": [concrete([[-3, 0], [8, 0], [8, -6], [18, -6], [18, 10], [-3, 10]])],
    "facing": [facing("w1", (-3, 8)), facing("w2", (8, 14))],
    "coverage": coverage((-3, 14)),
}
case(
    "g11b-both-ends-real-all-fail",
    golden("11 (b)"),
    "w1 turns an outside corner at s = 8 onto w2, walked to its real end at s = 14. Gas strips "
    "1 ft in front of each wall fail every start. Nothing is unobserved, so there is no spot "
    "and no photo request.",
    g11b,
    {
        "decision_in": ["manual_review", "reject"],
        "spot": None,
        "missing_evidence_empty": True,
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [-3, 5.4], "outcome": "fail", "failing_match": "gas"},
            {"wall_id": "w2", "start_ft": [8, 11.4], "outcome": "fail", "failing_match": "gas"},
        ],
    },
    {"gas": 3.0},
)

# g11c: observed starts fail gas; the ground right of s = 1 was never seen (closed gate).
case(
    "g11c-unobserved-ground",
    golden("11 (c)"),
    "Starts below s = 2*sqrt(2) - 0.5 fail gas. Starts beyond it pass gas but stand on ground "
    "nobody saw (observed only up to s = 1), so they are unsure, never pass, and the result "
    "asks for that ground.",
    straight_scene(
        -10,
        10,
        z=FRONT0,
        objects=[gas("w1", (-10, -0.5), rect(-12, -0.5, 1.0, 1.5))],
        ground=[concrete(rect(-10, 1, FRONT0, FRONT0 + 10))],
        cov=coverage((-10, 10), ground=[(-10, 1)]),
    ),
    {
        "decision_in": ["manual_review"],
        "spot": {"wall_id": "w1", "span_within": [2 * math.sqrt(2) - 0.5, 10]},
        "missing_evidence_empty": False,
        "sweep_runs": [
            {"wall_id": "w1", "start_ft": [-9.9, 2.2], "outcome": "fail", "failing_match": "gas"},
            {"wall_id": "w1", "start_ft": [2.5, 7.3], "outcome": "unsure"},
        ],
    },
    {"gas": 3.0},
)

# g12a: legal starts only in the open interval (7, 7.1), narrower than a 2 in grid step.
win2 = 10.1 + W
case(
    "g12a-subgrid-start",
    golden("12"),
    "Windows at s = [3, 4] and [10.1 + 31/12, 11.1 + 31/12] with 3 ft opening clearance leave "
    "legal starts only in (7, 7.1). A 2 in grid from s = 0 samples 7 and 43/6 and misses them.",
    straight_scene(
        -1,
        16,
        objects=[
            opening("window", "w1", (3, 4), 4.0, 7.0),
            opening("window", "w1", (win2, win2 + 1), 4.0, 7.0),
        ],
    ),
    {
        "spot": {"wall_id": "w1", "span_within": [7, 7.1 + W]},
        "sweep_runs": [
            {
                "wall_id": "w1",
                "start_ft": [-1, 6.95],
                "outcome": "fail",
                "failing_match": "opening",
            },
            {
                "wall_id": "w1",
                "start_ft": [7.2, 13.4],
                "outcome": "fail",
                "failing_match": "opening",
            },
        ],
    },
    {"opening": 3.0},
)

# g12b: one straight segment exactly one battery wide; its only start is its last start.
g12b_wall = polyline_wall("w1", -3, [(1.8, 40 - 8 * k) for k in range(5)] + [(W, 0)])
case(
    "g12b-exact-fit-last-start",
    golden("12"),
    "Five 1.8 ft segments, then one straight segment exactly 31/12 ft long at s = [6, 6 + 31/12] "
    "where the wall ends. Its single start, s = 6, is also the last start and must be "
    "enumerated.",
    {
        "schema_version": "1.0",
        "meter": meter(0.0, 0.0),
        "walls": [g12b_wall],
        "objects": [],
        "ground": [offset_ground(g12b_wall["baseline"])],
        "facing": [facing("w1", (-3, 6 + W))],
        "coverage": coverage((-3, 6 + W)),
    },
    {"spot": {"wall_id": "w1", "span_within": [6, 6 + W]}, "missing_evidence_empty": True},
)


# g13: F = right of the meter, gas gap 3.2 +/- 0.3 (unsure); S = left, passes.
def g13_scene(x0):
    strip = gas("w1", (0.3, 8), rect(0.3, 12, 3.2, 3.7), pm=0.3)
    return straight_scene(x0, 8, z=FRONT0, objects=[strip]) | {
        "ground": [concrete(rect(x0, 8, FRONT0, FRONT0 + 10))]
    }


s_edge = 0.3 - math.sqrt(3.3**2 - 3.2**2)
case(
    "g13a-unsure-never-outranks-pass",
    golden("13"),
    "Starts right of the meter have gas gap 3.2 +/- 0.3 (unsure) and the shortest routes. "
    "Batteries whose right edge is left of s = 0.3 - sqrt(0.65) clear gas and pass. The chosen "
    "spot must be a passing one on the left.",
    g13_scene(-8),
    {
        "spot": {"wall_id": "w1", "span_within": [-8, s_edge]},
        "checks": [{"match": "gas", "outcome": "pass"}],
        "sweep_runs": [{"wall_id": "w1", "start_ft": [0.5, 5], "outcome": "unsure"}],
        "missing_evidence_empty": True,
    },
    {"gas": 3.0},
)
case(
    "g13b-unsure-alone",
    golden("13"),
    "The wall ends at s = -0.5, so every start has gas gap 3.2 +/- 0.3. The best spot is "
    "unsure by margin and fully observed: manual review with no photo request.",
    g13_scene(-0.5),
    {
        "decision_in": ["manual_review"],
        "spot": {"wall_id": "w1", "span_within": [-0.5, 8]},
        "checks": [
            {
                "match": "gas",
                "outcome": "unsure",
                "unsure_cause": "margin",
                "measured_ft": 3.2,
                "plus_minus_ft": 0.3,
            }
        ],
        "sweep_runs": [{"wall_id": "w1", "start_ft": [-0.4, 5.3], "outcome": "unsure"}],
        "missing_evidence_empty": True,
    },
    {"gas": 3.0},
)

# No coverage field: nothing counts as observed and both ends default to unexplored.
nocov = straight_scene(-6, 10)
del nocov["coverage"]
case(
    "c5-no-coverage",
    f"scene.schema.json coverage and end descriptions at origin/t3/server {SERVER_SHA}; C5",
    "A clean straight wall with ground and facing measurements but no coverage field. Nothing is "
    "known to be observed, so no start may pass, the result must ask for views, and it cannot "
    "reject because both ends default to unexplored.",
    nocov,
    {
        "decision_in": ["manual_review"],
        "missing_evidence_empty": False,
        "sweep_runs": [{"wall_id": "w1", "start_ft": [-6, 7.4], "outcome": "unsure"}],
    },
)


def main():
    for old in HERE.glob("*.json"):
        old.unlink()
    for c in CASES:
        (HERE / f"{c['id']}.json").write_text(json.dumps(c, indent=2) + "\n")
    print(f"wrote {len(CASES)} cases")


if __name__ == "__main__":
    main()
