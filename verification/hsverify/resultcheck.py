"""Judge a placement result (contract C2) against its scene (C1) and the decision rule (C5).

Everything here is pure: a scene and a result go in, a list of problems comes out. The
checks hold for any policy and any rule values, so they can run on every response:

- decision consistency: what `pass`, `reject` and `manual_review` each require of the rest
  of the record;
- the margin rule: a check's outcome must follow from its measurement, error and threshold
  (PASS only when the margin beats the error, and clears the review line when the check has
  one; FAIL only when past the threshold by more than the error; otherwise UNSURE);
- coverage: no battery position whose wall stretch, cable route or ground was never observed
  may pass, and nothing may ask for photos of an area the scene says was observed;
- bookkeeping: counts add up, the input hash matches what was sent, the spot's offset from
  the meter matches its centre.

Case expectations (a scene plus the outcomes geometry forces) and the mirror transform used
for the left-right symmetry check also live here.
"""

from __future__ import annotations

import copy
import hashlib
from dataclasses import dataclass
from typing import Any

import yaml
from jsonschema import Draft202012Validator

EPS = 1e-6
NUMBER_TOL_FT = 1e-5
# Spot centres and offsets are rounded by the server; a hundredth of a foot is 1/8 inch.
OFFSET_TOL_FT = 0.01
# Check ids whose PASS depends on seeing an area around the footprint, the band that area lies
# in, and the rules.yaml clearance that sets its radius. ground_surface needs only the ground
# under the battery.
CLEARANCE_CHECKS = {
    "gas_clearance": ("ground", "gas_ft"),
    "ac_clearance": ("ground", "ac_ft"),
    "drive_clearance": ("ground", "drive_ft"),
    "pool_clearance": ("ground", "pool_ft"),
    "opening_clearance": ("wall", "opening_ft"),
}


@dataclass(frozen=True)
class RuleSet:
    """What the checks here need from the server's rules.yaml at the tested ref."""

    width_ft: float
    depth_ft: float
    # check id -> (band, radius in feet around the battery footprint that must be observed)
    radii: dict[str, tuple[str, float]]
    # default error by object source, and for walls and the meter
    errors: dict[str, float]

    @classmethod
    def from_yaml(cls, text: str) -> RuleSet:
        data = yaml.safe_load(text)

        def value(*path: str) -> float:
            node: Any = data
            for key in path:
                if not isinstance(node, dict) or key not in node:
                    raise ValueError(f"rules.yaml has no {'.'.join(path)}")
                node = node[key]
            return float(node["value"] if isinstance(node, dict) else node)

        radii = {
            check: (band, value("clearances", key))
            for check, (band, key) in CLEARANCE_CHECKS.items()
        }
        radii["ground_surface"] = ("ground", 0.0)
        errors = {
            name: value("errors", f"{name}_ft") for name in ("tap", "vlm", "tape", "wall", "meter")
        }
        return cls(value("battery", "width_ft"), value("battery", "depth_ft"), radii, errors)


def schema_errors(instance: Any, schema: dict) -> list[str]:
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
    return [f"{'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message}" for e in errors]


# --- Coverage --------------------------------------------------------------------------------


def observed(scene: dict, band: str, min_out_ft: float = 0.0) -> list[tuple[float, float]]:
    """Merged observed s-intervals for a band. Ground intervals must reach `min_out_ft` out."""
    spans = []
    for entry in scene.get("coverage", {}).get("observed", []):
        if entry["band"] != band:
            continue
        if band == "ground" and entry.get("out_ft", 0.0) + EPS < min_out_ft:
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

    problems += missing_evidence_problems(result)
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


def coverage_problems(scene: dict, result: dict, rules: RuleSet) -> list[str]:
    """Missing coverage is never a pass (C5), to the radius each check's rule looks out to.

    A PASS for a check at a battery covering [lo, hi] along the wall needs that check's band
    observed over [lo - R, hi + R], and for the ground band out to the battery depth plus R. A
    sweep run that passes needs every check's area. The wall and cable route back to the meter
    must be observed too. No slack: runs list exactly the starts that were evaluated.
    """
    problems: list[str] = []
    width, depth = rules.width_ft, rules.depth_ft
    wall = observed(scene, "wall")

    def unobserved(band: str, radius: float, lo: float, hi: float) -> str | None:
        a, b = required_span(lo, hi, radius)
        seen = observed(scene, band, min_out_ft=depth + radius if band == "ground" else 0.0)
        if covers(seen, a, b):
            return None
        out = f", {depth + radius:.2f} ft out" if band == "ground" else ""
        return f"{band} [{a:.2f}, {b:.2f}]{out}"

    if "coverage" not in scene and result["decision"] == "pass":
        problems.append("decision pass for a scene with no coverage at all")

    for run in result.get("sweep", []):
        if run["outcome"] != "pass":
            continue
        lo, hi = run["start_ft"][0], run["start_ft"][1] + width
        route_lo, route_hi = min(0.0, lo), max(0.0, hi)
        if not covers(wall, route_lo, route_hi):
            problems.append(
                f"sweep pass for starts {run['start_ft']} but the wall and cable route "
                f"[{route_lo:.2f}, {route_hi:.2f}] were not all observed"
            )
        for check, (band, radius) in sorted(rules.radii.items()):
            gap = unobserved(band, radius, lo, hi)
            if gap:
                problems.append(
                    f"sweep pass for starts {run['start_ft']} but {check} needs {gap} observed"
                )

    spot = result.get("spot")
    if spot is not None:
        lo, hi = spot["span_ft"]
        for check in result.get("checks", []):
            if check["outcome"] != "pass" or check["id"] not in rules.radii:
                continue
            band, radius = rules.radii[check["id"]]
            gap = unobserved(band, radius, lo, hi)
            if gap:
                problems.append(f"check {check['id']} passes but needs {gap} observed")

    for request in result.get("missing_evidence", []):
        if request["kind"] != "band" or "span_ft" not in request or "band" not in request:
            continue
        a, b = sorted(request["span_ft"])
        if b - a > EPS and covers(observed(scene, request["band"]), a, b):
            problems.append(
                f"missing_evidence asks for {request['band']} {request['span_ft']}, "
                "which the scene lists as observed"
            )
    return problems


def missing_evidence_problems(result: dict) -> list[str]:
    """Every check left unsure because an area was unobserved has a request naming it."""
    listed = {
        c for request in result.get("missing_evidence", []) for c in request.get("checks", [])
    }
    problems = [
        f"check {c['id']} is unsure (unobserved) but no missing_evidence entry names it"
        for c in result.get("checks", [])
        if c["outcome"] == "unsure"
        and c.get("unsure_cause") == "unobserved"
        and c["id"] not in listed
    ]
    codes = {r["code"] for r in result.get("reasons", [])}
    if "unobserved_area" in codes and not result.get("missing_evidence"):
        problems.append("reason unobserved_area but missing_evidence is empty")
    return problems


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


def with_more_error(scene: dict, rules: RuleSet, extra_ft: float = 0.5) -> dict:
    """Every object, wall and the meter measured `extra_ft` less precisely than stated (or than
    its source's default)."""
    m = copy.deepcopy(scene)
    for obj in m.get("objects", []):
        base = obj.get("plus_minus_ft", rules.errors[obj["source"]])
        obj["plus_minus_ft"] = base + extra_ft
    for wall in m["walls"]:
        wall["plus_minus_ft"] = wall.get("plus_minus_ft", rules.errors["wall"]) + extra_ft
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
    radius = max(r for band, r in rules.radii.values() if band == "ground")
    reach = rules.depth_ft + radius - margin_ft
    grounds = [e for e in scene.get("coverage", {}).get("observed", []) if e["band"] == "ground"]
    if not any(e.get("out_ft", 0.0) > reach for e in grounds):
        return None
    m = copy.deepcopy(scene)
    for entry in m["coverage"]["observed"]:
        if entry["band"] == "ground":
            entry["out_ft"] = min(entry["out_ft"], reach)
    return m


def with_requests_captured(scene: dict, result: dict, out_ft: float = 40.0) -> dict | None:
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


def unobserved_checks(result: dict) -> list[str]:
    return [
        c["id"]
        for c in result.get("checks", [])
        if c["outcome"] == "unsure" and c.get("unsure_cause") == "unobserved"
    ]
