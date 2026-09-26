"""Judge a placement result (contract C2) against its scene (C1) and the decision rule (C5).

Everything here is pure: a scene and a result go in, a list of problems comes out. The
checks hold for any policy and any rule values, so they can run on every response:

- decision consistency: what `pass`, `reject` and `manual_review` each require of the rest
  of the record;
- the margin rule: a check's outcome must follow from its measurement, error and threshold
  (PASS only when the margin beats the error, FAIL only when past the threshold by more
  than the error, otherwise UNSURE);
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
from typing import Any

from jsonschema import Draft202012Validator

EPS = 1e-6
# Spot centres and offsets are rounded by the server; a hundredth of a foot is 1/8 inch.
OFFSET_TOL_FT = 0.01
# Sweep start ranges are sampled; a pass run may reach one 2 in step past a covered edge.
SWEEP_STEP_FT = 2 / 12
DEFAULT_BATTERY_WIDTH_FT = 31 / 12


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
    """The C5 rule for one check, when its numbers are all present."""
    m, e, t, cmp = (
        check.get(k) for k in ("measured_ft", "plus_minus_ft", "threshold_ft", "comparison")
    )
    if m is None or e is None or t is None or cmp is None:
        return None
    if cmp == "at_least":
        clear_pass, clear_fail = m - e > t + EPS, m + e < t - EPS
    else:
        clear_pass, clear_fail = m + e < t - EPS, m - e > t + EPS
    expected = "pass" if clear_pass else "fail" if clear_fail else "unsure"
    if check["outcome"] != expected:
        return (
            f"check {check['id']}: measured {m} ± {e} {cmp} {t} should be {expected}, "
            f"server says {check['outcome']}"
        )
    return None


def invariant_problems(scene: dict, result: dict, sent: bytes | None = None) -> list[str]:
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

    problems += coverage_problems(scene, result)
    return problems


def coverage_problems(scene: dict, result: dict) -> list[str]:
    """Missing coverage is never a pass (C5); photo requests only for unobserved areas."""
    problems: list[str] = []
    spot = result.get("spot")
    width = spot["width_ft"] if spot else DEFAULT_BATTERY_WIDTH_FT
    depth = spot["depth_ft"] if spot else 22 / 12
    wall = observed(scene, "wall")
    ground = observed(scene, "ground", min_out_ft=depth)

    if "coverage" not in scene and result["decision"] == "pass":
        problems.append("decision pass for a scene with no coverage at all")

    for run in result.get("sweep", []):
        if run["outcome"] != "pass":
            continue
        lo, hi = run["start_ft"][0], run["start_ft"][1] + width
        route_lo, route_hi = min(0.0, lo), max(0.0, hi)
        if not covers(wall, route_lo, route_hi, slack=SWEEP_STEP_FT):
            problems.append(
                f"sweep pass for starts {run['start_ft']} but the wall and cable route "
                f"[{route_lo:.2f}, {route_hi:.2f}] were not all observed"
            )
        if not covers(ground, lo, hi, slack=SWEEP_STEP_FT):
            problems.append(
                f"sweep pass for starts {run['start_ft']} but the ground under "
                f"[{lo:.2f}, {hi:.2f}] was not observed {depth:.2f} ft out"
            )

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
        if not runs:
            problems.append(f"no sweep run overlaps {rule['wall_id']} starts ({a}, {b})")
        for run in runs:
            if run["outcome"] != rule["outcome"]:
                problems.append(
                    f"sweep {run['wall_id']} starts {run['start_ft']} is {run['outcome']}, "
                    f"expected {rule['outcome']}"
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
