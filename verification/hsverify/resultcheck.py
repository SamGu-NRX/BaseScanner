"""Judge a placement result (contract C2) against its scene (C1) and the decision rule (C5).

Everything here is pure: a scene and a result go in, a list of problems comes out. The
checks hold for any policy and any rule values, so they can run on every response:

- decision consistency: what `pass`, `reject` and `manual_review` each require of the rest
  of the record;
- the margin rule: a check's outcome must follow from its measurement, error and threshold
  (PASS only when the margin beats the error, and clears the review line when the check has
  one; FAIL only when past the threshold by more than the error; otherwise UNSURE);
- coverage: no battery position passes without the coverage each passing check needs, as the
  server's README ("What settles each check") states it: the wall seen high enough over the
  clearance's reach, the ground out to the battery's depth plus the reach, the facing and
  overhead bands unless measured, and the cable route. The reach includes the battery's
  position error, which depends on how the wall was found. Only points within reach whatever
  the wall's shape are required, so a correct server is not flagged;
- requests: every check left unsure for coverage is named for each band it lacks, and nothing
  is requested that was already seen as far as the request needs;
- bookkeeping: counts add up, the input hash matches what was sent, the spot's offset from
  the meter matches its centre.

Case expectations (a scene plus the outcomes geometry forces) and the mirror transform used
for the left-right symmetry check also live here.
"""

from __future__ import annotations

import copy
import hashlib
import itertools
import math
from dataclasses import dataclass
from typing import Any

import yaml
from jsonschema import Draft202012Validator

EPS = 1e-6
NUMBER_TOL_FT = 1e-5
# Spot centres and offsets are rounded by the server; a hundredth of a foot is 1/8 inch.
OFFSET_TOL_FT = 0.01


@dataclass(frozen=True)
class Need:
    """One piece of coverage a check needs around a battery over [lo, hi] (server/README.md at the
    tested ref, "What settles each check"):

    - `ground`: ground over [lo - r, hi + r], out to depth + r in front of the battery;
    - `wall`: the wall band over [lo - r, hi + r], seen higher than `height`;
    - `facing`, `overhead`: the band over [lo, hi]; where no measurement (`facing`, `overheads`)
      covers a stretch, the band's `out_ft` there must reach `height`.

    r is `radius`, plus the battery's position error when `widen`.
    """

    band: str
    radius: float = 0.0
    height: float = 0.0
    widen: bool = True


# Scene lists whose entries settle facing_gap and headroom where they cover the battery.
MEASUREMENTS = {"facing": "facing", "overhead": "overheads"}
# rules.yaml error keys for a wall's `source`; a wall without one is tapped.
WALL_ERROR = {"tap": "wall", "mesh": "mesh", "plane": "plane"}


@dataclass(frozen=True)
class RuleSet:
    """What the checks here need from the server's rules.yaml at the tested ref."""

    width_ft: float
    depth_ft: float
    # check id -> the coverage its pass needs
    needs: dict[str, tuple[Need, ...]]
    # default error by object source, for walls (tap, mesh, plane) and the meter, and drift_per_ft
    errors: dict[str, float]
    # the height up the wall the cable route must be seen, from the meter to the battery
    route_height_ft: float = 0.0
    # the rules' sweep.step_ft: the spacing at which a passing sweep run's starts are sampled
    step_ft: float | None = None

    @classmethod
    def from_yaml(cls, text: str) -> RuleSet:
        data = yaml.safe_load(text)

        def value(*path: str, default: float | None = None) -> float:
            node: Any = data
            for key in path:
                if not isinstance(node, dict) or key not in node:
                    if default is not None:
                        return default
                    raise ValueError(f"rules.yaml has no {'.'.join(path)}")
                node = node[key]
            if node is None and default is not None:
                return default
            return float(node["value"] if isinstance(node, dict) else node)

        depth = value("battery", "depth_ft")
        headroom = value("headroom", "min_ft")
        # Openings need the wall seen to headroom height, or to a lower exempt height the rules set.
        opening_height = min(
            headroom, value("openings", "exempt_bottom_above_ft", default=headroom)
        )

        def r(key: str) -> float:
            return value("clearances", key)

        def reach(key: str) -> Need:
            return Need("ground", r(key))

        needs = {
            "ground_surface": (Need("ground", 0.0),),
            "wall_backing": (Need("wall", 0.0, value("battery", "height_ft"), widen=False),),
            "gas_clearance": (reach("gas_ft"), Need("wall", r("gas_ft"), headroom)),
            "battery_clearance": (reach("battery_ft"), Need("wall", r("battery_ft"), headroom)),
            "ac_clearance": (reach("ac_ft"),),
            "drive_clearance": (reach("drive_ft"),),
            "pool_clearance": (reach("pool_ft"),),
            "opening_clearance": (Need("wall", r("opening_ft"), opening_height),),
            "wall_equipment_above": (Need("wall", r("wall_equipment_ft"), headroom, widen=False),),
            "facing_gap": (Need("facing", 0.0, depth + value("facing", "min_ft"), widen=False),),
            "headroom": (Need("overhead", 0.0, headroom, widen=False),),
        }
        errors = {
            name: value("errors", f"{name}_ft")
            for name in ("tap", "vlm", "tape", "wall", "mesh", "plane", "meter")
        }
        errors["drift_per_ft"] = value("errors", "drift_per_ft")
        return cls(
            value("battery", "width_ft"),
            depth,
            needs,
            errors,
            value("route", "height_ft"),
            value("sweep", "step_ft"),
        )


def schema_errors(instance: Any, schema: dict) -> list[str]:
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
    return [f"{'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message}" for e in errors]


# --- Coverage --------------------------------------------------------------------------------


def reached(entry: dict) -> float:
    """How far an observed entry's view reached: its `out_ft`, or for a band other than ground
    without one, all the way (C1: the wall to headroom height, facing to whatever faces it,
    overhead clear to the sky)."""
    default = 0.0 if entry["band"] == "ground" else math.inf
    return entry.get("out_ft", default)


def observed(
    scene: dict, band: str, min_out_ft: float = 0.0, beyond: bool = False
) -> list[tuple[float, float]]:
    """Merged observed s-intervals for a band, counting only entries whose view reached
    `min_out_ft` (out from the wall for ground and facing, up for wall and overhead). With
    `beyond`, the view must pass it strictly, as the server requires of a wall seen "higher
    than" a height (server/scene.py at 6c7ca23)."""
    spans = []
    for entry in scene.get("coverage", {}).get("observed", []):
        if entry["band"] != band:
            continue
        far = reached(entry)
        if (far <= min_out_ft) if beyond else (far + EPS < min_out_ft):
            continue
        spans.append(tuple(sorted(entry["span_ft"])))
    spans.sort()
    merged: list[list[float]] = []
    for a, b in spans:
        if merged and a <= merged[-1][1] + EPS:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return [(a, b) for a, b in merged]


def covers(intervals: list[tuple[float, float]], a: float, b: float, slack: float = 0.0) -> bool:
    return any(lo - slack <= a + EPS and b - EPS <= hi + slack for lo, hi in intervals)


# --- Invariants ------------------------------------------------------------------------------


def margin_problem(check: dict) -> str | None:
    """The C5 rule for one check, when its numbers are all present.

    PASS needs a clear pass and FAIL a clear fail. A check with a review band
    (`review_threshold_ft`) passes only when it also clears that line. UNSURE for another cause
    (unobserved area, unknown attribute, review rule) may sit on numbers that would pass, never
    on numbers that clearly fail. UNSURE labelled `margin` must lie within its error of a line:
    C2 defines that cause as "measured inside the error band".
    """
    m, e, t, cmp = (
        check.get(k) for k in ("measured_ft", "plus_minus_ft", "threshold_ft", "comparison")
    )
    if m is None or e is None or t is None or cmp is None:
        return None
    review = check.get("review_threshold_ft")
    lines = [t] if review is None else [t, review]
    if cmp == "at_least":
        clear_pass = all(m - e > x + EPS for x in lines)
        clear_fail = m + e < t - EPS
    else:
        clear_pass = all(m + e < x - EPS for x in lines)
        clear_fail = m - e > t + EPS
    expected = "pass" if clear_pass else "fail" if clear_fail else "unsure"
    outcome, cause = check["outcome"], check.get("unsure_cause")
    band = f" ({cmp} {t}" + (f", review {review})" if review is not None else ")")
    if outcome == "unsure" and cause == "margin" and expected == "unsure":
        if not any(abs(m - x) <= e + EPS for x in lines):
            return (
                f"check {check['id']}: unsure_cause margin, but {m} ± {e} is not within its "
                f"error of any line{band}; a review band is rule_requires_review"
            )
        return None
    other_cause = outcome == "unsure" and cause not in (None, "margin")
    if outcome == expected or (other_cause and not clear_fail):
        return None
    because = f" ({cause})" if cause else ""
    return (
        f"check {check['id']}: measured {m} ± {e}{band} should be {expected}, "
        f"server says {outcome}{because}"
    )


def invariant_problems(
    scene: dict, result: dict, sent: bytes | None = None, rules: RuleSet | None = None
) -> list[str]:
    problems: list[str] = []
    decision = result["decision"]
    spot = result.get("spot")
    checks = result.get("checks", [])

    if decision == "pass":
        if spot is None or spot.get("outcome") != "pass":
            problems.append("decision pass without a passing spot")
        not_passing = [c["id"] for c in checks if c["outcome"] != "pass"]
        if not_passing:
            problems.append(f"decision pass with checks not passing: {not_passing}")
        if result.get("missing_evidence"):
            problems.append("decision pass while asking for more evidence")
        if not result["policy"].get("auto_approve"):
            problems.append("decision pass although policy.auto_approve is false")
    if decision == "reject":
        if spot is not None:
            problems.append("decision reject but a spot is given")
        if result.get("missing_evidence"):
            problems.append("decision reject while asking for more evidence")
    if decision == "manual_review" and not result.get("reasons"):
        problems.append("decision manual_review without reasons")
    if (spot is None) != (result.get("route") is None):
        problems.append("spot and route must be both null or both present")

    for check in checks:
        problem = margin_problem(check)
        if problem:
            problems.append(problem)
        cause = check.get("unsure_cause")
        if check["outcome"] == "unsure" and cause is None:
            problems.append(f"check {check['id']}: unsure without unsure_cause")
        if check["outcome"] != "unsure" and cause is not None:
            problems.append(f"check {check['id']}: unsure_cause on a {check['outcome']} check")

    stats = result["stats"]
    if stats["pass"] + stats["unsure"] + stats["fail"] != stats["candidates"]:
        problems.append(
            f"stats: pass {stats['pass']} + unsure {stats['unsure']} + fail {stats['fail']} "
            f"!= candidates {stats['candidates']}"
        )
    if sent is not None and stats["input_sha256"] != hashlib.sha256(sent).hexdigest():
        problems.append("stats.input_sha256 does not match the scene bytes sent")

    if spot is not None:
        mx, _, mz = scene["meter"]["pos"]
        want = [spot["center"][0] - mx, spot["center"][1] - mz]
        got = spot["meter_offset_ft"]
        if max(abs(want[0] - got[0]), abs(want[1] - got[1])) > OFFSET_TOL_FT:
            problems.append(f"spot.meter_offset_ft {got} != centre - meter {want}")

    problems += missing_evidence_problems(scene, result, rules)
    if rules is not None:
        problems += coverage_problems(scene, result, rules)
    return problems


def required_span(lo: float, hi: float, radius: float) -> tuple[float, float]:
    """Along-wall stretch within `radius` of a battery covering [lo, hi].

    Along the wall chain, distance is never shorter than straight-line distance, so every point
    in this stretch lies within the radius even where the chain bends: observing it is necessary
    (not sufficient) for a PASS, and demanding it cannot wrongly flag a correct server.
    """
    return lo - radius, hi + radius


def battery_error(scene: dict, rules: RuleSet, wall_id: str, lo: float, hi: float) -> float:
    """Position error of a battery over [lo, hi] on `wall_id`: the wall's explicit error, or the
    default for its `source` (tap, mesh, plane) plus drift at the battery's edge further from the
    meter (S2 70ab0b0)."""
    wall = next((w for w in scene["walls"] if w["id"] == wall_id), None)
    if wall is None:
        raise ValueError(f"the result names wall {wall_id!r}, which the scene does not have")
    if "plus_minus_ft" in wall:
        return wall["plus_minus_ft"]
    default = rules.errors[WALL_ERROR[wall.get("source", "tap")]]
    return default + rules.errors["drift_per_ft"] * max(abs(lo), abs(hi))


def reach_gaps(
    scene: dict, rules: RuleSet, check: str, wall_id: str, lo: float, hi: float
) -> list[tuple[str, str]]:
    """(band, what is missing) for each Need of `check` a battery over [lo, hi] does not have.

    Only points within the check's radius R of the battery whatever the wall's shape are
    required, so a correct server is never flagged. R is widened by the battery's position
    error e where the server widens it (C5: a pass needs the margin to exceed the error, and an
    unseen hazard just past the seen area is a margin of zero).

    - wall band: [lo - R - e, hi + R + e] along the wall, since distance along the wall is
      never shorter than straight-line distance, seen up to the check's height;
    - ground band: out to depth + R + e in front of the battery (a battery sits flush on one
      straight segment), and at distance d past either end out to R + e - d. The ground point
      there is at most d along the wall plus R + e - d out from the battery's end;
    - facing and overhead bands: over the battery, reaching the check's distance unless
      measured.
    """
    gaps = []
    for need in rules.needs[check]:
        reach = need.radius + (battery_error(scene, rules, wall_id, lo, hi) if need.widen else 0.0)
        if need.band == "ground":
            gap = ground_gap(scene, lo, hi, rules.depth_ft, reach)
        elif need.band == "wall":
            a, b = required_span(lo, hi, reach)
            seen = covers(observed(scene, "wall", min_out_ft=need.height, beyond=True), a, b)
            gap = None if seen else f"wall [{a:.2f}, {b:.2f}] observed higher than {need.height} ft"
        else:
            gap = measured_band_gap(scene, need.band, wall_id, lo, hi, need.height)
        if gap:
            gaps.append((need.band, gap))
    return gaps


def measured_band_gap(
    scene: dict, band: str, wall_id: str, lo: float, hi: float, need: float
) -> str | None:
    """The first stretch of [lo, hi] the facing or overhead band leaves unsettled: not observed,
    or observed short of `need` where no measurement covers it."""
    entries = [
        (*sorted(e["span_ft"]), reached(e))
        for e in scene.get("coverage", {}).get("observed", [])
        if e["band"] == band
    ]
    measured = [
        tuple(sorted(m["span_ft"]))
        for m in scene.get(MEASUREMENTS[band], [])
        if m.get("wall_id", wall_id) == wall_id
    ]
    edges = {x for e in entries for x in e[:2]} | {x for m in measured for x in m}
    cuts = sorted({lo, hi} | {x for x in edges if lo < x < hi})
    for p, q in itertools.pairwise(cuts):
        if q - p <= EPS:
            continue
        seen = [out for x, y, out in entries if x <= p + EPS and q - EPS <= y]
        where = f"{band} [{p:.2f}, {q:.2f}] observed"
        if not seen:
            return f"{where}, none seen"
        settled = any(x <= p + EPS and q - EPS <= y for x, y in measured)
        # Strictly beyond, as the server requires (server/solver.py at 6c7ca23).
        if not settled and max(seen) <= need:
            return f"{where} out to {need:.2f} ft or measured, seen {max(seen):.2f} ft"
    return None


def run_starts(span: list[float], step_ft: float | None) -> list[float]:
    """Starts sampled from a sweep run: its first, every step after it, and its last.

    A sample, not the server's own list: the server also evaluates boundaries and midpoints
    that a run reports only as its two ends."""
    if step_ft is None or step_ft <= 0:
        raise ValueError("checking a sweep run needs the rules' sweep.step_ft")
    a, b = span
    count = max(0, round((b - a) / step_ft))
    return [a + k * step_ft for k in range(count)] + [b]


def coverage_problems(scene: dict, result: dict, rules: RuleSet) -> list[str]:
    """Missing coverage is never a pass (C5), to the reach each check's rule looks out to (see
    reach_gaps). A sweep run that passes needs, at each start sampled from it (run_starts), every
    check's area around that start's battery with that battery's own position error, and the
    wall and cable route back to the meter over the whole run. Checking the whole run as one
    battery at its farthest start's error would ask for more than any single start needs."""
    problems: list[str] = []
    route_wall = observed(scene, "wall", min_out_ft=rules.route_height_ft, beyond=True)
    # A passing run passes every check the server evaluated; a check it did not evaluate (a
    # battery clearance with no battery in the scene, say) needs nothing.
    evaluated = {c["id"] for c in result.get("checks", [])} or set(rules.needs)
    if "coverage" not in scene and result["decision"] == "pass":
        problems.append("decision pass for a scene with no coverage at all")

    for run in result.get("sweep", []):
        if run["outcome"] != "pass":
            continue
        lo, hi = run["start_ft"][0], run["start_ft"][1] + rules.width_ft
        route_lo, route_hi = min(0.0, lo), max(0.0, hi)
        if not covers(route_wall, route_lo, route_hi):
            problems.append(
                f"sweep pass for starts {run['start_ft']} but the wall and cable route "
                f"[{route_lo:.2f}, {route_hi:.2f}] were not all observed higher than "
                f"{rules.route_height_ft} ft"
            )
        for check in sorted(set(rules.needs) & evaluated):
            gaps = {}  # each gap once, at the first start that needs it
            for start in run_starts(run["start_ft"], rules.step_ft):
                battery = (start, start + rules.width_ft)
                for _, gap in reach_gaps(scene, rules, check, run["wall_id"], *battery):
                    gaps.setdefault(gap, start)
            problems += [
                f"sweep pass for starts {run['start_ft']} but at start {start:.2f} {check} "
                f"needs {gap}"
                for gap, start in gaps.items()
            ]

    spot = result.get("spot")
    if spot is not None:
        lo, hi = spot["span_ft"]
        for check in result.get("checks", []):
            if check["outcome"] != "pass" or check["id"] not in rules.needs:
                continue
            for _, gap in reach_gaps(scene, rules, check["id"], spot["wall_id"], lo, hi):
                problems.append(f"check {check['id']} passes but needs {gap}")

    for request in result.get("missing_evidence", []):
        if request["kind"] != "band" or "span_ft" not in request or "band" not in request:
            continue
        a, b = sorted(request["span_ft"])
        # A request may want a farther or higher view over a span already seen: it is redundant
        # only where the band was seen as far as it asks (`out_ft`, on every band since S2
        # 55cb4b0). Without one, a ground request is redundant past GROUND_FAR_FT, and any other
        # only where the band was seen all the way (no `out_ft`).
        default = GROUND_FAR_FT if request["band"] == "ground" else math.inf
        far = request.get("out_ft", default)
        if b - a > EPS and covers(observed(scene, request["band"], min_out_ft=far), a, b):
            problems.append(
                f"missing_evidence asks for {request['band']} {request['span_ft']}, "
                "which the scene lists as observed"
            )
    return problems


def ground_gap(scene: dict, lo: float, hi: float, depth: float, radius: float) -> str | None:
    """The first stretch of ground seen less far out than a battery over [lo, hi] needs (see
    coverage_problems), or None."""
    entries = [
        (*sorted(e["span_ft"]), e.get("out_ft", 0.0))
        for e in scene.get("coverage", {}).get("observed", [])
        if e["band"] == "ground"
    ]
    a, b = lo - radius, hi + radius
    cuts = sorted({a, lo, hi, b} | {x for e in entries for x in e[:2] if a < x < b})
    for p, q in itertools.pairwise(cuts):
        if q - p <= EPS:
            continue
        inside = lo - EPS <= p and q <= hi + EPS
        need = depth + radius if inside else radius - min(abs(lo - q), abs(p - hi))
        seen = max((out for x, y, out in entries if x <= p + EPS and q - EPS <= y), default=None)
        if seen is None or seen + EPS < need:
            where = f"ground [{p:.2f}, {q:.2f}] observed"
            if seen is None:
                return f"{where}, none seen"
            return f"{where} out to {need:.2f} ft, seen {seen:.2f} ft"
    return None


def missing_evidence_problems(scene: dict, result: dict, rules: RuleSet | None = None) -> list[str]:
    """When coverage is what stands in the way (reason unobserved_area), every check left unsure
    for an unobserved area is named by a request, and a clearance check by a request of each
    band it lacks around the chosen spot: a check that forgets one band leaves the next capture
    still unsure. Otherwise no photo would change the answer, and C2 lets missing_evidence stay
    empty."""
    codes = {r["code"] for r in result.get("reasons", [])}
    if "unobserved_area" not in codes:
        return []
    requests = result.get("missing_evidence", [])
    if not requests:
        return ["reason unobserved_area but missing_evidence is empty"]
    named = {(r.get("band"), c) for r in requests for c in r.get("checks", [])}
    problems = [
        f"check {c} is unsure (unobserved) but no missing_evidence entry names it"
        for c in unobserved_checks(result)
        if not any(check == c for _, check in named)
    ]
    spot = result.get("spot")
    if rules is None or spot is None:
        return problems
    lo, hi = spot["span_ft"]
    asked = with_past_ends_asked(scene, requests)
    for c in unobserved_checks(result):
        if c not in rules.needs:
            continue
        for band, gap in reach_gaps(asked, rules, c, spot["wall_id"], lo, hi):
            if (band, c) not in named:
                problems.append(
                    f"check {c} is unsure and needs {gap}, but no {band} request names it"
                )
    return problems


# How far a past_end request may sit from the chain's actual end and still name it.
END_TOL_FT = 0.1


def chain_ends_s(scene: dict) -> tuple[float, float] | None:
    """s of the wall chain's left and right ends (the meter's projection is s = 0; distance
    runs along every wall and across the gaps between them), or None without a meter wall."""
    walls = scene.get("walls", [])
    points, owner = [], []
    for wall in walls:
        for pt in wall["baseline"]:
            points.append(tuple(pt))
            owner.append(wall["id"])
    if len(points) < 2 or "meter" not in scene:
        return None
    cum = [0.0]
    for p, q in itertools.pairwise(points):
        cum.append(cum[-1] + math.dist(p, q))
    mx, _, mz = scene["meter"]["pos"]
    best = None
    for i, (p, q) in enumerate(itertools.pairwise(points)):
        if owner[i] != scene["meter"]["wall_id"] or owner[i + 1] != owner[i]:
            continue
        seg = math.dist(p, q)
        if seg == 0:
            continue
        t = ((mx - p[0]) * (q[0] - p[0]) + (mz - p[1]) * (q[1] - p[1])) / seg**2
        t = min(1.0, max(0.0, t))
        d = math.dist((mx, mz), (p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
        if best is None or d < best[0]:
            best = (d, cum[i] + t * seg)
    if best is None:
        return None
    return -best[1], cum[-1] - best[1]


def with_past_ends_asked(scene: dict, requests: list[dict]) -> dict:
    """The scene as if everything past each end the result asks to walk past were observed.

    Past an unexplored end the wall may turn, so a view along the same line settles nothing; the
    server asks to keep walking (`past_end`) instead of for a band there, and that request covers
    every band beyond the end. Only a request at the chain's actual end, on a side not marked
    `limit`, earns that credit."""
    ends = chain_ends_s(scene)
    kinds = scene.get("coverage", {}).get("ends", {})
    past = [r for r in requests if r["kind"] == "past_end" and "span_ft" in r and "side" in r]
    if not past or ends is None:
        return scene
    m = copy.deepcopy(scene)
    observed_ = m.setdefault("coverage", {}).setdefault("observed", [])
    for r in past:
        side = r["side"]
        end = ends[0] if side == "left" else ends[1]
        if kinds.get(side, {}).get("kind") == "limit" or abs(r["span_ft"][0] - end) > END_TOL_FT:
            continue
        span = [end - 1e6, end] if side == "left" else [end, end + 1e6]
        for band in ("wall", "facing", "overhead"):
            observed_.append({"band": band, "span_ft": span})
        observed_.append({"band": "ground", "span_ft": span, "out_ft": 1e6})
    return m


# --- Case expectations -----------------------------------------------------------------------


def assumption_mismatches(assumed: dict[str, float], result: dict) -> list[str]:
    out = []
    for key, value in assumed.items():
        for check in result.get("checks", []):
            threshold = check.get("threshold_ft")
            if key in check["id"] and threshold is not None and abs(threshold - value) > EPS:
                out.append(
                    f"case assumes {key} threshold {value}, server's {check['id']} uses "
                    f"{check['threshold_ft']}"
                )
    return out


def expectation_problems(expect: dict, result: dict) -> list[str]:
    problems: list[str] = []
    decision = result["decision"]
    if "decision_in" in expect and decision not in expect["decision_in"]:
        problems.append(f"decision {decision}, expected one of {expect['decision_in']}")
    if decision in expect.get("decision_not", []):
        problems.append(f"decision {decision} is ruled out for this case")

    if "spot" in expect:
        want, spot = expect["spot"], result.get("spot")
        if want is None and spot is not None:
            problems.append(f"expected no spot, got {spot['wall_id']} {spot['span_ft']}")
        if want is not None:
            if spot is None:
                problems.append("expected a spot, got none")
            else:
                a, b = want["span_within"]
                s0, s1 = spot["span_ft"]
                if spot["wall_id"] != want["wall_id"] or s0 < a - 1 / 12 or s1 > b + 1 / 12:
                    problems.append(
                        f"spot {spot['wall_id']} {spot['span_ft']} outside expected "
                        f"{want['wall_id']} {want['span_within']}"
                    )

    for rule in expect.get("sweep_runs", []):
        a, b = rule["start_ft"]
        runs = [
            r
            for r in result.get("sweep", [])
            if r["wall_id"] == rule["wall_id"] and r["start_ft"][0] < b and r["start_ft"][1] > a
        ]
        if not runs and "outcome" in rule:
            problems.append(f"no sweep run overlaps {rule['wall_id']} starts ({a}, {b})")
        for run in runs:
            if "outcome" in rule and run["outcome"] != rule["outcome"]:
                problems.append(
                    f"sweep {run['wall_id']} starts {run['start_ft']} is {run['outcome']}, "
                    f"expected {rule['outcome']}"
                )
            if "outcome_not" in rule and run["outcome"] == rule["outcome_not"]:
                why = f" ({rule['reason']})" if "reason" in rule else ""
                problems.append(
                    f"sweep {run['wall_id']} starts {run['start_ft']} is {run['outcome']}, "
                    f"which this case rules out{why}"
                )
            for field, key in (("failing", "failing_match"), ("unsure", "unsure_match")):
                if key in rule and not any(rule[key] in c for c in run[field]):
                    problems.append(
                        f"sweep {run['wall_id']} starts {run['start_ft']}: no {field} check "
                        f"matching {rule[key]!r} (has {run[field]})"
                    )

    for rule in expect.get("checks", []):
        matching = [c for c in result.get("checks", []) if rule["match"] in c["id"]]
        if not matching:
            problems.append(f"no check matching {rule['match']!r}")
        for check in matching:
            for field in ("outcome", "unsure_cause"):
                if field in rule and check.get(field) != rule[field]:
                    problems.append(
                        f"check {check['id']}: {field} {check.get(field)}, expected {rule[field]}"
                    )
            # Pinned numbers catch a server that measures from somewhere else (for example
            # another battery depth) and lands on the right outcome by accident. The server
            # rounds to 6 decimals.
            for field in ("measured_ft", "plus_minus_ft"):
                got = check.get(field)
                if field in rule and (got is None or abs(got - rule[field]) > NUMBER_TOL_FT):
                    problems.append(f"check {check['id']}: {field} {got}, expected {rule[field]}")

    for rule in expect.get("start_outcomes", []):
        got = outcome_at(result, rule["wall_id"], rule["start_ft"])
        if got != rule["outcome"]:
            why = f" ({rule['why']})" if "why" in rule else ""
            problems.append(
                f"start {rule['wall_id']} {rule['start_ft']} is {got or 'not evaluated'}, "
                f"expected {rule['outcome']}{why}"
            )

    if "missing_evidence_empty" in expect:
        empty = not result.get("missing_evidence")
        if empty != expect["missing_evidence_empty"]:
            problems.append(
                "missing_evidence "
                + ("is empty" if empty else "is not empty")
                + f", expected {'empty' if expect['missing_evidence_empty'] else 'requests'}"
            )
    return problems


# --- Transforms for black-box properties -----------------------------------------------------


def _flip_span(span: list[float]) -> list[float]:
    return [-span[1], -span[0]]


def mirror_scene(scene: dict) -> dict:
    """Reflect the scene left to right (x -> -x) so s becomes -s.

    Baselines are reversed after reflecting so they still run left to right as seen from
    outside, which keeps every wall's outward side. Keyframes, stills and heading are dropped,
    since a reflected camera pose is not a rotation.
    """
    m = copy.deepcopy(scene)
    for key in ("keyframes", "stills", "heading"):
        m.pop(key, None)
    x, y, z = m["meter"]["pos"]
    m["meter"]["pos"] = [-x, y, z]
    m["walls"] = [
        wall | {"baseline": [[-px, pz] for px, pz in reversed(wall["baseline"])]}
        for wall in reversed(m["walls"])
    ]
    for obj in m.get("objects", []):
        obj["span_ft"] = _flip_span(obj["span_ft"])
        if "footprint" in obj:
            obj["footprint"] = [[-px, pz] for px, pz in obj["footprint"]]
    for area in m.get("ground", []):
        area["polygon"] = [[-px, pz] for px, pz in area["polygon"]]
    for key in ("overheads", "facing"):
        for item in m.get(key, []):
            item["span_ft"] = _flip_span(item["span_ft"])
    coverage = m.get("coverage")
    if coverage:
        for entry in coverage.get("observed", []):
            entry["span_ft"] = _flip_span(entry["span_ft"])
        ends = coverage.get("ends")
        if ends:
            coverage["ends"] = {
                side: ends[other]
                for side, other in (("left", "right"), ("right", "left"))
                if other in ends
            }
    return m


def outcome_lengths(result: dict) -> dict[str, float]:
    """Total length of battery start positions per outcome, from the sweep."""
    totals = {"pass": 0.0, "unsure": 0.0, "fail": 0.0}
    for run in result.get("sweep", []):
        totals[run["outcome"]] += run["start_ft"][1] - run["start_ft"][0]
    return totals


def comparable(result: dict) -> dict:
    """The result with the fields that may legitimately differ between identical runs removed."""
    r = copy.deepcopy(result)
    r["stats"].pop("elapsed_ms", None)
    return r


# --- Ordering properties ---------------------------------------------------------------------
#
# Comparisons between the answers to a scene and to a changed copy of it. They need no expected
# numbers: more measurement error or less coverage can only make the server less sure.


def outcome_at(result: dict, wall_id: str, start_ft: float) -> str | None:
    """Outcome of the sweep run containing this battery start, or None if none contains it."""
    for run in result.get("sweep", []):
        a, b = run["start_ft"]
        if run["wall_id"] == wall_id and a - EPS <= start_ft <= b + EPS:
            return run["outcome"]
    return None


def probe_starts(*results: dict) -> list[tuple[str, float]]:
    """Every run's ends and middle, from all results: where the outcomes can be compared."""
    points = set()
    for result in results:
        for run in result.get("sweep", []):
            a, b = run["start_ft"]
            points |= {(run["wall_id"], a), (run["wall_id"], b), (run["wall_id"], (a + b) / 2)}
    return sorted(points)


def more_error_problems(before: dict, after: dict, change: str) -> list[str]:
    """With more error, a start may only move toward UNSURE: UNSURE stays, PASS and FAIL stay
    or become UNSURE."""
    problems = []
    for wall_id, s in probe_starts(before, after):
        a, b = outcome_at(before, wall_id, s), outcome_at(after, wall_id, s)
        if a is None or b is None or a == b or b == "unsure":
            continue
        problems.append(f"{change}: start {wall_id} {s:.3f} went from {a} to {b}")
    if before["decision"] != "pass" and after["decision"] == "pass":
        problems.append(f"{change}: the decision became pass")
    return problems


def less_coverage_problems(before: dict, after: dict, change: str) -> list[str]:
    """With less observed, no start may newly PASS."""
    problems = [
        f"{change}: start {wall_id} {s:.3f} went from {outcome_at(before, wall_id, s)} to pass"
        for wall_id, s in probe_starts(before, after)
        if outcome_at(after, wall_id, s) == "pass"
        and outcome_at(before, wall_id, s) not in (None, "pass")
    ]
    if before["decision"] != "pass" and after["decision"] == "pass":
        problems.append(f"{change}: the decision became pass")
    return problems


def chain_length_ft(scene: dict) -> float:
    """Length of the wall chain, gaps between walls included: no point on it is further than
    this from the meter along the walls."""
    points = [tuple(p) for wall in scene["walls"] for p in wall["baseline"]]
    return sum(math.dist(p, q) for p, q in itertools.pairwise(points))


def with_more_error(scene: dict, rules: RuleSet, extra_ft: float = 0.5) -> dict:
    """Every object, wall and the meter measured `extra_ft` less precisely than before.

    An explicit error replaces the default, and the default for walls and for tap and vlm
    objects grows by drift_per_ft with distance from the meter. So an item left on its default
    gets that default at the far end of the chain, plus `extra_ft`: at least as much as before
    everywhere.
    """
    m = copy.deepcopy(scene)
    drift = rules.errors["drift_per_ft"] * chain_length_ft(scene)
    for obj in m.get("objects", []):
        if "plus_minus_ft" not in obj:
            grows = obj["source"] in ("tap", "vlm")
            obj["plus_minus_ft"] = rules.errors[obj["source"]] + (drift if grows else 0.0)
        obj["plus_minus_ft"] += extra_ft
    for wall in m["walls"]:
        wall["plus_minus_ft"] = wall.get("plus_minus_ft", rules.errors["wall"] + drift) + extra_ft
    meter = m["meter"]
    meter["plus_minus_ft"] = meter.get("plus_minus_ft", rules.errors["meter"]) + extra_ft
    return m


def tape_to_tap(scene: dict) -> dict | None:
    """Objects measured by tape (and not given their own error) re-measured by AR tap."""
    m = copy.deepcopy(scene)
    changed = False
    for obj in m.get("objects", []):
        if obj["source"] == "tape" and "plus_minus_ft" not in obj:
            obj["source"] = "tap"
            changed = True
    return m if changed else None


def with_less_coverage(scene: dict, trim_ft: float = 0.5) -> dict | None:
    """Every observed span shortened by `trim_ft` at each end and the ground seen less far out."""
    if not scene.get("coverage", {}).get("observed"):
        return None
    m = copy.deepcopy(scene)
    kept = []
    for entry in m["coverage"]["observed"]:
        a, b = sorted(entry["span_ft"])
        if b - a <= 2 * trim_ft:
            continue
        entry["span_ft"] = [a + trim_ft, b - trim_ft]
        if "out_ft" in entry:
            entry["out_ft"] = max(0.0, entry["out_ft"] - trim_ft)
        kept.append(entry)
    m["coverage"]["observed"] = kept
    return m


def with_ground_short_of(scene: dict, rules: RuleSet, margin_ft: float = 0.1) -> dict | None:
    """Ground seen out to just short of the largest clearance radius, where any correct server
    must stop passing the check that needs it."""
    radius = max(n.radius for ns in rules.needs.values() for n in ns if n.band == "ground")
    reach = rules.depth_ft + radius - margin_ft
    grounds = [e for e in scene.get("coverage", {}).get("observed", []) if e["band"] == "ground"]
    if not any(e.get("out_ft", 0.0) > reach for e in grounds):
        return None
    m = copy.deepcopy(scene)
    for entry in m["coverage"]["observed"]:
        if entry["band"] == "ground":
            entry["out_ft"] = min(entry["out_ft"], reach)
    return m


# Further out than any clearance looks: the largest in rules.yaml is 10 ft, plus a 1.8 ft
# battery and its position error. Requested ground is added out to here, and ground seen this
# far never needs asking for again.
GROUND_FAR_FT = 40.0


def with_requests_captured(scene: dict, result: dict, out_ft: float = GROUND_FAR_FT) -> dict | None:
    """The scene as if the homeowner had shown every band the result asked for."""
    added = [
        {"band": r["band"], "span_ft": sorted(r["span_ft"])}
        | ({"out_ft": out_ft} if r["band"] == "ground" else {})
        for r in result.get("missing_evidence", [])
        if r["kind"] == "band" and "band" in r and "span_ft" in r
    ]
    if not added:
        return None
    m = copy.deepcopy(scene)
    m.setdefault("coverage", {}).setdefault("observed", []).extend(added)
    return m


def coverage_blocks(result: dict) -> bool:
    """The result names an unobserved area as a reason, so photos could change it."""
    return any(r["code"] == "unobserved_area" for r in result.get("reasons", []))


def unobserved_checks(result: dict) -> list[str]:
    return [
        c["id"]
        for c in result.get("checks", [])
        if c["outcome"] == "unsure" and c.get("unsure_cause") == "unobserved"
    ]
