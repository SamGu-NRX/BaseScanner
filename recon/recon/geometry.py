"""Wall and ground geometry fitted to the reconstruction, and the meter's wall frame.

The ground is a least-squares plane through the reconstruction's upward-facing surface near the
phone's ground (or its lowest broad surface). Walls are vertical planes: straight lines in plan
through the reconstruction's vertical surface between 0.3 and 2 m above the ground, found by
repeated RANSAC. The wall the phone marked is the fitted line nearest its line; without one, the
wall is the stretch the most frames see.

Wall frame (the app's `WallGeometry`): `s` meters along the wall from the meter, positive to the
right for someone facing the wall; `out` meters from the wall toward the homeowner; height above
the ground. along = cross(-outward, up).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from recon.capture import UP, Capture
from recon.fusion import Mesh

WALL_BAND_M = (0.3, 2.0)
LINE_TOL_M = 0.06  # walls step by several cm (pilasters, trim); a tapped wall line is off by more
MIN_STRETCH_M = 1.5
GAP_M = 1.0  # doors and glass return no depth but are part of the wall
METER_HEIGHT_M = 1.5


@dataclass(frozen=True)
class Ground:
    y: float  # height at the wall's foot
    normal: np.ndarray
    rms_m: float
    points: int


@dataclass(frozen=True)
class WallLine:
    foot: np.ndarray  # a point on the wall's foot (y = ground)
    along: np.ndarray
    outward: np.ndarray
    extent: tuple[float, float]  # t along `along` from `foot`, where the fitted surface is
    rms_m: float
    points: int


@dataclass(frozen=True)
class WallFrame:
    meter: np.ndarray  # on the wall face
    along: np.ndarray
    outward: np.ndarray
    ground_y: float
    s_range: tuple[float, float]  # the fitted wall's extent in s
    meter_moved_m: float = 0.0  # how far the phone's meter was moved onto the fitted wall face

    @property
    def origin(self) -> np.ndarray:
        return np.array([self.meter[0], self.ground_y, self.meter[2]])

    def world(self, s, height, out=0.0) -> np.ndarray:
        s, height, out = np.broadcast_arrays(
            np.asarray(s, float), np.asarray(height, float), np.asarray(out, float)
        )
        return (
            self.origin
            + s[..., None] * self.along
            + out[..., None] * self.outward
            + height[..., None] * UP
        )

    def local(self, points: np.ndarray) -> np.ndarray:
        """(s, height, out) of world points."""
        d = points - self.origin
        return np.stack([d @ self.along, d[..., 1], d @ self.outward], axis=-1)


def fit_ground(mesh: Mesh, hint_y: float | None) -> Ground:
    up = mesh.normals @ UP > 0.9
    y = mesh.vertices[:, 1]
    cand = mesh.vertices[up]
    if hint_y is not None:
        cand = cand[np.abs(cand[:, 1] - hint_y) < 0.3]
    else:
        # The lowest broad surface: the 10th percentile of upward-facing heights, +-0.3 m.
        base = np.percentile(y[up], 10) if up.any() else np.percentile(y, 5)
        cand = cand[np.abs(cand[:, 1] - base) < 0.3]
    if len(cand) < 50:
        raise RuntimeError(
            f"only {len(cand)} ground points in the reconstruction; "
            "the photos need to show the ground"
        )
    for _ in range(3):  # least squares, then drop points more than 3 RMS off and refit
        c = cand.mean(axis=0)
        n = np.linalg.svd(cand - c, full_matrices=False)[2][2]
        n = n if n[1] > 0 else -n
        r = (cand - c) @ n
        rms = float(np.sqrt(np.mean(r**2)))
        cand = cand[np.abs(r) <= max(3 * rms, 0.02)]
    return Ground(float(np.median(cand[:, 1])), n, rms, len(cand))


def _runs(t: np.ndarray, gap: float, min_length: float) -> list[tuple[float, float]]:
    t = np.sort(t)
    if len(t) == 0:
        return []
    breaks = np.flatnonzero(np.diff(t) > gap)
    starts, ends = np.r_[0, breaks + 1], np.r_[breaks, len(t) - 1]
    return [
        (float(t[i]), float(t[j]))
        for i, j in zip(starts, ends, strict=True)
        if t[j] - t[i] >= min_length
    ]


def wall_lines(
    mesh: Mesh, ground_y: float, cameras: np.ndarray, rng: np.random.Generator
) -> list[WallLine]:
    """Straight wall stretches in the reconstruction, each with its outward side toward the
    cameras that saw it."""
    v = mesh.vertices
    h = v[:, 1] - ground_y
    vertical = (np.abs(mesh.normals @ UP) < 0.3) & (h > WALL_BAND_M[0]) & (h < WALL_BAND_M[1])
    plan = np.unique(np.floor(v[vertical][:, [0, 2]] / 0.05), axis=0) * 0.05 + 0.025
    lines, remaining = [], plan
    for _ in range(15):
        if len(remaining) < 100:
            break
        best = None
        for _ in range(300):
            p, q = remaining[rng.choice(len(remaining), 2, replace=False)]
            d = q - p
            if np.linalg.norm(d) < 0.5:
                continue
            n = np.array([-d[1], d[0]]) / np.linalg.norm(d)
            inl = np.abs((remaining - p) @ n) < LINE_TOL_M
            if best is None or inl.sum() > best.sum():
                best = inl
        if best is None:
            break
        pts = remaining[best]
        c = pts.mean(axis=0)
        d2 = np.linalg.svd(pts - c, full_matrices=False)[2][0]
        n2 = np.array([-d2[1], d2[0]])
        rms = float(np.sqrt(np.mean(((pts - c) @ n2) ** 2)))
        t = (pts - c) @ d2
        for lo, hi in _runs(t, GAP_M, MIN_STRETCH_M):
            along = np.array([d2[0], 0.0, d2[1]])
            outward = np.array([-along[2], 0.0, along[0]])
            foot = np.array([c[0], ground_y, c[1]])
            mid = foot + along * (lo + hi) / 2
            if np.median((cameras - mid) @ outward) < 0:  # outward faces the cameras
                along, outward, lo, hi = -along, -outward, -hi, -lo
            lines.append(WallLine(foot, along, outward, (lo, hi), rms, int(best.sum())))
        remaining = remaining[~best]
    return lines


MATCH_ANGLE_DEG = 25
MATCH_OFFSET_M = 0.6  # a tapped wall line is within a few inches of the wall; 0.6 m is generous
METER_MOVE_LIMIT_M = 0.9  # the server refuses a meter over 3 ft from its wall


class WallMismatch(RuntimeError):
    """The phone's wall has no reconstructed surface behind it."""


def frames_seeing(line: WallLine, frames) -> int:
    """How many frames see at least 1 m of the line at 1 m up, within range and in frame."""
    ts = np.arange(line.extent[0], line.extent[1], 0.2)
    pts = line.foot + ts[:, None] * line.along + UP * 1.0
    count = 0
    for f in frames:
        p = (pts - f.center) @ f.cam_to_world[:3, :3]
        z = -p[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = f.intrinsics[2] + f.intrinsics[0] * p[:, 0] / z
            v = f.intrinsics[3] - f.intrinsics[1] * p[:, 1] / z
        inside = (z > 0.1) & (z <= 6.0) & (u >= 0) & (u <= f.width) & (v >= 0) & (v <= f.height)
        count += int(inside.sum() >= 5)
    return count


def choose_wall(lines: list[WallLine], capture: Capture, move_meter: bool) -> WallLine:
    """The line matching the phone's wall (within 25 degrees and 0.6 m of it). With no match this
    refuses, since the homeowner's wall and meter would be silently replaced, unless `move_meter`
    allows the most-seen wall. Without a phone wall, the most-seen wall."""
    if not lines:
        raise RuntimeError("no straight vertical wall found in the reconstruction")
    most_seen = max(
        lines,
        key=lambda line: (frames_seeing(line, capture.frames), line.extent[1] - line.extent[0]),
    )
    hint = capture.wall
    if hint is None:
        return most_seen

    def offset(line: WallLine) -> float:
        parallel = abs(line.along @ hint.along) > np.cos(np.radians(MATCH_ANGLE_DEG))
        return abs((hint.point - line.foot) @ line.outward) if parallel else np.inf

    best = min(lines, key=offset)
    if offset(best) <= MATCH_OFFSET_M:
        return best
    nearest = offset(best) / 0.3048
    msg = (
        f"no reconstructed wall lies along the phone's wall line (the nearest parallel one is "
        f"{nearest:.1f} ft away)"
    )
    if not move_meter:
        raise WallMismatch(f"{msg}; rerun with --move-meter to use the most-seen wall instead")
    capture.notes.append(f"{msg}: the meter was moved onto the most-seen wall (--move-meter)")
    return most_seen


def wall_frame(line: WallLine, capture: Capture, ground_y: float, move_meter: bool) -> WallFrame:
    """The meter's frame on the fitted wall: the phone's meter moved onto the fitted wall face,
    which must be within 3 ft unless `move_meter`; without one, a meter assumed mid-stretch,
    1.5 m up, and said so."""
    if capture.meter is not None:
        t = (capture.meter - line.foot) @ line.along
        move = abs((capture.meter - line.foot) @ line.outward)
        if move > METER_MOVE_LIMIT_M and not move_meter:
            raise WallMismatch(
                f"the phone's meter is {move / 0.3048:.1f} ft off the reconstructed wall; "
                "rerun with --move-meter to move it onto the wall"
            )
        if move > METER_MOVE_LIMIT_M:  # moved: keep it on the stretch that was reconstructed
            t = float(np.clip(t, *line.extent))
        meter = line.foot + line.along * t
        meter[1] = capture.meter[1]
        moved = float(np.linalg.norm((meter - capture.meter)[[0, 2]]))
    else:
        t = sum(line.extent) / 2
        meter = line.foot + line.along * t + UP * METER_HEIGHT_M
        moved = 0.0
        capture.notes.append(
            "the capture marks no electric meter: one is assumed mid-wall, 1.5 m up, so the "
            "placement is a demonstration, not an answer for this house"
        )
    # A meter past the reconstructed end of its wall extends the wall to it.
    lo, hi = min(line.extent[0] - t, 0.0), max(line.extent[1] - t, 0.0)
    return WallFrame(meter, line.along, line.outward, ground_y, (lo, hi), moved)
