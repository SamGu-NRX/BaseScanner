"""scene.json out: the reconstruction's wall line, coverage and measured gaps in the server's
contract (server/schemas/scene.schema.json and "What settles each check" in server/README.md on
t3/server). Feet, in the scene frame: the world with the ground at the wall at y = 0.

A scan bundle's scene is updated: the meter's wall takes the fitted line (over the union of its
fitted extent and the phone's baseline), `coverage.observed` is replaced by the occlusion-aware
coverage, and the measured facing gaps and overhead clearances are added to whatever the phone
marked. A Measure Lab session gets a new scene with the same parts.
"""

from __future__ import annotations

import copy

import numpy as np

from recon.capture import FEET, Capture
from recon.coverage import CellCoverage, measurements, observed
from recon.geometry import WallFrame

WALL_ID = "wall"


def _plan_ft(p: np.ndarray) -> list[float]:
    return [round(float(p[0]) / FEET, 4), round(float(p[2]) / FEET, 4)]


def build(
    capture: Capture, wall: WallFrame, cov: CellCoverage, plus_minus_ft: float | None
) -> dict:
    """The scene to send. For a bundle the scene frame is the bundle's own (its ground is y = 0 by
    the phone's estimate); for a session it is ARKit's world lowered to the fitted ground."""
    shift = 0.0 if capture.scene is not None else wall.ground_y
    lo, hi = wall.s_range
    if capture.scene is not None:
        doc = copy.deepcopy(capture.scene)
        wid = doc["meter"]["wall_id"]
        target = next(w for w in doc["walls"] if w["id"] == wid)
        if wall.meter_moved_m > 0.05:
            # The phone's marks were placed against a wall line the reconstruction does not have.
            doc["meter"]["pos"] = [round(float(v) / FEET, 4) for v in wall.meter]
            doc["objects"] = []
            doc["facing"] = []
            doc["overheads"] = []
        old = np.array(target["baseline"], dtype=np.float64) * FEET
        if wall.meter_moved_m <= 0.05:
            old_s = [(np.array([x, 0.0, z]) - wall.origin) @ wall.along for x, z in old]
            lo, hi = min(lo, *old_s), max(hi, *old_s)
    else:
        wid = WALL_ID
        m = wall.meter - np.array([0.0, shift, 0.0])
        doc = {
            "schema_version": "1.0",
            "meter": {"pos": [round(float(v) / FEET, 4) for v in m], "wall_id": wid},
            "walls": [{"id": wid, "baseline": []}],
            "objects": [],
            "ground": [],
            "coverage": {"ends": {"left": {"kind": "unexplored"}, "right": {"kind": "unexplored"}}},
            "keyframes": [
                {
                    "id": f.id,
                    "pose": _pose_ft(f.cam_to_world, shift),
                    "intrinsics": [round(float(v), 4) for v in f.intrinsics],
                    "w": f.width,
                    "h": f.height,
                    "img": f.image.name,
                }
                for f in capture.frames
            ],
        }
        target = doc["walls"][0]
    target["baseline"] = [_plan_ft(wall.world(s, 0.0)) for s in (lo, hi)]
    doc.setdefault("coverage", {})["observed"] = observed(cov)[:500]
    facing, overheads = measurements(cov, wid, plus_minus_ft)
    doc["facing"] = [*doc.get("facing", []), *facing]
    doc["overheads"] = [*doc.get("overheads", []), *overheads]
    return doc


def _pose_ft(T: np.ndarray, shift: float) -> list[float]:
    P = T.copy()
    P[1, 3] -= shift
    P[:3, 3] /= FEET
    return [round(float(v), 4) for v in P.T.reshape(-1)]
