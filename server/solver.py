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
from collections.abc import Callable
from dataclasses import dataclass, field
from functools import partial
from typing import Any

from shapely import Geometry, LineString, Polygon, unary_union

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
    review_threshold: float | None = None
    comparison: str | None = None
    subject: str | None = None
    unsure_cause: str | None = None
    missing: list[tuple[str, float, float]] = field(default_factory=list)
    # Computing the exact unseen stretch is slow, so it is deferred until a result reports it.
    missing_later: Callable[[], list[tuple[str, float, float]]] | None = None

    def all_missing(self) -> list[tuple[str, float, float]]:
        return self.missing + (self.missing_later() if self.missing_later else [])

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
        if self.review_threshold is not None:
            out["review_threshold_ft"] = _round(self.review_threshold)
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
        """True when nothing unobserved lies within `radius` of the footprint. Unseen areas count
        by area (touching along an edge is not overlap) and unseen wall lines by length."""
        if unobserved.is_empty:
            return True
        if fp.distance(unobserved) > radius + _MEASURE_EPS:
            return True
        near = unobserved.intersection(fp.buffer(radius) if radius > 0 else fp)
        for part in getattr(near, "geoms", [near]):
            if part.geom_type.endswith("Polygon") and part.area > _MEASURE_EPS:
                return False
            if part.geom_type.endswith("LineString") and part.length > _MEASURE_EPS:
                return False
        return True

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
        if not self._covered(fp, self.unobserved_ground, ew):
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.missing_later = partial(self._missing_ground, fp, ew)
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

    def _unobserved(self, band: str) -> Geometry:
        return self.unobserved_ground if band == "ground" else self.unobserved_wall

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
        # The footprint itself is only placed to within the wall's error, so the area that must
        # have been seen reaches that much further.
        radius = t + piece.plus_minus
        bands = ["ground", "wall"] if band == "ground+wall" else [band]
        unseen = [b for b in bands if not self._covered(fp, self._unobserved(b), radius)]
        covered = not unseen
        band = unseen[0] if unseen else bands[0]
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
                c.missing_later = partial(self._missing_band, band, fp, radius)
            return c
        if not covered:
            c.outcome, c.unsure_cause = UNSURE, "unobserved"
            c.missing_later = partial(self._missing_band, band, fp, radius)
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
        wall_error: float,
    ) -> Check:
        """Facing gap or headroom: the smallest measurement over the battery's stretch of wall."""
        t = rule.value
        c = Check(check_id, label, PASS, "", rule_key, rule, threshold=t, comparison="at_least")
        missing = self.scene.missing(band, s0, s1)
        worst_key: tuple[int, float] | None = None
        for m in entries:
            # plus_minus is the error of the measured height or depth; where the stretch sits
            # along the wall is known to the wall's error. A measurement that lies under the
            # battery wherever that error puts it counts in full; one that only might (it
            # reaches the battery's edge within the error) can't give a clean pass, but isn't a
            # clear failure either. With exact geometry, touching end to end is not overlap.
            a, b = m.span
            possible = a - wall_error < s1 - EPS and b + wall_error > s0 + EPS
            if not possible:
                continue
            definite = a + wall_error < s1 - EPS and b - wall_error > s0 + EPS
            outcome = at_least(m.value - subtract, m.plus_minus, t)
            if not definite and outcome == FAIL:
                outcome = UNSURE
            key = (_SEVERITY[outcome], -(m.value - m.plus_minus))
            if worst_key is None or key > worst_key:
                worst_key = key
                c.outcome, c.measured, c.plus_minus = outcome, m.value - subtract, m.plus_minus
                c.subject = f"{'overheads' if band == 'overhead' else 'facing'}[{m.index}]"
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
        small_gaps: list[str] = []
        for gap in self.scene.gaps:
            if min(hi, gap.s1) - max(lo, gap.s0) > EPS:
                # A gap no longer than the two walls' errors may not be a gap at all.
                clear = (gap.s1 - gap.s0) - gap.plus_minus > EPS
                crossings.append(
                    {
                        "subject": "stretch with no wall",
                        "span_ft": [gap.s0, gap.s1],
                        "effect": "fail" if clear else "review",
                    }
                )
                if clear:
                    effects.append("fail")
                else:
                    small_gaps.append(f"a {ft(gap.s1 - gap.s0)} gap between walls")
        h = r.height_ft.value
        path_line = self.scene.wall_line(lo, hi) if hi - lo > EPS else None
        e = self.scene.meter_plus_minus + piece.plus_minus
        for o in self.route_objects:
            if path_line is None or min(hi, o.span[1]) - max(lo, o.span[0]) <= EPS:
                continue
            effect = r.crossing[o.type]  # type: ignore[index]
            # Something the cable can go round or behind is only in its way when it touches the
            # wall the cable runs along; a door or garage blocks it wherever it is drawn.
            standoff = o.geom.distance(path_line) - o.plus_minus - piece.plus_minus
            if effect in ("detour", "allow") and standoff > _MEASURE_EPS:
                continue
            crossings.append({"subject": o.label, "span_ft": list(o.span), "effect": effect})
            effects.append(effect)
            if effect == "detour":
                bottom = o.bottom if o.bottom is not None else 0.0
                if o.top is None:
                    unknown.append(o.label)
                    continue
                # Heights carry the object's error; a detour that may or may not be needed, or
                # whose size is uncertain, widens the route's error by the round trip.
                if bottom - o.plus_minus <= h + EPS and o.top + o.plus_minus >= h - EPS:
                    e += 2 * o.plus_minus
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
        elif small_gaps:
            path.outcome, path.unsure_cause = UNSURE, "margin"
            path.subject = "stretch with no wall"
            path.reason = (
                f"The cable would cross {small_gaps[0]}, no longer than the walls' own "
                "measurement error: it may be one continuous wall."
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

        outcome = reach_outcome(length, e, r.confident_reach_ft.value, r.max_ft.value)
        # threshold_ft is the maximum, the line past which the run fails (at_most). A run past
        # the confident reach but under the maximum is UNSURE, so the cited rule names both lines
        # and is a placeholder if either is.
        cr = r.confident_reach_ft
        rule = Value(
            value=r.max_ft.value,
            source=f"{r.max_ft.source}. Review past {ft(cr.value)}: {cr.source}",
            placeholder=r.max_ft.placeholder or cr.placeholder,
        )
        reach = Check(
            "route_length",
            "Cable run length",
            outcome,
            "",
            "route.max_ft",
            rule,
            measured=length,
            plus_minus=e,
            threshold=r.max_ft.value,
            review_threshold=cr.value,
            comparison="at_most",
        )
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
                # Gas meters hang on the wall as well as standing on the ground.
                "ground+wall",
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
                piece.plus_minus,
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
                piece.plus_minus,
            ),
        ]
        route, path, reach = self.route_for(piece, s0, s1)
        checks += [path, reach]
        return Candidate(piece, s0, s1, fp, checks, route, worst([x.outcome for x in checks]))

    def reach_limit(self, piece: Piece) -> float:
        """Past this |s| of its near edge a battery's route fails the maximum length whatever
        else is true: the route is never shorter than |s|, and its error is at most the meter's,
        the wall's and every possible detour's."""
        detour_err = sum(2 * o.plus_minus for o in self.route_objects)
        e_max = self.scene.meter_plus_minus + piece.plus_minus + detour_err
        return self.r.route.max_ft.value + e_max + 2 * EPS

    def starts(self, piece: Piece) -> list[float]:
        """Start positions (left edge, in s) to evaluate on one straight segment."""
        W, D = self.W, self.D
        limit = self.reach_limit(piece)
        lo, hi = max(piece.s0, -limit - W), min(piece.s1 - W, limit)
        if hi < lo - EPS:
            return []
        hi = max(hi, lo)
        step = self.r.sweep.step_ft.value
        # The grid is anchored at the meter, in left-edge and right-edge form (starts k * step
        # and k * step - W), so the start positions of a scene and of its mirror image map onto
        # each other and left and right get the same treatment.
        k_lo, k_hi = math.floor(lo / step) - 1, math.ceil((hi + W) / step) + 1
        points = [lo, hi]
        for k in range(k_lo, k_hi + 1):
            points += [k * step, k * step - W]
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
        for m in [*self.equipment, *self.scene.overheads, *self.scene.facing]:
            for e in (m.plus_minus, m.plus_minus + piece.plus_minus):
                offsets |= {e, -e}
        for b in boundaries:
            for off in offsets:
                points += [b + off, b - W - off]
        rt = self.r.route
        e_route = self.scene.meter_plus_minus + piece.plus_minus
        for line in (rt.confident_reach_ft.value, rt.max_ft.value):
            for x in (line - e_route, line + e_route, line):
                points += [x, -x - W]
        # Plan clearances: where a footprint corner's track along the wall crosses the line at
        # the rule's distance (and within error of it) from any part of an object, including
        # the middle of a slanted edge, and where it crosses a ground patch's edge.
        tracks = [LineString([piece.point(lo, v), piece.point(hi + W, v)]) for v in (0.0, D)]
        for geom, dist in self._clearance_edges(piece):
            boundary = geom.buffer(dist).boundary if dist != 0 else geom.boundary
            for track in tracks:
                if track.distance(boundary) > EPS:
                    continue
                for x, z in _coords_of(track.intersection(boundary)):
                    u = piece.local((x, z))[0]
                    points += [u, u - W]
        pts = sorted({round(p, 9) for p in points if lo - EPS <= p <= hi + EPS})
        pts = [min(max(p, lo), hi) for p in pts]
        mids = [(a + b) / 2 for a, b in itertools.pairwise(pts) if b - a > 1e-6]
        return sorted(set(pts) | set(mids))

    def _clearance_edges(self, piece: Piece) -> list[tuple[Geometry, float]]:
        """(geometry, offset) pairs whose offset outlines bound some check's outcome."""
        c = self.r.clearances
        ew = piece.plus_minus
        out: list[tuple[Geometry, float]] = []
        for t, objs in (
            (c.gas_ft.value, self.gas),
            (c.ac_ft.value, self.ac),
            (c.pool_ft.value, self.pool),
            (c.opening_ft.value, self.openings),
        ):
            for o in objs:
                for d in (t, t + o.plus_minus + ew, t - o.plus_minus - ew):
                    if d > 0:
                        out.append((o.geom, d))
        for g in self.drives:
            for d in (
                c.drive_ft.value,
                c.drive_ft.value + g.plus_minus + ew,
                c.drive_ft.value - g.plus_minus - ew,
            ):
                if d > 0:
                    out.append((g.polygon, d))
        for g in self.scene.ground:
            for d in (0.0, g.plus_minus + ew, -(g.plus_minus + ew)):
                out.append((g.polygon, d))
        return out

    def candidates(self) -> list[Candidate]:
        out = []
        for piece in self.scene.walls:
            for s0 in self.starts(piece):
                out.append(self.evaluate(piece, s0))
        return out

    def out_of_reach(self) -> list[dict[str, Any]]:
        """Sweep runs for wall that is not evaluated start by start: segments too short for the
        battery, and stretches too far along for any route to pass."""
        runs = []
        for piece in self.scene.walls:
            limit = self.reach_limit(piece)
            lo, hi = piece.s0, piece.s1 - self.W
            if hi < lo - EPS:
                # Too short for the battery: any start runs off the end of the segment.
                runs.append(
                    {
                        "wall_id": piece.wall_id,
                        "segment": piece.index,
                        "start_ft": [_round(lo), _round(lo)],
                        "outcome": FAIL,
                        "failing": ["wall_backing"],
                        "unsure": [],
                    }
                )
                continue
            for a, b in ((lo, min(hi, -limit - self.W)), (max(lo, limit), hi)):
                if b - a > EPS:
                    runs.append(
                        {
                            "wall_id": piece.wall_id,
                            "segment": piece.index,
                            "start_ft": [_round(a), _round(b)],
                            "outcome": FAIL,
                            "failing": ["route_length"],
                            "unsure": [],
                        }
                    )
        return runs


def _coords_of(geom: Geometry) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for part in getattr(geom, "geoms", [geom]):
        if not part.is_empty and hasattr(part, "coords"):
            out += [(x, z) for x, z in part.coords]
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
        for band, a, b in chk.all_missing():
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
        key = (c.piece.wall_id, c.piece.index, c.outcome, sorted(c.failing()), sorted(c.unsure()))
        if runs and runs[-1]["_key"] == key:
            runs[-1]["start_ft"][1] = _round(c.s0)
        else:
            runs.append(
                {
                    "_key": key,
                    "wall_id": c.piece.wall_id,
                    "segment": c.piece.index,
                    "start_ft": [_round(c.s0), _round(c.s0)],
                    "outcome": c.outcome,
                    "failing": key[3],
                    "unsure": key[4],
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
    far = solver.out_of_reach()
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
        if cands or far:
            if far:
                fail_counts["route_length"] = fail_counts.get("route_length", 0) + len(far)
                top = sorted(fail_counts, key=lambda i: -fail_counts[i])
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
        "sweep": sorted(
            _sweep_json(cands) + far, key=lambda run: (run["start_ft"][0], run["segment"])
        ),
        "stats": {
            "candidates": len(cands),
            "pass": len(passes),
            "unsure": len(unsures),
            "fail": len(fails),
            "elapsed_ms": round(elapsed_ms, 3),
            "input_sha256": scene.input_sha256,
        },
    }
