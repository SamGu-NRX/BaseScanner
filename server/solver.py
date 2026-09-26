"""The placement solver: a pure function from a parsed scene and the rules to a result.

It slides the battery footprint along every straight wall segment, runs every check at each start
position, and decides. Every check follows the strict rule (plan contract C5, docs/02 Lane C):
PASS only when the margin is larger than the error, FAIL only when the value is past the threshold
by more than the error, otherwise UNSURE. An area nobody observed is never a pass.

Start positions are a 2 in grid plus every position where some check can change its outcome (an
opening's clearance edge, a coverage boundary, a ground patch edge), plus the midpoints between
those. A feasible stretch narrower than the grid step is therefore still found (golden test 12).
"""

import itertools
import math
import time
from dataclasses import dataclass, field
from typing import Any

from shapely import Geometry, Polygon, unary_union

from rules import LoadedRules, Rules, Value
from scene import EPS, Piece, Scene, SceneObject, merge_intervals
from units import format_ft_in

PASS, FAIL, UNSURE = "pass", "fail", "unsure"
_SEVERITY = {PASS: 0, UNSURE: 1, FAIL: 2}
# Areas and lengths below this are floating point slivers, not geometry.
_MEASURE_EPS = 1e-6
SCHEMA_VERSION = "1.0"


@dataclass
class Check:
    id: str
    label: str
    outcome: str
    reason: str
    rule_key: str
    rule: Value | None
    rule_source: str = ""
    rule_placeholder: bool = False
    measured: float | None = None
    plus_minus: float | None = None
    threshold: float | None = None
    comparison: str | None = None
    subject: str | None = None
    unsure_cause: str | None = None
    missing: list[tuple[str, float, float]] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "id": self.id,
            "label": self.label,
            "outcome": self.outcome,
            "reason": self.reason,
            "measured_ft": _round(self.measured),
            "plus_minus_ft": _round(self.plus_minus),
            "threshold_ft": _round(self.threshold),
            "comparison": self.comparison,
            "subject": self.subject,
            "rule": {
                "key": self.rule_key,
                "source": self.rule.source if self.rule else self.rule_source,
                "placeholder": self.rule.placeholder if self.rule else self.rule_placeholder,
            },
        }
        if self.outcome == UNSURE:
            out["unsure_cause"] = self.unsure_cause or "margin"
        return out


def _round(v: float | None) -> float | None:
    return None if v is None else round(v, 6)


def at_least(value: float, error: float, threshold: float) -> str:
    """A clearance: PASS when value - error > threshold, FAIL when value + error < threshold."""
    if value - error - threshold > EPS:
        return PASS
    if threshold - (value + error) > EPS:
        return FAIL
    return UNSURE


def reach_outcome(length: float, error: float, confident: float, maximum: float) -> str:
    """A route length: PASS when clearly under the confident reach, FAIL when clearly over the
    maximum, UNSURE in between or on either line."""
    if (length - error) - maximum > EPS:
        return FAIL
    if confident - (length + error) > EPS:
        return PASS
    return UNSURE


def worst(outcomes: list[str]) -> str:
    return max(outcomes, key=_SEVERITY.__getitem__, default=PASS)


def ft(v: float) -> str:
    return format_ft_in(abs(v)) if v >= 0 else "-" + format_ft_in(abs(v))


def where(s: float) -> str:
    if abs(s) < 1 / 24:
        return "at the meter"
    return f"{format_ft_in(abs(s))} {'left' if s < 0 else 'right'} of the meter"


@dataclass
class Route:
    outcome: str
    length: float
    plus_minus: float
    near_s: float
    polyline: list[tuple[float, float]]
    detours: list[dict[str, Any]]
    crossings: list[dict[str, Any]]


@dataclass
class Candidate:
    piece: Piece
    s0: float
    s1: float
    footprint: Polygon
    checks: list[Check]
    route: Route
    outcome: str

    def failing(self) -> list[str]:
        return [c.id for c in self.checks if c.outcome == FAIL]

    def unsure(self) -> list[str]:
        return [c.id for c in self.checks if c.outcome == UNSURE]


class Solver:
    def __init__(self, scene: Scene, loaded: LoadedRules) -> None:
        self.scene = scene
        self.loaded = loaded
        r: Rules = loaded.rules
        self.r = r
        self.W = r.battery.width_ft.value
        self.D = r.battery.depth_ft.value
        self.H = r.battery.height_ft.value
        objs = scene.objects
        self.gas = [o for o in objs if o.type == "gas_meter"]
        self.ac = [o for o in objs if o.type == "ac"]
        self.pool = [o for o in objs if o.type == "pool"]
        self.openings = [o for o in objs if o.type in r.openings.types]
        self.equipment = [o for o in objs if o.type in r.wall_equipment.types]
        self.route_objects = [
            o
            for o in objs
            if r.route.crossing.get(o.type, "allow") != "allow"  # type: ignore[call-overload]
        ]
        self.good = [g for g in scene.ground if g.type in r.ground.allowed]
        self.bad = [g for g in scene.ground if g.type not in r.ground.allowed]
        self.drives = [g for g in scene.ground if g.type in r.ground.drivable]
        self.unobserved_ground = scene.unobserved_ground()
        self.unobserved_wall = scene.unobserved_wall()
        ws = r.meter_working_space
        self.ws_span = (-ws.width_ft.value / 2, ws.width_ft.value / 2)
        self.ws_poly = scene.band_polygon(self.ws_span[0], self.ws_span[1], ws.depth_ft.value)
        self._good_union = unary_union([g.polygon for g in self.good]).buffer(1e-7)
        recorded = unary_union([g.polygon for g in scene.ground])
        outdoor = scene.band_polygon(scene.pieces[0].s0, scene.pieces[-1].s1, scene.reach_ft)
        # Outdoor ground no patch describes; opened to drop floating point slivers.
        self._unclassified = outdoor.difference(recorded).buffer(-1e-6).buffer(1e-6)
        self._ground_error = max((g.plus_minus for g in scene.ground), default=0.0)

    # --- geometry helpers ----------------------------------------------------------------------

    def footprint(self, piece: Piece, s0: float) -> Polygon:
        return piece.rect(s0, s0 + self.W, 0.0, self.D)

    def _covered(self, fp: Polygon, unobserved: Geometry, radius: float) -> bool:
        """True when nothing unobserved lies within `radius` of the footprint."""
        if unobserved.is_empty:
            return True
        if fp.distance(unobserved) > radius + _MEASURE_EPS:
            return True
        near = unobserved.intersection(fp.buffer(radius) if radius > 0 else fp)
        return (
            near.area <= _MEASURE_EPS
            if near.geom_type.endswith("Polygon")
            else (near.length <= _MEASURE_EPS)
        )

    # --- checks --------------------------------------------------------------------------------

    def check_backing(self, piece: Piece, s0: float, s1: float) -> Check:
        c = Check(
            "wall_backing",
            "Flush against one straight wall",
            PASS,
            "",
            "battery.width_ft",
            self.r.battery.width_ft,
        )
        if piece.kind != "wall" or s0 < piece.s0 - EPS or s1 > piece.s1 + EPS:
            c.outcome = FAIL
            c.reason = (
                "The footprint runs past the end of its straight wall segment (a corner, the end "
                "of the wall or a stretch with no wall), so the battery can't sit flush."
            )
            return c
        missing = self.scene.missing("wall", s0, s1)
        if missing:
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.missing = [("wall", a, b) for a, b in missing]
            c.reason = "Part of the wall behind the battery was not seen."
            return c
        c.reason = "The whole footprint backs onto one straight, observed wall segment."
        return c

    def check_ground(self, piece: Piece, fp: Polygon) -> Check:
        c = Check(
            "ground_surface",
            "Ground under the battery",
            PASS,
            "",
            "ground.allowed",
            None,
            rule_source=self.r.ground.source,
            rule_placeholder=self.r.ground.placeholder,
        )
        ew = piece.plus_minus
        for g in self.bad:
            core = g.polygon.buffer(-(g.plus_minus + ew))
            if not core.is_empty and fp.intersection(core).area > _MEASURE_EPS:
                c.outcome, c.subject = FAIL, f"ground[{g.index}] {g.type}"
                c.reason = f"The footprint stands on {g.type}, which is not an allowed surface."
                return c
        if not self._covered(fp, self.unobserved_ground, 0.0):
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.missing = self._missing_ground(fp, 0.0)
            c.reason = "The ground under the footprint was not seen."
            return c
        # A patch edge's error matters only where an allowed surface meets a disallowed or
        # unrecorded one; an edge that runs along the house wall is not a boundary at all.
        # Containment is inclusive: touching a disallowed patch along an exact edge is not
        # standing on it (golden test 01).
        on_good = self._good_union.covers(fp)
        near_bad = any(
            fp.intersection(g.polygon.buffer(g.plus_minus + ew)).area > _MEASURE_EPS
            for g in self.bad
        )
        near_unknown = (
            not self._unclassified.is_empty
            and fp.intersection(self._unclassified.buffer(self._ground_error + ew)).area
            > _MEASURE_EPS
        )
        if on_good and not near_bad and not near_unknown:
            c.reason = "The whole footprint stands on an allowed surface."
            return c
        c.outcome = UNSURE
        if not on_good and not near_bad:
            c.unsure_cause = "unknown_attribute"
            c.reason = "The ground under the footprint was seen but its surface was not recorded."
        else:
            c.unsure_cause = "margin"
            c.reason = "The footprint sits within measurement error of a surface boundary."
        return c

    def _missing_ground(self, fp: Polygon, radius: float) -> list[tuple[str, float, float]]:
        """The stretch of ground within `radius` of the footprint that nobody saw."""
        region = self.unobserved_ground.intersection(fp.buffer(radius) if radius > 0 else fp)
        extent = self.scene.s_extent(region)
        return [("ground", *extent)] if extent else []

    def _missing_band(
        self, band: str, fp: Polygon, radius: float
    ) -> list[tuple[str, float, float]]:
        if band == "ground":
            return self._missing_ground(fp, radius)
        region = self.unobserved_wall.intersection(fp.buffer(radius) if radius > 0 else fp)
        extent = self.scene.s_extent(region)
        return [("wall", *extent)] if extent else []

    def check_clearance(
        self,
        check_id: str,
        label: str,
        rule_key: str,
        rule: Value,
        piece: Piece,
        fp: Polygon,
        items: list[tuple[str, Geometry, float, bool | None]],
        band: str,
        noun: str,
    ) -> Check:
        """Minimum plan distance from the footprint to each item. `items` holds (label, geometry,
        error, counts) where counts None means an unknown attribute decides whether it applies."""
        t = rule.value
        c = Check(check_id, label, PASS, "", rule_key, rule, threshold=t, comparison="at_least")
        worst_key: tuple[int, float] | None = None
        for name, geom, err, counts in items:
            if counts is False:
                continue
            d = fp.distance(geom)
            e = err + piece.plus_minus
            outcome = at_least(d, e, t)
            cause = "margin"
            if counts is None and outcome != PASS:
                outcome, cause = UNSURE, "unknown_attribute"
            key = (_SEVERITY[outcome], -(d - e))
            if worst_key is None or key > worst_key:
                worst_key = key
                c.outcome, c.measured, c.plus_minus, c.subject = outcome, d, e, name
                c.unsure_cause = cause if outcome == UNSURE else None
        if c.outcome == FAIL:
            c.reason = (
                f"{c.subject} is {ft(c.measured or 0)} (± {ft(c.plus_minus or 0)}) from the "
                f"battery; the rule needs more than {ft(t)}."
            )
            return c
        unobserved = self.unobserved_ground if band == "ground" else self.unobserved_wall
        covered = self._covered(fp, unobserved, t)
        if c.outcome == UNSURE:
            if c.unsure_cause == "unknown_attribute":
                c.reason = (
                    f"{c.subject} is within {ft(t)} of the battery, and whether the rule applies "
                    "to it (for example whether a window opens) was not recorded."
                )
            else:
                c.reason = (
                    f"{c.subject} is {ft(c.measured or 0)} (± {ft(c.plus_minus or 0)}) from the "
                    f"battery against a {ft(t)} rule: too close to call."
                )
            if not covered:
                c.missing = self._missing_band(band, fp, t)
            return c
        if not covered:
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.missing = self._missing_band(band, fp, t)
            c.reason = (
                f"Not everything within {ft(t)} of the battery was seen, so a {noun} could "
                "hide there."
            )
            return c
        if c.measured is None:
            c.reason = f"No {noun} within {ft(t)} of the battery, and that whole area was seen."
        else:
            c.reason = (
                f"Nearest {noun} is {ft(c.measured)} (± {ft(c.plus_minus or 0)}) away, clear of "
                f"the {ft(t)} rule, and the area around the battery was seen."
            )
        return c

    def _opening_counts(self, o: SceneObject) -> bool | None:
        cfg = self.r.openings
        if o.type != "window" or o.well is True:
            return True
        exempt: bool | None = False
        if cfg.exempt_fixed_windows:
            exempt = True if o.operable is False else (None if o.operable is None else False)
        if cfg.exempt_bottom_above_ft is not None and exempt is not True:
            if o.bottom is None:
                exempt = None
            elif o.bottom > cfg.exempt_bottom_above_ft:
                exempt = True
        if exempt is True and o.well is None:
            return None
        return None if exempt is None else not exempt

    def check_along_wall(self, piece: Piece, s0: float, s1: float) -> Check:
        """Wall-mounted boxes and vents directly above the battery, measured along the wall."""
        rule = self.r.clearances.wall_equipment_ft
        t = rule.value
        c = Check(
            "wall_equipment_above",
            "No box or vent above the battery",
            PASS,
            "",
            "clearances.wall_equipment_ft",
            rule,
            threshold=t,
            comparison="at_least",
        )
        worst_key: tuple[int, float] | None = None
        for o in self.equipment:
            gap = max(o.span[0] - s1, s0 - o.span[1])
            e = o.plus_minus
            outcome = at_least(gap, e, t)
            key = (_SEVERITY[outcome], -(gap - e))
            if worst_key is None or key > worst_key:
                worst_key = key
                c.outcome, c.measured, c.plus_minus, c.subject = outcome, gap, e, o.label
        if c.outcome == FAIL:
            c.reason = f"{c.subject} is on the wall directly above the battery."
            return c
        missing = self.scene.missing("wall", s0 - t, s1 + t)
        if c.outcome == UNSURE:
            c.unsure_cause = "margin"
            c.reason = f"{c.subject} ends within measurement error of the battery's edge."
        elif missing:
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.reason = "The wall above the battery was not fully seen."
        else:
            c.reason = "Nothing is mounted on the wall above the battery."
        if missing and c.outcome == UNSURE:
            c.missing = [("wall", a, b) for a, b in missing]
        return c

    def check_meter_space(self, piece: Piece, fp: Polygon, s0: float, s1: float) -> Check:
        ws = self.r.meter_working_space
        c = Check(
            "meter_working_space",
            "Clear of the meter's working space",
            PASS,
            "",
            "meter_working_space.width_ft",
            ws.width_ft,
            threshold=0.0,
            comparison="at_least",
            subject="meter",
        )
        d = fp.distance(self.ws_poly)
        if d <= EPS:
            d = min(0.0, max(self.ws_span[0] - s1, s0 - self.ws_span[1]))
        e = self.scene.meter_plus_minus + piece.plus_minus
        c.measured, c.plus_minus = d, e
        c.outcome = at_least(d, e, 0.0)
        box = f"{ft(ws.width_ft.value)} wide by {ft(ws.depth_ft.value)} deep"
        if c.outcome == FAIL:
            c.reason = f"The battery would stand in the {box} working space in front of the meter."
        elif c.outcome == UNSURE:
            c.unsure_cause = "margin"
            c.reason = (
                f"The battery is within measurement error of the meter's {box} working space."
            )
        else:
            c.reason = f"The battery is {ft(d)} clear of the meter's {box} working space."
        return c

    def check_measured(
        self,
        check_id: str,
        label: str,
        band: str,
        entries: list,
        rule_key: str,
        rule: Value,
        s0: float,
        s1: float,
        subtract: float,
        noun: str,
    ) -> Check:
        """Facing gap or headroom: the smallest measurement over the battery's stretch of wall."""
        t = rule.value
        c = Check(check_id, label, PASS, "", rule_key, rule, threshold=t, comparison="at_least")
        over = [m for m in entries if m.span[0] < s1 - EPS and m.span[1] > s0 + EPS]
        missing = self.scene.missing(band, s0, s1)
        if over:
            m = min(over, key=lambda m: (m.value - m.plus_minus, m.index))
            c.measured, c.plus_minus = m.value - subtract, m.plus_minus
            c.subject = f"{'overheads' if band == 'overhead' else 'facing'}[{m.index}]"
            c.outcome = at_least(c.measured, c.plus_minus, t)
        val = f"{ft(c.measured or 0)} (± {ft(c.plus_minus or 0)})"
        if c.outcome == FAIL:
            c.reason = f"The {noun} is {val}; the rule needs more than {ft(t)}."
            return c
        if c.outcome == UNSURE:
            c.unsure_cause = "margin"
            c.reason = f"The {noun} is {val} against a {ft(t)} rule: too close to call."
        elif missing:
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.reason = f"The {noun} over the battery's stretch of wall was not measured everywhere."
        elif c.measured is None:
            c.reason = f"Nothing limits the {noun} over the battery's stretch of wall."
        else:
            c.reason = f"The {noun} is {val}, clear of the {ft(t)} rule."
        if missing and c.outcome == UNSURE:
            c.missing = [(band, a, b) for a, b in missing]
        return c

    def route_for(self, piece: Piece, s0: float, s1: float) -> tuple[Route, Check, Check]:
        r = self.r.route
        near = s0 if s0 > 0 else (s1 if s1 < 0 else 0.0)
        lo, hi = min(0.0, near), max(0.0, near)
        crossings: list[dict[str, Any]] = []
        detours: list[dict[str, Any]] = []
        effects: list[str] = []
        unknown: list[str] = []
        for gap in self.scene.gaps:
            if min(hi, gap.s1) - max(lo, gap.s0) > EPS:
                crossings.append(
                    {
                        "subject": "stretch with no wall",
                        "span_ft": [gap.s0, gap.s1],
                        "effect": "fail",
                    }
                )
                effects.append("fail")
        h = r.height_ft.value
        path_line = self.scene.wall_line(lo, hi) if hi - lo > EPS else None
        for o in self.route_objects:
            if min(hi, o.span[1]) - max(lo, o.span[0]) <= EPS:
                continue
            # Only something that touches the wall the cable runs along is in its way; a pipe
            # or unit standing off the wall is not (the cable passes behind it).
            if path_line is None or o.geom.distance(path_line) > o.plus_minus + _MEASURE_EPS:
                continue
            effect = r.crossing[o.type]  # type: ignore[index]
            crossings.append({"subject": o.label, "span_ft": list(o.span), "effect": effect})
            effects.append(effect)
            if effect == "detour":
                bottom = o.bottom if o.bottom is not None else 0.0
                if o.top is None:
                    unknown.append(o.label)
                    continue
                if bottom <= h + EPS and o.top >= h - EPS:
                    options = [2 * (o.top - h)]
                    if bottom > EPS:
                        options.append(2 * (h - bottom))
                    extra = min(options)
                    if extra > EPS:
                        detours.append({"subject": o.label, "extra_ft": extra})
        corners = sum(
            1
            for a, b in zip(self.scene.pieces, self.scene.pieces[1:], strict=False)
            if a.kind == "wall" and b.kind == "wall" and lo + EPS < a.s1 < hi - EPS
        )
        length = (
            (hi - lo) + corners * r.corner_allowance_ft.value + sum(d["extra_ft"] for d in detours)
        )
        e = self.scene.meter_plus_minus + piece.plus_minus
        missing = self.scene.missing("wall", lo, hi)

        path = Check(
            "route_path",
            "Cable route along the wall",
            PASS,
            "",
            "route.crossing",
            None,
            rule_source="docs/02 Lane C: the cable can't cross a door, a garage or a "
            "stretch with no wall",
            rule_placeholder=False,
        )
        if "fail" in effects:
            path.outcome = FAIL
            blockers = [x["subject"] for x in crossings if x["effect"] == "fail"]
            path.subject = blockers[0]
            path.reason = f"The cable would have to cross {', '.join(blockers)}."
        elif "review" in effects:
            path.outcome, path.unsure_cause = UNSURE, "rule_requires_review"
            path.subject = next(x["subject"] for x in crossings if x["effect"] == "review")
            path.reason = (
                f"The cable would route past {path.subject}, which the policy sends to a person."
            )
        elif unknown:
            path.outcome, path.unsure_cause = UNSURE, "unknown_attribute"
            path.subject = unknown[0]
            path.reason = (
                f"The height of {unknown[0]} was not recorded, so the detour around it is unknown."
            )
        elif missing:
            path.outcome, path.unsure_cause = UNSURE, "unobserved"
            path.missing = [("wall", a, b) for a, b in missing]
            path.reason = "Part of the wall the cable would run along was not seen."
        else:
            path.reason = "The cable runs along continuous, observed wall with nothing blocking it."

        reach = Check(
            "route_length",
            "Cable run length",
            PASS,
            "",
            "route.max_ft",
            r.max_ft,
            measured=length,
            plus_minus=e,
            threshold=r.max_ft.value,
            comparison="at_most",
        )
        reach.outcome = reach_outcome(length, e, r.confident_reach_ft.value, r.max_ft.value)
        run = f"{ft(length)} (± {ft(e)})"
        confident = r.confident_reach_ft.value
        if reach.outcome == FAIL:
            reach.reason = f"The cable run is {run}, over the {ft(r.max_ft.value)} maximum."
        elif reach.outcome == UNSURE:
            reach.unsure_cause = "margin"
            reach.reason = (
                f"The cable run is {run}: past the {ft(confident)} confident reach "
                f"or within error of the {ft(r.max_ft.value)} maximum."
            )
        else:
            reach.reason = f"The cable run is {run}, within the {ft(confident)} confident reach."
        route = Route(
            outcome=worst([path.outcome, reach.outcome]),
            length=length,
            plus_minus=e,
            near_s=near,
            polyline=self.scene.polyline(0.0, near),
            detours=detours,
            crossings=crossings,
        )
        return route, path, reach

    # --- candidates ----------------------------------------------------------------------------

    def evaluate(self, piece: Piece, s0: float) -> Candidate:
        r = self.r
        s1 = s0 + self.W
        fp = self.footprint(piece, s0)
        c = r.clearances
        checks = [
            self.check_backing(piece, s0, s1),
            self.check_ground(piece, fp),
            self.check_meter_space(piece, fp, s0, s1),
            self.check_clearance(
                "gas_clearance",
                "Distance from gas equipment",
                "clearances.gas_ft",
                c.gas_ft,
                piece,
                fp,
                [(o.label, o.geom, o.plus_minus, True) for o in self.gas],
                "ground",
                "gas meter or pipe",
            ),
            self.check_clearance(
                "ac_clearance",
                "Distance from AC units",
                "clearances.ac_ft",
                c.ac_ft,
                piece,
                fp,
                [(o.label, o.geom, o.plus_minus, True) for o in self.ac],
                "ground",
                "AC unit",
            ),
            self.check_clearance(
                "drive_clearance",
                "Distance from the driveway",
                "clearances.drive_ft",
                c.drive_ft,
                piece,
                fp,
                [
                    (f"ground[{g.index}] {g.type}", g.polygon, g.plus_minus, True)
                    for g in self.drives
                ],
                "ground",
                "drivable surface",
            ),
            self.check_clearance(
                "pool_clearance",
                "Distance from a pool",
                "clearances.pool_ft",
                c.pool_ft,
                piece,
                fp,
                [(o.label, o.geom, o.plus_minus, True) for o in self.pool],
                "ground",
                "pool",
            ),
            self.check_clearance(
                "opening_clearance",
                "Distance from doors and windows",
                "clearances.opening_ft",
                c.opening_ft,
                piece,
                fp,
                [(o.label, o.geom, o.plus_minus, self._opening_counts(o)) for o in self.openings],
                "wall",
                "door or window",
            ),
            self.check_along_wall(piece, s0, s1),
            self.check_measured(
                "facing_gap",
                "Open space in front",
                "facing",
                self.scene.facing,
                "facing.min_ft",
                r.facing.min_ft,
                s0,
                s1,
                self.D if r.facing.measured_from == "battery_front" else 0.0,
                "gap in front of the battery"
                if r.facing.measured_from == "battery_front"
                else "gap from the wall to whatever faces it",
            ),
            self.check_measured(
                "headroom",
                "Headroom above",
                "overhead",
                self.scene.overheads,
                "headroom.min_ft",
                r.headroom.min_ft,
                s0,
                s1,
                0.0,
                "headroom",
            ),
        ]
        route, path, reach = self.route_for(piece, s0, s1)
        checks += [path, reach]
        return Candidate(piece, s0, s1, fp, checks, route, worst([x.outcome for x in checks]))

    def starts(self, piece: Piece) -> list[float]:
        lo, hi = piece.s0, piece.s1 - self.W
        if hi < lo - EPS:
            return []
        hi = max(hi, lo)
        step = self.r.sweep.step_ft.value
        points = [lo + k * step for k in range(int((hi - lo) / step + EPS) + 1)] + [hi]
        W, D = self.W, self.D
        # Along the wall: every place an interval can start or stop mattering.
        boundaries = [0.0, *self.ws_span]
        for o in self.scene.objects:
            boundaries += list(o.span)
        for m in self.scene.overheads + self.scene.facing:
            boundaries += list(m.span)
        for band in self.scene.observed.values():
            for a, b, _ in band:
                boundaries += [a, b]
        for g in self.scene.gaps:
            boundaries += [g.s0, g.s1]
        offsets = {0.0}
        for o in self.equipment:
            offsets |= {o.plus_minus, -o.plus_minus}
        for b in boundaries:
            for off in offsets:
                points += [b + off, b - W - off]
        rt = self.r.route
        e_route = self.scene.meter_plus_minus + piece.plus_minus
        for limit in (rt.confident_reach_ft.value, rt.max_ft.value):
            for x in (limit - e_route, limit + e_route, limit):
                points += [x, -x - W]
        # Plan clearances: the start where the footprint is exactly the rule's distance from
        # each vertex of each object (and within error of it).
        c = self.r.clearances
        rules_by_items = [
            (c.gas_ft.value, [(p, o.plus_minus) for o in self.gas for p in o.points]),
            (c.ac_ft.value, [(p, o.plus_minus) for o in self.ac for p in o.points]),
            (c.pool_ft.value, [(p, o.plus_minus) for o in self.pool for p in o.points]),
            (c.opening_ft.value, [(p, o.plus_minus) for o in self.openings for p in o.points]),
            (
                c.drive_ft.value,
                [(p, g.plus_minus) for g in self.drives for p in g.polygon.exterior.coords],
            ),
        ]
        for g in self.scene.ground:
            for p in g.polygon.exterior.coords:
                u, _ = piece.local(p)
                for off in (
                    0.0,
                    g.plus_minus + piece.plus_minus,
                    -(g.plus_minus + piece.plus_minus),
                ):
                    points += [u + off, u - W + off]
        for t, items in rules_by_items:
            for p, err in items:
                u, v = piece.local(p)
                dv = max(0.0, v - D) if v >= 0 else -v
                for tt in (t, t + err + piece.plus_minus, t - err - piece.plus_minus):
                    if tt > dv:
                        du = math.sqrt(tt * tt - dv * dv)
                        points += [u + du, u - W - du]
        pts = sorted({round(p, 9) for p in points if lo - EPS <= p <= hi + EPS})
        pts = [min(max(p, lo), hi) for p in pts]
        mids = [(a + b) / 2 for a, b in itertools.pairwise(pts) if b - a > 1e-6]
        return sorted(set(pts) | set(mids))

    def candidates(self) -> list[Candidate]:
        out = []
        for piece in self.scene.walls:
            for s0 in self.starts(piece):
                out.append(self.evaluate(piece, s0))
        return out


def evaluate_start(
    scene: Scene, loaded: LoadedRules, s0: float, wall_id: str | None = None
) -> Candidate:
    """Evaluate one battery start position (its left edge at s0), even one that crosses a corner.
    The footprint follows the straight segment that contains s0."""
    solver = Solver(scene, loaded)
    walls = [p for p in scene.walls if wall_id is None or p.wall_id == wall_id]
    piece = next((p for p in walls if p.s0 - EPS <= s0 < p.s1 - EPS), walls[-1])
    return solver.evaluate(piece, s0)


# --- decision and result -------------------------------------------------------------------------


def _rank_pass(c: Candidate) -> tuple:
    return (c.route.length, abs((c.s0 + c.s1) / 2), c.s0)


def _rank_unsure(c: Candidate) -> tuple:
    return (len(c.unsure()), c.route.length, c.s0)


def _spot_json(solver: Solver, c: Candidate) -> dict[str, Any]:
    p = c.piece
    corners = [p.point(c.s0), p.point(c.s1), p.point(c.s1, solver.D), p.point(c.s0, solver.D)]
    center = p.point((c.s0 + c.s1) / 2, solver.D / 2)
    mx, mz = solver.scene.meter_xz
    return {
        "outcome": c.outcome,
        "wall_id": p.wall_id,
        "segment": p.index,
        "span_ft": [_round(c.s0), _round(c.s1)],
        "width_ft": _round(solver.W),
        "depth_ft": _round(solver.D),
        "height_ft": _round(solver.H),
        "footprint": [[_round(x), _round(z)] for x, z in corners],
        "center": [_round(center[0]), _round(center[1])],
        "along": [_round(p.along[0]), _round(p.along[1])],
        "outward": [_round(p.outward[0]), _round(p.outward[1])],
        "meter_offset_ft": [_round(center[0] - mx), _round(center[1] - mz)],
        "route_length_ft": _round(c.route.length),
    }


def _route_json(solver: Solver, c: Candidate) -> dict[str, Any]:
    rt = c.route
    return {
        "outcome": rt.outcome,
        "length_ft": _round(rt.length),
        "plus_minus_ft": _round(rt.plus_minus),
        "height_ft": _round(solver.r.route.height_ft.value),
        "polyline": [[_round(x), _round(z)] for x, z in rt.polyline],
        "detours": [
            {"subject": d["subject"], "extra_ft": _round(d["extra_ft"])} for d in rt.detours
        ],
        "crossings": [
            {
                "subject": x["subject"],
                "span_ft": [_round(v) for v in x["span_ft"]],
                "effect": x["effect"],
            }
            for x in rt.crossings
        ],
    }


_BAND_TEXT = {
    "wall": "wall",
    "ground": "ground in front of the wall",
    "overhead": "space overhead",
    "facing": "gap in front of the wall",
}


def _missing_json(c: Candidate) -> list[dict[str, Any]]:
    by_band: dict[str, list[tuple[float, float, str]]] = {}
    for chk in c.checks:
        for band, a, b in chk.missing:
            by_band.setdefault(band, []).append((a, b, chk.id))
    out = []
    for band, items in by_band.items():
        for a, b in merge_intervals([(a, b) for a, b, _ in items]):
            ids = sorted({i for x0, x1, i in items if x0 < b + EPS and x1 > a - EPS})
            out.append(
                {
                    "kind": "band",
                    "band": band,
                    "span_ft": [_round(a), _round(b)],
                    "checks": ids,
                    "message": f"Show the {_BAND_TEXT[band]} from {where(a)} to {where(b)}.",
                }
            )
    return out


def _sweep_json(cands: list[Candidate]) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    for c in sorted(cands, key=lambda c: c.s0):
        key = (c.piece.wall_id, c.outcome, sorted(c.failing()), sorted(c.unsure()))
        if runs and runs[-1]["_key"] == key:
            runs[-1]["start_ft"][1] = _round(c.s0)
        else:
            runs.append(
                {
                    "_key": key,
                    "wall_id": c.piece.wall_id,
                    "start_ft": [_round(c.s0), _round(c.s0)],
                    "outcome": c.outcome,
                    "failing": key[2],
                    "unsure": key[3],
                }
            )
    for run in runs:
        del run["_key"]
    return runs


def solve(scene: Scene, loaded: LoadedRules) -> dict[str, Any]:
    """Decide where the battery goes. Pure apart from the elapsed time it reports."""
    started = time.perf_counter()
    solver = Solver(scene, loaded)
    r = loaded.rules
    cands = solver.candidates()
    passes = [c for c in cands if c.outcome == PASS]
    unsures = [c for c in cands if c.outcome == UNSURE]
    fails = [c for c in cands if c.outcome == FAIL]
    auto = r.policy.auto_approve and r.policy.id is not None

    e_end = scene.meter_plus_minus
    ends: dict[str, dict[str, Any]] = {}
    for side, s_end, pt, piece in (
        ("left", scene.s_min, scene.walls[0].a, scene.walls[0]),
        ("right", scene.s_max, scene.walls[-1].b, scene.walls[-1]),
    ):
        beyond = abs(s_end) - (e_end + piece.plus_minus) - r.route.max_ft.value > EPS
        ends[side] = {
            "kind": scene.end_kinds[side],
            "s_ft": _round(s_end),
            "point": [_round(pt[0]), _round(pt[1])],
            "beyond_reach": beyond,
        }
    open_ends = [s for s, e in ends.items() if e["kind"] == "unexplored" and not e["beyond_reach"]]

    def past_end_requests() -> list[dict[str, Any]]:
        return [
            {
                "kind": "past_end",
                "side": side,
                "span_ft": [ends[side]["s_ft"], ends[side]["s_ft"]],
                "message": (
                    f"Keep walking past the {side} end of the scan ({where(ends[side]['s_ft'])}): "
                    "a spot within reach may be there."
                ),
            }
            for side in open_ends
        ]

    reasons: list[dict[str, Any]] = []
    missing: list[dict[str, Any]] = []
    spot = best = nearest = None
    policy_reason = {
        "code": "policy_not_approved",
        "message": (
            "The rules in use are not approved for automatic decisions (no policy selected, or "
            "placeholder values), so a person must confirm."
        ),
    }
    if passes:
        best = spot = min(passes, key=_rank_pass)
        reasons.append(
            {"code": "all_checks_pass", "message": "A fully observed spot passes every check."}
        )
        decision = "pass" if auto else "manual_review"
        if not auto:
            reasons.append(policy_reason)
        summary = (
            f"The battery fits {where((best.s0 + best.s1) / 2)} with a "
            f"{format_ft_in(best.route.length)} cable run"
            + (": every check passes." if auto else "; a person must confirm under these rules.")
        )
    elif unsures:
        best = spot = min(unsures, key=_rank_unsure)
        decision = "manual_review"
        ids = best.unsure()
        labels = [c.label.lower() for c in best.checks if c.outcome == UNSURE]
        reasons.append(
            {
                "code": "unsure_checks",
                "checks": ids,
                "message": "The best spot has checks nobody can settle from this scan: "
                + "; ".join(labels)
                + ".",
            }
        )
        missing = _missing_json(best)
        if missing:
            reasons.append(
                {
                    "code": "unobserved_area",
                    "checks": sorted({i for m in missing for i in m["checks"]}),
                    "message": "Part of the area the checks need was not seen.",
                }
            )
        if open_ends:
            reasons.append(
                {
                    "code": "unexplored_end",
                    "message": "The wall continues past an end of the scan within cable reach.",
                }
            )
            missing += past_end_requests()
        spot_at = where((best.s0 + best.s1) / 2)
        if any(c.unsure_cause == "unobserved" for c in best.checks if c.outcome == UNSURE):
            summary = (
                f"More views are needed around the best spot, {spot_at}: "
                f"{len(ids)} checks depend on areas the scan did not see."
            )
        else:
            summary = (
                f"A person needs to check the best spot, {spot_at}: " + "; ".join(labels) + "."
            )
    else:
        nearest = (
            min(fails, key=lambda c: (len(c.failing()), len(c.unsure()), c.route.length, c.s0))
            if fails
            else None
        )
        best = nearest
        fail_counts: dict[str, int] = {}
        for c in fails:
            for i in c.failing():
                fail_counts[i] = fail_counts.get(i, 0) + 1
        top = sorted(fail_counts, key=lambda i: -fail_counts[i])
        if cands:
            reasons.append(
                {
                    "code": "all_spots_fail",
                    "checks": top,
                    "message": "Every spot on the walls scanned fails at least one check by a "
                    "clear margin.",
                }
            )
        else:
            reasons.append(
                {
                    "code": "no_wall_segment_fits",
                    "message": "No straight stretch of scanned wall is as wide as the battery.",
                }
            )
        can_reject = auto and r.policy.allow_reject and not open_ends
        if open_ends:
            reasons.append(
                {
                    "code": "unexplored_end",
                    "message": "The wall continues past an end of the scan within cable reach.",
                }
            )
            missing = past_end_requests()
        if not auto:
            reasons.append(policy_reason)
        decision = "reject" if can_reject else "manual_review"
        if decision == "reject":
            summary = (
                "No spot within reach works: every spot fails "
                + (", ".join(t.replace("_", " ") for t in top[:3]) or "the checks")
                + "."
            )
        elif open_ends:
            summary = (
                "No spot on the scanned walls works; walk further to look for one within reach."
            )
        else:
            summary = "No spot on the scanned walls works; a person must confirm before rejecting."

    elapsed_ms = (time.perf_counter() - started) * 1000
    return {
        "schema_version": SCHEMA_VERSION,
        "decision": decision,
        "summary": summary,
        "reasons": reasons,
        "policy": {
            "id": r.policy.id,
            "version": r.policy.version,
            "auto_approve": auto,
            "sources": list(loaded.sources),
            "rules_sha256": loaded.sha256,
        },
        "spot": _spot_json(solver, spot) if spot else None,
        "route": _route_json(solver, spot) if spot else None,
        "checks": [c.to_json() for c in best.checks] if best else [],
        "nearest_considered": _spot_json(solver, nearest) if nearest else None,
        "missing_evidence": missing,
        "ends": ends,
        "sweep": _sweep_json(cands),
        "stats": {
            "candidates": len(cands),
            "pass": len(passes),
            "unsure": len(unsures),
            "fail": len(fails),
            "elapsed_ms": round(elapsed_ms, 3),
            "input_sha256": scene.input_sha256,
        },
    }
