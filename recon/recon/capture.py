"""A capture: posed photos, optional LiDAR depth, and whatever the phone marked, in one form.

Every input is adapted here and nowhere else. The internal form:
- world: ARKit's `.gravity` frame, meters, +y up. For the app's scan bundle it is the scene frame
  in meters, so the ground at the wall is y = 0; for a Measure Lab session it is ARKit's own world.
- camera: ARKit axes (+x right, +y up in the unrotated sensor image, looking along -z);
  `cam_to_world` is 4x4.
- intrinsics: fx, fy, cx, cy in pixels of that image, with (0, 0) the image's top-left corner.

Readers:
- the app's scan bundle (`shareableScan` on t3/ios-mvf): `scene.json` (server/schemas/
  scene.schema.json, feet) and the keyframe JPEGs it names, as a folder or zip;
- a Measure Lab session, format 2 (experiments/measure-lab/README.md on t3/measure-lab), as a
  folder or zip. The ADVIO replay is one.

LiDAR depth, when a keyframe carries it, uses Measure Lab's layout: `depth: {file, confidenceFile,
w, h}`, Float32 meters and UInt8 confidence (0 low, 1 medium, 2 high), row-major, in the
keyframe's unrotated orientation.
"""

from __future__ import annotations

import hashlib
import json
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

FEET = 0.3048
UP = np.array([0.0, 1.0, 0.0])


@dataclass(frozen=True)
class LidarDepth:
    file: Path
    confidence: Path | None
    width: int
    height: int


@dataclass(frozen=True)
class Frame:
    id: str
    image: Path
    width: int
    height: int
    intrinsics: np.ndarray  # fx, fy, cx, cy
    cam_to_world: np.ndarray  # 4x4, meters, ARKit camera axes
    lidar: LidarDepth | None = None

    @property
    def center(self) -> np.ndarray:
        return self.cam_to_world[:3, 3]


@dataclass(frozen=True)
class WallHint:
    """A wall line the phone marked: a point on its foot, and horizontal unit vectors."""

    point: np.ndarray
    along: np.ndarray
    outward: np.ndarray


@dataclass
class Capture:
    source: str  # "scan-bundle" or "measure-lab"
    root: Path
    frames: list[Frame]
    ground_y: float | None  # world y of the ground at the wall, when the phone knows it
    meter: np.ndarray | None  # world position of the electric meter
    wall: WallHint | None
    scene: dict | None = None  # the bundle's scene.json, updated in place of rebuilt
    notes: list[str] = field(default_factory=list)

    @property
    def has_lidar(self) -> bool:
        return bool(self.frames) and all(f.lidar is not None for f in self.frames)


ROTATION_TOL = 1e-2  # scene.json rounds poses to 4 decimals; anything further off is not a pose


def column_major(pose: list[float]) -> np.ndarray:
    """A 4x4 from 16 column-major numbers, its rotation snapped to the nearest proper rotation.
    Exported poses are rounded, so their rotations are orthonormal only to about 1e-4."""
    if len(pose) != 16:
        raise ValueError(f"pose has {len(pose)} numbers, expected 16 (column-major 4x4)")
    T = np.array(pose, dtype=np.float64).reshape(4, 4).T
    u, _, vt = np.linalg.svd(T[:3, :3])
    R = u @ vt
    if np.linalg.det(R) < 0 or np.abs(R - T[:3, :3]).max() > ROTATION_TOL:
        raise ValueError(f"pose rotation is not a rotation: {T[:3, :3].round(4).tolist()}")
    T[:3, :3] = R
    return T


def outward_of(along: np.ndarray) -> np.ndarray:
    """scene.schema.json: a baseline's outward side is its direction turned 90 degrees clockwise
    in plan seen from above (+y). In (x, z) that takes (ax, az) to (-az, ax)."""
    return np.array([-along[2], 0.0, along[0]])


def unpack(path: Path, work: Path) -> Path:
    """A folder as is; a zip extracted once under `work`, keyed by its sha256."""
    if path.is_dir():
        return path
    digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
    out = work / "bundles" / digest
    if not out.exists():
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if not n.startswith("__MACOSX/")]
            for n in names:
                if n.startswith("/") or ".." in Path(n).parts:
                    raise ValueError(f"{path}: unsafe entry {n!r}")
            z.extractall(out, members=names)
    return out


def _find(root: Path, name: str) -> Path | None:
    hits = [p for p in root.rglob(name) if "__MACOSX" not in p.parts]
    if len(hits) > 1:
        raise ValueError(f"{root}: {len(hits)} copies of {name}; expected one")
    return hits[0] if hits else None


def load(path: Path, work: Path) -> Capture:
    root = unpack(path, work)
    scene = _find(root, "scene.json")
    session = _find(root, "session.json")
    if scene is not None:
        return _scan_bundle(scene.parent, json.loads(scene.read_text()))
    if session is not None:
        doc = json.loads(session.read_text())
        if doc.get("format") != "measure-lab-session" or doc.get("formatVersion") != 2:
            raise ValueError(f"{session}: not a Measure Lab session, format 2")
        return _measure_lab(session.parent, doc)
    raise ValueError(f"{path}: neither scene.json (app scan bundle) nor session.json (Measure Lab)")


def _lidar(root: Path, kf: dict) -> LidarDepth | None:
    d = kf.get("depth")
    if not d:
        return None
    conf = d.get("confidenceFile")
    return LidarDepth(root / d["file"], root / conf if conf else None, int(d["w"]), int(d["h"]))


def _scan_bundle(root: Path, scene: dict) -> Capture:
    frames = []
    for kf in scene.get("keyframes", []):
        T = column_major(kf["pose"])
        T[:3, 3] *= FEET  # scene frame translations are feet
        frames.append(
            Frame(
                kf["id"],
                root / kf["img"],
                int(kf["w"]),
                int(kf["h"]),
                np.array(kf["intrinsics"], dtype=np.float64),
                T,
                _lidar(root, kf),
            )
        )
    if not frames:
        raise ValueError(f"{root}/scene.json has no keyframes: nothing to reconstruct")
    meter = np.array(scene["meter"]["pos"], dtype=np.float64) * FEET
    wall = None
    walls = {w["id"]: w for w in scene["walls"]}
    base = np.array(walls[scene["meter"]["wall_id"]]["baseline"], dtype=np.float64) * FEET
    along = np.array([base[-1, 0] - base[0, 0], 0.0, base[-1, 1] - base[0, 1]])
    along /= np.linalg.norm(along)
    wall = WallHint(np.array([base[0, 0], 0.0, base[0, 1]]), along, outward_of(along))
    return Capture("scan-bundle", root, frames, 0.0, meter, wall, scene)


def _measure_lab(root: Path, doc: dict) -> Capture:
    frames = [
        Frame(
            kf["id"],
            root / kf["img"],
            int(kf["w"]),
            int(kf["h"]),
            np.array(kf["intrinsics"], dtype=np.float64),
            column_major(kf["pose"]),
            _lidar(root, kf),
        )
        for kf in sorted(doc["keyframes"], key=lambda k: k["id"])
        if (root / kf["img"]).exists()  # a JPEG still being written at share time has no entry
    ]
    points = {p["id"]: np.array(p["position"], dtype=np.float64) for p in doc.get("points", [])}
    wall, ground = None, None
    for w in doc.get("walls", []):
        a, b = (points[c] for c in w["contacts"][:2])
        along = np.array([b[0] - a[0], 0.0, b[2] - a[2]])
        along /= np.linalg.norm(along)
        out = outward_of(along)
        cam = np.array(w["cameraPosition"], dtype=np.float64)
        if (cam - a) @ out < 0:  # the camera stood in front of the wall
            along, out = -along, -out
        wall, ground = WallHint(a.copy(), along, out), float((a[1] + b[1]) / 2)
    notes = []
    if wall is None:
        notes.append("the session marks no wall: the wall is found in the reconstruction")
    return Capture("measure-lab", root, frames, ground, None, wall, None, notes)
