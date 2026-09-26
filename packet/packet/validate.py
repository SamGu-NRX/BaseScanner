"""Check a capture packet against README.md and manifest.schema.json.

Each check returns a list of problems; `validate` runs them all and never stops at the first, so
one run shows everything a producer has to fix. Tolerances are stated beside each check.
"""

from __future__ import annotations

import csv
import io
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from jsonschema import Draft202012Validator
from PIL import Image

from packet.files import PacketError, PacketFiles

SCHEMA_PATH = Path(__file__).resolve().parents[1] / "manifest.schema.json"

# A float32 simd matrix written to JSON keeps about 7 significant digits, so an orthonormal
# rotation comes back orthonormal to about 1e-6; 1e-3 leaves room for any honest writer.
ROTATION_TOL = 1e-3
QUATERNION_TOL = 1e-3
# Real cameras have square pixels to well under 1%; 5% catches fx/fy swapped with a rotation.
PIXEL_ASPECT_TOL = 0.05
FOV_RANGE_DEG = (20.0, 150.0)
DEPTH_ASPECT_TOL = 0.01
# Distance walked is a sum over the trajectory; 1% (or 5 cm on a short walk) covers rounding.
DISTANCE_REL_TOL, DISTANCE_ABS_TOL = 0.01, 0.05
# A photo taken from a tracked frame must sit on the trajectory: its nearest trajectory sample
# within one frame at 60 Hz, and at the same place to a centimetre.
PHOTO_TRAJECTORY_DT, PHOTO_TRAJECTORY_DIST = 1 / 60 + 1e-6, 0.01

STREAM_COLUMNS = {
    "trajectory": ["t", "tracking", "px", "py", "pz", "qx", "qy", "qz", "qw"],
    "accelerometer": ["t", "x", "y", "z"],
    "gyroscope": ["t", "x", "y", "z"],
    "magnetometer": ["t", "x", "y", "z"],
    "device_motion": [
        "t",
        "qx",
        "qy",
        "qz",
        "qw",
        "gravity_x",
        "gravity_y",
        "gravity_z",
        "user_accel_x",
        "user_accel_y",
        "user_accel_z",
        "rotation_rate_x",
        "rotation_rate_y",
        "rotation_rate_z",
        "heading_deg",
    ],
    "barometer": ["t", "pressure_kpa", "relative_altitude_m"],
    "location": [
        "t",
        "latitude",
        "longitude",
        "altitude_m",
        "horizontal_accuracy_m",
        "vertical_accuracy_m",
    ],
    "heading": ["t", "magnetic_deg", "true_deg", "accuracy_deg"],
}
TRACKING_STATES = {"normal", "limited", "not_available"}
CONSENTED_STREAMS = ("location", "heading")
MARK_POINTS = {
    "meter": 1,
    "wall_end": 1,
    "gas_meter": 1,
    "ac": 1,
    "door": 2,
    "window": 2,
    "garage_door": 2,
    "drive_edge": 2,
    "fence": 2,
}
# ARMeshClassification raw values: none, wall, floor, ceiling, table, seat, window, door.
MESH_CLASSIFICATIONS = 8


@dataclass
class Report:
    problems: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    summary: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.problems


# --- Geometry -----------------------------------------------------------------------------------


def matrix(pose: list[float]) -> np.ndarray:
    """16 numbers column by column to a 4x4 matrix."""
    return np.asarray(pose, dtype=np.float64).reshape(4, 4).T


def rigid_problems(pose: list[float], where: str) -> list[str]:
    """A rotation (orthonormal, determinant +1), a finite translation and a [0 0 0 1] last row."""
    if len(pose) != 16 or not all(math.isfinite(v) for v in pose):
        return [f"{where}: pose must be 16 finite numbers"]
    m = matrix(pose)
    out = []
    if not np.allclose(m[3], [0, 0, 0, 1], atol=1e-9):
        out.append(f"{where}: last row is {m[3].tolist()}, not [0, 0, 0, 1] (column-major?)")
    r = m[:3, :3]
    err = float(np.abs(r.T @ r - np.eye(3)).max())
    if err > ROTATION_TOL:
        out.append(f"{where}: rotation is not orthonormal (max |RᵀR - I| = {err:.2g})")
    elif np.linalg.det(r) < 0:
        out.append(f"{where}: rotation is a reflection (determinant < 0)")
    return out


def intrinsics_problems(k: list[float], width: int, height: int, where: str) -> list[str]:
    fx, fy, cx, cy = k
    out = []
    if width <= height:
        out.append(
            f"{where}: image is {width}x{height}; photos are stored landscape (width > height)"
        )
    if fx <= 0 or fy <= 0:
        return [*out, f"{where}: focal lengths must be positive, got fx={fx}, fy={fy}"]
    if not (0 < cx < width and 0 < cy < height):
        out.append(f"{where}: principal point ({cx}, {cy}) is outside the {width}x{height} image")
    if abs(fx / fy - 1) > PIXEL_ASPECT_TOL:
        out.append(f"{where}: fx/fy = {fx / fy:.3f}; intrinsics may belong to a rotated image")
    fov = math.degrees(2 * math.atan(width / (2 * fx)))
    if not FOV_RANGE_DEG[0] <= fov <= FOV_RANGE_DEG[1]:
        out.append(
            f"{where}: horizontal field of view {fov:.1f}° is outside {FOV_RANGE_DEG}; "
            "intrinsics do not fit this image size"
        )
    return out


def increasing_problems(times: list[float], where: str) -> list[str]:
    for i in range(1, len(times)):
        if not times[i] > times[i - 1]:
            return [f"{where}: time goes from {times[i - 1]} to {times[i]} at row {i + 1}"]
    return []


# --- Files --------------------------------------------------------------------------------------


def file_problems(files: PacketFiles, ref: dict, where: str) -> list[str]:
    path = ref["path"]
    if not files.exists(path):
        return [f"{where}: {path} is missing"]
    size = files.size(path)
    if size != ref["bytes"]:
        return [f"{where}: {path} is {size} bytes, manifest says {ref['bytes']}"]
    if files.sha256(path) != ref["sha256"]:
        return [f"{where}: {path} sha256 does not match"]
    return []


def file_refs(manifest: dict) -> list[tuple[str, dict]]:
    """Every file the manifest names, with where it is named."""
    refs = []
    for i, p in enumerate(manifest.get("photos", [])):
        refs.append((f"photos[{i}].image", p["image"]))
        depth = p.get("depth")
        if depth:
            refs.append((f"photos[{i}].depth.map", depth["map"]))
            if "confidence" in depth:
                refs.append((f"photos[{i}].depth.confidence", depth["confidence"]))
    for name, s in manifest.get("streams", {}).items():
        refs.append((f"streams.{name}", s))
    if manifest.get("lidar", {}).get("mesh"):
        refs.append(("lidar.mesh", manifest["lidar"]["mesh"]))
    if manifest.get("scene"):
        refs.append(("scene", manifest["scene"]))
    return refs


# --- Photos and depth ---------------------------------------------------------------------------


def image_problems(files: PacketFiles, photo: dict, where: str) -> list[str]:
    try:
        with files.open(photo["image"]["path"]) as f, Image.open(f) as img:
            fmt, size = img.format, img.size
            orientation = img.getexif().get(0x0112)
    except (OSError, SyntaxError) as exc:
        return [f"{where}: image cannot be read: {exc}"]
    out = []
    if fmt != "JPEG":
        out.append(f"{where}: image is {fmt}, not JPEG")
    if size != (photo["width"], photo["height"]):
        out.append(
            f"{where}: image is {size[0]}x{size[1]}, manifest says "
            f"{photo['width']}x{photo['height']}"
        )
    if orientation not in (None, 1):
        out.append(f"{where}: EXIF orientation {orientation}; store the unrotated sensor image")
    return out


def depth_problems(files: PacketFiles, photo: dict, intact: set[str], where: str) -> list[str]:
    d = photo["depth"]
    w, h = d["width"], d["height"]
    out = []
    if w > photo["width"] or h > photo["height"]:
        out.append(f"{where}: depth {w}x{h} is larger than the photo")
    photo_aspect, depth_aspect = photo["width"] / photo["height"], w / h
    if abs(depth_aspect / photo_aspect - 1) > DEPTH_ASPECT_TOL:
        out.append(
            f"{where}: depth {w}x{h} does not have the photo's aspect "
            f"({photo['width']}x{photo['height']}); it cannot be aligned by scaling"
        )
    if d["map"]["bytes"] != w * h * 4:
        return [
            *out,
            f"{where}: depth map is {d['map']['bytes']} bytes, {w}x{h} float32 is {w * h * 4}",
        ]
    if d["map"]["path"] not in intact:
        return out  # reported by file_problems
    depth = np.frombuffer(files.read(d["map"]["path"]), dtype="<f4")
    if not np.isfinite(depth).all():
        out.append(f"{where}: depth has NaN or infinite values; write 0 for no measurement")
    elif (depth < 0).any():
        out.append(f"{where}: depth has negative values")
    elif (depth > 0).mean() < 0.01:
        out.append(f"{where}: depth is empty (under 1% of pixels measured)")
    if "confidence" in d:
        if d["confidence"]["bytes"] != w * h:
            out.append(
                f"{where}: confidence is {d['confidence']['bytes']} bytes, {w}x{h} uint8 is {w * h}"
            )
        elif d["confidence"]["path"] in intact:
            conf = np.frombuffer(files.read(d["confidence"]["path"]), dtype=np.uint8)
            if conf.max(initial=0) > 2:
                out.append(f"{where}: confidence values must be 0, 1 or 2")
    return out


# --- Streams ------------------------------------------------------------------------------------


def read_stream(files: PacketFiles, name: str, ref: dict) -> tuple[list[str], list[list[str]]]:
    text = io.TextIOWrapper(files.open(ref["path"]), encoding="utf-8", newline="")
    rows = list(csv.reader(text))
    return (rows[0] if rows else []), rows[1:]


def stream_problems(name: str, header: list[str], rows: list[list[str]], ref: dict) -> list[str]:
    where = f"streams.{name}"
    want = STREAM_COLUMNS[name]
    if header != want:
        return [f"{where}: header is {header}, expected {want}"]
    if len(rows) != ref["rows"]:
        return [f"{where}: {len(rows)} rows, manifest says {ref['rows']}"]
    numeric = [i for i, c in enumerate(want) if c != "tracking"]
    try:
        values = [[float(r[i]) for i in numeric] for r in rows]
    except (ValueError, IndexError) as exc:
        return [f"{where}: a row is short or not numeric ({exc})"]
    if any(not math.isfinite(v) for row in values for v in row):
        return [f"{where}: values must be finite"]
    out = increasing_problems([row[0] for row in values], where)
    if name == "trajectory":
        bad = [r[1] for r in rows if r[1] not in TRACKING_STATES]
        if bad:
            out.append(
                f"{where}: tracking must be one of {sorted(TRACKING_STATES)}, got {bad[0]!r}"
            )
        q = np.asarray([row[4:8] for row in values])
        norm_err = np.abs(np.linalg.norm(q, axis=1) - 1) if len(q) else np.zeros(0)
        if len(q) and norm_err.max() > QUATERNION_TOL:
            out.append(
                f"{where}: quaternion at row {int(norm_err.argmax()) + 1} is not unit length"
            )
    return out


def horizontal_distance(positions: np.ndarray) -> float:
    """Path length on the ground plane (meter frame x and z; y is up)."""
    if len(positions) < 2:
        return 0.0
    step = np.diff(positions[:, [0, 2]], axis=0)
    return float(np.linalg.norm(step, axis=1).sum())


# --- LiDAR --------------------------------------------------------------------------------------

MESH_HEADER = [
    "ply",
    "format binary_little_endian 1.0",
    None,  # element vertex N
    "property float x",
    "property float y",
    "property float z",
    None,  # element face M
    "property list uchar int vertex_indices",
    "property uchar classification",
    "end_header",
]


def mesh_problems(data: bytes) -> list[str]:
    """A binary PLY with exactly the layout README.md fixes, indices in range, classes 0 to 7."""
    end = data.find(b"end_header\n")
    if not data.startswith(b"ply\n") or end < 0:
        return ["lidar.mesh: not a PLY file"]
    lines = [*data[:end].decode("ascii", "replace").rstrip("\n").split("\n"), "end_header"]
    lines = [ln for ln in lines if not ln.startswith("comment")]
    if len(lines) != len(MESH_HEADER):
        return [f"lidar.mesh: header has {len(lines)} lines, expected the layout in README.md"]
    counts = {}
    for got, want in zip(lines, MESH_HEADER, strict=True):
        if want is None:
            parts = got.split()
            if len(parts) != 3 or parts[0] != "element" or parts[1] not in ("vertex", "face"):
                return [f"lidar.mesh: expected an element line, got {got!r}"]
            counts[parts[1]] = int(parts[2])
        elif got != want:
            return [f"lidar.mesh: header line {got!r}, expected {want!r}"]
    body = memoryview(data)[end + len(b"end_header\n") :]
    nv, nf = counts["vertex"], counts["face"]
    vertices = np.frombuffer(body[: nv * 12], dtype="<f4")
    # Each face: uchar count (must be 3), 3 int32 indices, uchar classification = 14 bytes.
    face_dtype = np.dtype([("n", "u1"), ("i", "<i4", 3), ("c", "u1")])
    if len(body) != nv * 12 + nf * face_dtype.itemsize:
        return [
            f"lidar.mesh: body is {len(body)} bytes, {nv} vertices and {nf} triangles need "
            f"{nv * 12 + nf * face_dtype.itemsize}"
        ]
    faces = np.frombuffer(body[nv * 12 :], dtype=face_dtype)
    out = []
    if not np.isfinite(vertices).all():
        out.append("lidar.mesh: vertices must be finite")
    if nf and (faces["n"] != 3).any():
        out.append("lidar.mesh: every face must be a triangle")
    if nf and (faces["i"].min() < 0 or faces["i"].max() >= nv):
        out.append("lidar.mesh: a face index is out of range")
    if nf and faces["c"].max() >= MESH_CLASSIFICATIONS:
        out.append("lidar.mesh: classification must be an ARMeshClassification raw value, 0 to 7")
    return out


# --- The whole packet ---------------------------------------------------------------------------


def schema_problems(manifest: dict) -> list[str]:
    schema = json.loads(SCHEMA_PATH.read_text())
    errors = sorted(Draft202012Validator(schema).iter_errors(manifest), key=lambda e: list(e.path))
    return [f"schema: {'/'.join(map(str, e.path)) or '(root)'}: {e.message}" for e in errors]


def validate(source: Path) -> Report:
    report = Report()
    try:
        files = PacketFiles(source)
        manifest = json.loads(files.read("manifest.json"))
    except (PacketError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        report.problems.append(str(exc))
        return report
    report.problems += schema_problems(manifest)
    if report.problems:
        return report  # the checks below rely on the shape the schema guarantees

    problems = report.problems
    session = manifest["session"]
    start, end = session["capture"]["started_at_uptime"], session["capture"]["ended_at_uptime"]
    if not end > start:
        problems.append("session.capture: ended_at_uptime must be after started_at_uptime")

    def in_window(t: float, where: str) -> None:
        if not start <= t <= end:
            problems.append(f"{where}: t = {t} is outside the capture [{start}, {end}]")

    problems += rigid_problems(session["meter_anchor"]["pose_in_world"], "session.meter_anchor")

    refs = file_refs(manifest)
    paths = [ref["path"] for _, ref in refs]
    dupes = sorted({p for p in paths if paths.count(p) > 1})
    if dupes:
        problems.append(f"files named more than once: {dupes[:3]}")
    # Content checks read only files whose size and hash matched, so one bad file is one problem.
    intact = set()
    for where, ref in refs:
        found = file_problems(files, ref, where)
        problems += found
        if not found:
            intact.add(ref["path"])
    unlisted = files.names() - set(paths) - {"manifest.json"}
    if unlisted:
        report.warnings.append(
            f"{len(unlisted)} files are not in the manifest: {sorted(unlisted)[:3]}"
        )

    photos = manifest["photos"]
    ids = [p["id"] for p in photos]
    if len(set(ids)) != len(ids):
        problems.append("photos: ids must be unique")
    problems += increasing_problems([p["t"] for p in photos], "photos (in manifest order)")
    for i, p in enumerate(photos):
        where = f"photos[{i}] {p['id']}"
        in_window(p["t"], where)
        problems += rigid_problems(p["pose"], where)
        problems += intrinsics_problems(p["intrinsics"], p["width"], p["height"], where)
        if p["image"]["path"] in intact:
            problems += image_problems(files, p, where)
        if "depth" in p:
            problems += depth_problems(files, p, intact, where)

    streams = manifest.get("streams", {})
    trajectory = None
    for name, ref in streams.items():
        if ref["path"] not in intact:
            continue
        header, rows = read_stream(files, name, ref)
        found = stream_problems(name, header, rows, ref)
        problems += found
        if not found and rows:
            first, last = float(rows[0][0]), float(rows[-1][0])
            if first < start or last > end:
                report.warnings.append(
                    f"streams.{name}: runs {first} to {last}, beyond the capture [{start}, {end}]"
                )
            if name == "trajectory":
                trajectory = np.asarray([[float(v) for v in (r[0], *r[2:5])] for r in rows])
    for name in CONSENTED_STREAMS:
        if name in streams and not session.get("consent", {}).get("location", False):
            problems.append(f"streams.{name} is present but session.consent.location is not true")

    walked = session["capture"].get("distance_walked_m")
    if trajectory is not None:
        measured = horizontal_distance(trajectory[:, 1:4])
        if walked is None:
            report.warnings.append("session.capture.distance_walked_m is missing")
        elif abs(walked - measured) > max(DISTANCE_ABS_TOL, DISTANCE_REL_TOL * measured):
            problems.append(
                f"session.capture.distance_walked_m is {walked}; "
                f"the trajectory walks {measured:.3f}"
            )
        for i, p in enumerate(photos):
            j = int(np.abs(trajectory[:, 0] - p["t"]).argmin())
            dt = abs(trajectory[j, 0] - p["t"])
            dist = float(np.linalg.norm(trajectory[j, 1:4] - matrix(p["pose"])[:3, 3]))
            if dt > PHOTO_TRAJECTORY_DT:
                problems.append(f"photos[{i}] {p['id']}: no trajectory sample within {dt:.3f} s")
            elif dist > PHOTO_TRAJECTORY_DIST:
                problems.append(
                    f"photos[{i}] {p['id']}: {dist:.3f} m from the trajectory at its time; "
                    "poses and trajectory disagree (frame or clock)"
                )

    lidar = manifest.get("lidar", {})
    if "mesh" in lidar and lidar["mesh"]["path"] in intact:
        problems += mesh_problems(files.read(lidar["mesh"]["path"]))
    for i, plane in enumerate(lidar.get("planes", [])):
        problems += rigid_problems(plane["pose"], f"lidar.planes[{i}]")

    photo_ids = set(ids)
    for i, m in enumerate(manifest.get("marks", [])):
        where = f"marks[{i}] {m['kind']}"
        if "t" in m:
            in_window(m["t"], where)
        if len(m["points"]) != MARK_POINTS[m["kind"]]:
            problems.append(
                f"{where}: {len(m['points'])} points, a {m['kind']} has {MARK_POINTS[m['kind']]}"
            )
        missing = [pid for pid in m.get("photo_ids", []) if pid not in photo_ids]
        if missing:
            problems.append(f"{where}: photo_ids {missing[:3]} are not photos in this packet")
        if m["kind"] == "wall_end" and not {"side", "end_kind"} <= m.keys():
            problems.append(f"{where}: a wall end needs side and end_kind")

    for i, g in enumerate(manifest.get("guidance", [])):
        where = f"guidance[{i}] {g['kind']}"
        in_window(g["t_shown"], where)
        resolved = g.get("t_resolved")
        if resolved is not None and resolved < g["t_shown"]:
            problems.append(f"{where}: resolved before it was shown")
        if g["outcome"] != "unresolved" and resolved is None:
            problems.append(f"{where}: outcome {g['outcome']} needs t_resolved")

    scene = manifest.get("scene")
    if scene and scene["path"] in intact:
        try:
            doc = json.loads(files.read(scene["path"]))
        except json.JSONDecodeError as exc:
            problems.append(f"scene: {scene['path']} is not JSON ({exc})")
        else:
            want = scene.get("schema_version")
            if want is not None and doc.get("schema_version") != want:
                problems.append(
                    f"scene: schema_version {doc.get('schema_version')!r}, manifest says {want!r}"
                )

    report.summary = {
        "packet_version": manifest["packet_version"],
        "producer": f"{session['producer']['name']} {session['producer']['version']}",
        "photos": len(photos),
        "photo_size": f"{photos[0]['width']}x{photos[0]['height']}",
        "photos_with_depth": sum("depth" in p for p in photos),
        "streams": {n: s["rows"] for n, s in streams.items()},
        "mesh": "mesh" in lidar,
        "planes": len(lidar.get("planes", [])),
        "marks": len(manifest.get("marks", [])),
        "guidance": len(manifest.get("guidance", [])),
        "seconds": round(end - start, 2),
        "distance_walked_m": walked,
    }
    return report
