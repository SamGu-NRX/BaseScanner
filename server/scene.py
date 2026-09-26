"""Turn an uploaded scene.json into plan geometry the solver can measure.

The walls are chained left to right and unrolled into one coordinate s, the distance along the
chain from the meter (negative to the left). Every straight baseline segment knows its outward
direction from its point order (scene.schema.json: points run left to right as seen from outside,
so outward is the direction turned 90 degrees clockwise viewed from above). Clearances are measured
in plan (x, z) with shapely, so two things close together round an inside corner are close even
when they are far apart in s.

What the capture observed is kept as geometry too. The unobserved part of the outdoor area near the
walls is precomputed once, so "was everything within 3 ft of this footprint seen?" is one distance.
"""

import hashlib
import itertools
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from shapely import Geometry, LineString, Point, Polygon, unary_union
from shapely.validation import explain_validity

from rules import Rules

SCHEMA_PATH = Path(__file__).resolve().parent / "schemas" / "scene.schema.json"
_VALIDATOR = Draft202012Validator(json.loads(SCHEMA_PATH.read_text()))

# Tolerance for comparing lengths in feet. Far below any measurement error; it only keeps floating
# point noise (3.3 - 0.3 != 3.0) from deciding a check.
EPS = 1e-9
# Arc resolution for the outdoor-area wedges at corners.
_ARC_STEPS = 8

Point2 = tuple[float, float]


class SceneError(ValueError):
    """The upload is not a usable scene. `path` points at the offending field."""

    def __init__(self, path: str, message: str) -> None:
        super().__init__(f"{path}: {message}")
        self.path = path
        self.message = message


def _sub(a: Point2, b: Point2) -> Point2:
    return (a[0] - b[0], a[1] - b[1])


def _norm(v: Point2) -> float:
    return math.hypot(v[0], v[1])


@dataclass(frozen=True)
class Piece:
    """A straight stretch of the chain in s: a wall segment, a gap with no wall, or an extension
    that continues an end segment past the end of the walk."""

    kind: str  # "wall", "gap" or "extension"
    wall_id: str | None
    index: int  # segment index within its wall; -1 for gaps and extensions
    a: Point2
    b: Point2
    s0: float
    s1: float
    along: Point2
    outward: Point2
    plus_minus: float

    def point(self, s: float, out: float = 0.0) -> Point2:
        t = s - self.s0
        return (
            self.a[0] + self.along[0] * t + self.outward[0] * out,
            self.a[1] + self.along[1] * t + self.outward[1] * out,
        )

    def rect(self, s_lo: float, s_hi: float, out_lo: float, out_hi: float) -> Polygon:
        return Polygon(
            [
                self.point(s_lo, out_lo),
                self.point(s_hi, out_lo),
                self.point(s_hi, out_hi),
                self.point(s_lo, out_hi),
            ]
        )

    def local(self, p: Point2) -> Point2:
        """(s, out) of a plan point relative to this piece's line."""
        d = _sub(p, self.a)
        return (
            self.s0 + d[0] * self.along[0] + d[1] * self.along[1],
            d[0] * self.outward[0] + d[1] * self.outward[1],
        )


@dataclass(frozen=True)
class SceneObject:
    index: int
    type: str
    wall_id: str
    span: tuple[float, float]
    bottom: float | None
    top: float | None
    operable: bool | None
    well: bool | None
    source: str
    plus_minus: float
    geom: Geometry
    points: tuple[Point2, ...]  # vertices used to place candidate starts near the clearance edge

    @property
    def label(self) -> str:
        return f"objects[{self.index}] {self.type}"


@dataclass(frozen=True)
class GroundPatch:
    index: int
    type: str
    polygon: Polygon
    plus_minus: float


@dataclass(frozen=True)
class Measured:
    """An overhead clearance or a facing gap over a stretch of wall."""

    index: int
    span: tuple[float, float]
    value: float
    plus_minus: float


@dataclass
class Scene:
    raw: dict[str, Any]
    input_sha256: str
    pieces: list[Piece]  # extension, walls and gaps in chain order, extension
    meter_pos: tuple[float, float, float]
    meter_plus_minus: float
    meter_piece: Piece
    objects: list[SceneObject]
    ground: list[GroundPatch]
    overheads: list[Measured]
    facing: list[Measured]
    observed: dict[str, list[tuple[float, float, float | None]]]
    end_kinds: dict[str, str]
    reach_ft: float  # how far out from the walls the outdoor area is modelled
    _cache: dict[str, Any] = field(default_factory=dict, repr=False)

    # --- chain -----------------------------------------------------------------------------------

    @property
    def walls(self) -> list[Piece]:
        return [p for p in self.pieces if p.kind == "wall"]

    @property
    def gaps(self) -> list[Piece]:
        return [p for p in self.pieces if p.kind == "gap"]

    @property
    def s_min(self) -> float:
        return self.walls[0].s0

    @property
    def s_max(self) -> float:
        return self.walls[-1].s1

    @property
    def meter_xz(self) -> Point2:
        return (self.meter_pos[0], self.meter_pos[2])

    def piece_at(self, s: float) -> Piece:
        for p in self.pieces:
            if p.s0 - EPS <= s <= p.s1 + EPS:
                return p
        return self.pieces[0] if s < self.pieces[0].s0 else self.pieces[-1]

    def point_at(self, s: float, out: float = 0.0) -> Point2:
        return self.piece_at(s).point(s, out)

    def polyline(self, s_a: float, s_b: float) -> list[Point2]:
        """Plan points along the chain from s_a to s_b (either order), corners included."""
        lo, hi = min(s_a, s_b), max(s_a, s_b)
        pts = [self.point_at(lo)]
        for p in self.pieces:
            if lo + EPS < p.s1 < hi - EPS:
                pts.append(p.b)
        pts.append(self.point_at(hi))
        return pts if s_a <= s_b else pts[::-1]

    def band_polygon(self, s_lo: float, s_hi: float, out: float) -> Geometry:
        """The ground strip in front of the chain from s_lo to s_hi, out to `out` from the wall,
        with the wedges that fill the outside of convex corners."""
        parts: list[Geometry] = []
        if s_hi - s_lo <= EPS or out <= EPS:
            return Polygon()
        inside = [p for p in self.pieces if p.s1 > s_lo + EPS and p.s0 < s_hi - EPS]
        for p in inside:
            parts.append(p.rect(max(s_lo, p.s0), min(s_hi, p.s1), 0.0, out))
        for prev, nxt in itertools.pairwise(inside):
            parts.append(_wedge(prev.b, prev.outward, nxt.outward, out))
        return unary_union(parts)

    def s_of(self, p: Point2) -> float:
        """s of the chain point nearest to a plan point."""
        best = min(self.pieces, key=lambda q: Point(p).distance(LineString([q.a, q.b])))
        return min(max(best.local(p)[0], best.s0), best.s1)

    def s_extent(self, geom: Geometry) -> tuple[float, float] | None:
        """The stretch of chain a region lies in front of."""
        if geom.is_empty:
            return None
        coords: list[Point2] = []
        for part in getattr(geom, "geoms", [geom]):
            ring = part.exterior if hasattr(part, "exterior") else part
            coords += [(x, z) for x, z in ring.coords]
        values = [self.s_of(c) for c in coords]
        return (min(values), max(values))

    def wall_line(self, s_lo: float, s_hi: float) -> Geometry:
        if s_hi - s_lo <= EPS:
            return Point(self.point_at(s_lo))
        return LineString(self.polyline(s_lo, s_hi))

    # --- coverage --------------------------------------------------------------------------------

    def observed_intervals(self, band: str) -> list[tuple[float, float]]:
        return merge_intervals([(a, b) for a, b, _ in self.observed.get(band, [])])

    def missing(self, band: str, s_lo: float, s_hi: float) -> list[tuple[float, float]]:
        """Parts of [s_lo, s_hi] not observed in a 1D band."""
        return subtract_intervals((s_lo, s_hi), self.observed_intervals(band))

    def unobserved_ground(self) -> Geometry:
        if "ground" not in self._cache:
            lo, hi = self.pieces[0].s0, self.pieces[-1].s1
            outdoor = self.band_polygon(lo, hi, self.reach_ft)
            seen = unary_union(
                [
                    self.band_polygon(a, b, out or 0.0)
                    for a, b, out in self.observed.get("ground", [])
                ]
            )
            self._cache["ground"] = outdoor.difference(seen.buffer(1e-6))
        return self._cache["ground"]

    def unobserved_wall(self) -> Geometry:
        if "wall" not in self._cache:
            lo, hi = self.pieces[0].s0, self.pieces[-1].s1
            gaps = subtract_intervals((lo, hi), self.observed_intervals("wall"))
            self._cache["wall"] = unary_union([self.wall_line(a, b) for a, b in gaps])
        return self._cache["wall"]


def merge_intervals(intervals: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for a, b in sorted(intervals):
        if out and a <= out[-1][1] + EPS:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def subtract_intervals(
    target: tuple[float, float], covered: list[tuple[float, float]]
) -> list[tuple[float, float]]:
    lo, hi = target
    missing: list[tuple[float, float]] = []
    cursor = lo
    for a, b in merge_intervals(covered):
        if b <= cursor + EPS:
            continue
        if a >= hi - EPS:
            break
        if a > cursor + EPS:
            missing.append((cursor, min(a, hi)))
        cursor = max(cursor, b)
        if cursor >= hi - EPS:
            break
    if cursor < hi - EPS:
        missing.append((cursor, hi))
    return missing


def _wedge(v: Point2, n1: Point2, n2: Point2, radius: float) -> Polygon:
    a1, a2 = math.atan2(n1[1], n1[0]), math.atan2(n2[1], n2[0])
    delta = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
    pts = [v]
    for k in range(_ARC_STEPS + 1):
        ang = a1 + delta * k / _ARC_STEPS
        # Scale up so the polygon's chords stay outside the arc.
        r = radius / math.cos(abs(delta) / (2 * _ARC_STEPS))
        pts.append((v[0] + r * math.cos(ang), v[1] + r * math.sin(ang)))
    poly = Polygon(pts)
    return poly if poly.is_valid and poly.area > EPS else Polygon()


def _outward(along: Point2) -> Point2:
    # Points run left to right seen from outside, so outward is `along` turned clockwise viewed
    # from above: (ux, uz) -> (-uz, ux).
    return (-along[1], along[0])


def _xz(point: list[float], path: str) -> Point2:
    return (float(point[0]), float(point[1]))


def _span(value: list[float], path: str) -> tuple[float, float]:
    a, b = float(value[0]), float(value[1])
    if a > b:
        raise SceneError(path, f"span_ft must be [start, end] with start <= end, got [{a}, {b}]")
    return (a, b)


def _geometry(points: list[Point2], path: str) -> Geometry:
    if len(points) == 1:
        return Point(points[0])
    if len(points) == 2:
        return LineString(points)
    poly = Polygon(points)
    if not poly.is_valid:
        raise SceneError(path, f"polygon is not simple ({explain_validity(poly)})")
    return poly


def _error(item: dict[str, Any], default: float) -> float:
    return float(item["plus_minus_ft"]) if "plus_minus_ft" in item else default


def validate_schema(raw: Any) -> None:
    errors = sorted(_VALIDATOR.iter_errors(raw), key=lambda e: list(e.absolute_path))
    if errors:
        e = errors[0]
        path = "/" + "/".join(str(p) for p in e.absolute_path)
        raise SceneError(path, e.message)


def parse_scene(raw: dict[str, Any], rules: Rules, input_bytes: bytes | None = None) -> Scene:
    """Validate against scene.schema.json, then build the unrolled chain and plan geometry."""
    validate_schema(raw)
    if input_bytes is None:
        input_bytes = json.dumps(raw, sort_keys=True, separators=(",", ":")).encode()
    errors = rules.errors
    source_error = {
        "tap": errors.tap_ft.value,
        "vlm": errors.vlm_ft.value,
        "tape": errors.tape_ft.value,
    }

    # Chain the walls. s is provisional (0 at the chain's left end) until the meter is placed.
    join_tol = rules.sweep.wall_join_ft.value
    pieces: list[Piece] = []
    wall_ids: set[str] = set()
    s = 0.0
    prev_end: Point2 | None = None
    for wi, wall in enumerate(raw["walls"]):
        wid = wall["id"]
        if wid in wall_ids:
            raise SceneError(f"/walls/{wi}/id", f"duplicate wall id {wid!r}")
        wall_ids.add(wid)
        pts = [_xz(p, f"/walls/{wi}/baseline") for p in wall["baseline"]]
        wall_err = _error(wall, errors.wall_ft.value)
        if prev_end is not None:
            gap = _norm(_sub(pts[0], prev_end))
            if gap > join_tol:
                along = (
                    (pts[0][0] - prev_end[0]) / gap,
                    (pts[0][1] - prev_end[1]) / gap,
                )
                pieces.append(
                    Piece("gap", None, -1, prev_end, pts[0], s, s + gap, along, _outward(along), 0)
                )
                s += gap
        for i in range(len(pts) - 1):
            length = _norm(_sub(pts[i + 1], pts[i]))
            if length < 1e-6:
                raise SceneError(f"/walls/{wi}/baseline/{i + 1}", "repeats the previous point")
            along = ((pts[i + 1][0] - pts[i][0]) / length, (pts[i + 1][1] - pts[i][1]) / length)
            pieces.append(
                Piece(
                    "wall",
                    wid,
                    i,
                    pts[i],
                    pts[i + 1],
                    s,
                    s + length,
                    along,
                    _outward(along),
                    wall_err,
                )
            )
            s += length
        prev_end = pts[-1]

    # Place the meter: s = 0 at its projection onto its own wall.
    meter = raw["meter"]
    if meter["wall_id"] not in wall_ids:
        raise SceneError("/meter/wall_id", f"no wall with id {meter['wall_id']!r}")
    mpos = tuple(float(v) for v in meter["pos"])
    mxz = (mpos[0], mpos[2])
    best: tuple[float, Piece, float] | None = None
    for p in pieces:
        if p.wall_id != meter["wall_id"]:
            continue
        s_local, _out = p.local(mxz)
        s_clamped = min(max(s_local, p.s0), p.s1)
        dist = _norm(_sub(mxz, p.point(s_clamped)))
        if best is None or dist < best[0]:
            best = (dist, p, s_clamped)
    assert best is not None
    max_off = rules.sweep.meter_to_wall_max_ft.value
    if best[0] > max_off:
        raise SceneError(
            "/meter/pos",
            f"the meter is {best[0]:.2f} ft from wall {meter['wall_id']!r}; "
            f"more than {max_off} ft means the scene is misaligned",
        )
    shift = best[2]
    pieces = [
        Piece(
            p.kind,
            p.wall_id,
            p.index,
            p.a,
            p.b,
            p.s0 - shift,
            p.s1 - shift,
            p.along,
            p.outward,
            p.plus_minus,
        )
        for p in pieces
    ]
    meter_piece = next(
        p
        for p in pieces
        if p.kind == "wall" and p.wall_id == best[1].wall_id and p.index == best[1].index
    )

    # How far out from the walls the outdoor area matters: the largest clearance plus the battery.
    c = rules.clearances
    reach = max(
        c.gas_ft.value, c.ac_ft.value, c.opening_ft.value, c.drive_ft.value, c.pool_ft.value
    )
    reach += rules.battery.depth_ft.value + 1.0
    first, last = pieces[0], pieces[-1]
    ext_len = reach + rules.battery.width_ft.value
    left_ext = Piece(
        "extension",
        None,
        -1,
        first.point(first.s0 - ext_len),
        first.a,
        first.s0 - ext_len,
        first.s0,
        first.along,
        first.outward,
        first.plus_minus,
    )
    right_ext = Piece(
        "extension",
        None,
        -1,
        last.b,
        last.point(last.s1 + ext_len),
        last.s1,
        last.s1 + ext_len,
        last.along,
        last.outward,
        last.plus_minus,
    )
    pieces = [left_ext, *pieces, right_ext]

    scene = Scene(
        raw=raw,
        input_sha256=hashlib.sha256(input_bytes).hexdigest(),
        pieces=pieces,
        meter_pos=mpos,  # type: ignore[arg-type]
        meter_plus_minus=_error(meter, errors.meter_ft.value),
        meter_piece=meter_piece,
        objects=[],
        ground=[],
        overheads=[],
        facing=[],
        observed={},
        end_kinds={"left": "unexplored", "right": "unexplored"},
        reach_ft=reach,
    )

    for i, obj in enumerate(raw.get("objects", [])):
        path = f"/objects/{i}"
        if obj["wall_id"] not in wall_ids:
            raise SceneError(f"{path}/wall_id", f"no wall with id {obj['wall_id']!r}")
        span = _span(obj["span_ft"], f"{path}/span_ft")
        bottom, top = obj.get("bottom_ft"), obj.get("top_ft")
        if bottom is not None and top is not None and bottom > top:
            raise SceneError(path, f"bottom_ft {bottom} is above top_ft {top}")
        if "footprint" in obj:
            pts = [_xz(p, f"{path}/footprint") for p in obj["footprint"]]
            geom = _geometry(pts, f"{path}/footprint")
        else:
            geom = scene.wall_line(*span)
            pts = [scene.point_at(span[0]), scene.point_at(span[1])]
        attrs = obj.get("attrs", {})
        scene.objects.append(
            SceneObject(
                index=i,
                type=obj["type"],
                wall_id=obj["wall_id"],
                span=span,
                bottom=None if bottom is None else float(bottom),
                top=None if top is None else float(top),
                operable=attrs.get("operable"),
                well=attrs.get("well"),
                source=obj["source"],
                plus_minus=_error(obj, source_error[obj["source"]]),
                geom=geom,
                points=tuple(pts),
            )
        )

    for i, patch in enumerate(raw.get("ground", [])):
        poly = _geometry([_xz(p, "") for p in patch["polygon"]], f"/ground/{i}/polygon")
        scene.ground.append(GroundPatch(i, patch["type"], poly, _error(patch, errors.tap_ft.value)))

    for key, target, value_key in (
        ("overheads", scene.overheads, "clearance_ft"),
        ("facing", scene.facing, "depth_ft"),
    ):
        for i, item in enumerate(raw.get(key, [])):
            if item["wall_id"] not in wall_ids:
                raise SceneError(f"/{key}/{i}/wall_id", f"no wall with id {item['wall_id']!r}")
            target.append(
                Measured(
                    i,
                    _span(item["span_ft"], f"/{key}/{i}/span_ft"),
                    float(item[value_key]),
                    _error(item, errors.mesh_ft.value),
                )
            )

    coverage = raw.get("coverage", {})
    for i, obs in enumerate(coverage.get("observed", [])):
        span = _span(obs["span_ft"], f"/coverage/observed/{i}/span_ft")
        scene.observed.setdefault(obs["band"], []).append((span[0], span[1], obs.get("out_ft")))
    for side, end in coverage.get("ends", {}).items():
        scene.end_kinds[side] = end["kind"]

    _check_orientation(scene)
    return scene


def _check_orientation(scene: Scene) -> None:
    """Cameras stand outside the house. If most keyframes sit on the inward side of the wall they
    face, the baseline points were almost certainly ordered right to left."""
    walls = scene.walls
    inward = total = 0
    for kf in scene.raw.get("keyframes", []):
        pose = kf["pose"]
        cam = (float(pose[12]), float(pose[14]))
        nearest = min(walls, key=lambda p: Point(cam).distance(LineString([p.a, p.b])))
        s_local, out = nearest.local(cam)
        if nearest.s0 <= s_local <= nearest.s1:
            total += 1
            inward += out < 0
    if total >= 3 and inward * 2 > total:
        raise SceneError(
            "/walls",
            f"{inward} of {total} keyframe cameras sit on the inward side of the wall they face; "
            "baseline points must run left to right as seen from outside",
        )
