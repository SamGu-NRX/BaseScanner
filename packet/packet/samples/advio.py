"""A sample packet from ADVIO sequence 20 (outdoor, iPhone 6s): photos, 60 Hz ARKit trajectory,
and the phone's own accelerometer, gyroscope, magnetometer, barometer and location streams.

The photos are the evals lane's replay keyframes (`experiments/evals/evals/replay.py` on
t3/evals): ADVIO video frames at their native 1280 x 720, undistorted to the pinhole model with
ADVIO's calibration. Poses and streams come straight from the sequence's CSVs over the same window.

    uv run python -m packet.samples.advio \
        --replay ~/house-scanning-data/replays/advio-20-0040-0075 \
        --advio ~/house-scanning-data/evals/advio/advio-20 \
        --out ~/house-scanning-data/packets/advio-20-0040-0075
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from PIL import Image

from packet.validate import horizontal_distance
from packet.write import (
    PACKET_VERSION,
    SHARPNESS_METHOD,
    PacketWriter,
    column_major,
    from_column_major,
    meter_frame,
    sharpness,
    trajectory_row,
)

# ADVIO's arkit.csv holds the portrait device orientation; the landscape camera the images come
# from is that frame turned about z (image right = device -y, image up = device +x). Same matrix
# as DEVICE_TO_LANDSCAPE_CAMERA in experiments/evals/evals/camera.py, which the replay used.
DEVICE_TO_LANDSCAPE_CAMERA = np.array([[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
# The app's replay assumes the wall this far to the side the camera faces (ScanKit replay log).
WALL_OFFSET_M = 2.25
# ADVIO's replay keyframes match arkit.csv rows exactly; allow float32-level rounding only.
POSE_MATCH_TOL = 1e-4


def quat_wxyz_to_matrix(q: np.ndarray) -> np.ndarray:
    q = q / np.linalg.norm(q, axis=-1, keepdims=True)
    w, x, y, z = q[..., 0], q[..., 1], q[..., 2], q[..., 3]
    r = np.empty((*q.shape[:-1], 3, 3))
    r[..., 0, 0] = 1 - 2 * (y * y + z * z)
    r[..., 0, 1] = 2 * (x * y - w * z)
    r[..., 0, 2] = 2 * (x * z + w * y)
    r[..., 1, 0] = 2 * (x * y + w * z)
    r[..., 1, 1] = 1 - 2 * (x * x + z * z)
    r[..., 1, 2] = 2 * (y * z - w * x)
    r[..., 2, 0] = 2 * (x * z - w * y)
    r[..., 2, 1] = 2 * (y * z + w * x)
    r[..., 2, 2] = 1 - 2 * (x * x + y * y)
    return r


def read_csv(path: Path) -> np.ndarray:
    with path.open() as f:
        return np.array([[float(v) for v in row] for row in csv.reader(f) if row])


def world_poses(arkit: np.ndarray) -> np.ndarray:
    """Camera-to-world poses (ARKit camera axes, landscape image) from arkit.csv rows."""
    r = quat_wxyz_to_matrix(arkit[:, 4:8])
    poses = np.tile(np.eye(4), (len(arkit), 1, 1))
    poses[:, :3, :3] = r @ DEVICE_TO_LANDSCAPE_CAMERA
    poses[:, :3, 3] = arkit[:, 1:4]
    return poses


def assumed_meter(poses: np.ndarray) -> np.ndarray:
    """Meter-to-world pose by the app replay's rule: the wall is vertical, parallel to the walk,
    WALL_OFFSET_M to the side the camera faces; the meter is level with the camera, opposite the
    middle of the walk."""
    pos = poses[:, :3, 3]
    horizontal = pos[:, [0, 2]] - pos[:, [0, 2]].mean(axis=0)
    along2 = np.linalg.svd(horizontal, full_matrices=False)[2][0]
    along = np.array([along2[0], 0.0, along2[1]])
    looking = -poses[:, :3, 2].mean(axis=0)  # cameras look along their -z
    side = looking - along * (looking @ along)
    side[1] = 0
    side /= np.linalg.norm(side)
    middle = pos[len(pos) // 2]
    meter = middle + WALL_OFFSET_M * side
    # The meter frame's +z points out of the wall, toward the camera: -side. Its +x is then
    # y x z; flip `along` if needed so the frame is right-handed with that z.
    if np.cross([0.0, 1.0, 0.0], -side) @ along < 0:
        along = -along
    return meter_frame(meter, along)


def build(replay: Path, advio: Path, out: Path) -> Path:
    session = json.loads((replay / "session.json").read_text())
    start, end = session["provenance"]["secondsInSequence"]
    arkit = read_csv(advio / "iphone" / "arkit.csv")
    keep = (arkit[:, 0] >= start) & (arkit[:, 0] <= end) & (np.abs(arkit[:, 1:4]).sum(axis=1) > 0)
    arkit = arkit[keep]
    world = world_poses(arkit)
    anchor = assumed_meter(world)
    to_meter = np.linalg.inv(anchor)
    in_meter = to_meter @ world

    w = PacketWriter(out)
    photos = []
    for kf in session["keyframes"]:
        i = int(np.abs(arkit[:, 0] - kf["timestamp"]).argmin())
        replay_pose = from_column_major(kf["pose"])
        if np.abs(replay_pose - world[i]).max() > POSE_MATCH_TOL:
            raise ValueError(f"{kf['id']}: replay pose differs from arkit.csv at t={arkit[i, 0]}")
        pid = f"p{int(kf['id'][1:]):05d}"
        source = replay / kf["img"]
        with Image.open(source) as img:
            score = sharpness(img)
        photos.append(
            {
                "id": pid,
                "image": w.add_file(f"photos/{pid}.jpg", source),
                "width": kf["w"],
                "height": kf["h"],
                "t": float(arkit[i, 0]),
                "pose": column_major(in_meter[i]),
                "intrinsics": kf["intrinsics"],
                "tracking": {"state": "normal", "reason": None},
                "lens": {"camera": "wide"},
                "sharpness": {"method": SHARPNESS_METHOD, "value": round(score, 3)},
            }
        )

    trajectory = [
        trajectory_row(t, "normal", p) for t, p in zip(arkit[:, 0], in_meter, strict=True)
    ]
    streams = {"trajectory": w.add_stream("trajectory", trajectory, 60)}
    notes = []
    for name, file, rate in [
        ("accelerometer", "accelerometer.csv", 100),
        ("gyroscope", "gyro.csv", 100),
        ("magnetometer", "magnetometer.csv", 100),
        ("barometer", "barometer.csv", 1),
        ("location", "platform-locations.csv", 1),
    ]:
        data = read_csv(advio / "iphone" / file)
        data = data[(data[:, 0] >= start) & (data[:, 0] <= end)]
        repeats = np.flatnonzero(np.diff(data[:, 0]) <= 0) + 1
        if len(repeats):
            notes.append(f"{file}: dropped {len(repeats)} rows whose time did not advance")
            data = np.delete(data, repeats, axis=0)
        rows = [[round(float(v), 6) for v in r] for r in data]
        streams[name] = w.add_stream(name, rows, rate)

    manifest = {
        "packet_version": PACKET_VERSION,
        "session": {
            "id": session["session"]["id"],
            "producer": {"kind": "converter", "name": "packet.samples.advio", "version": "1"},
            "device": {"model": "iPhone8,1", "ios_version": "11 (ADVIO 2018)", "lidar": False},
            "capture": {
                "started_at_uptime": float(start),
                "ended_at_uptime": float(end),
                "distance_walked_m": round(horizontal_distance(in_meter[:, :3, 3]), 4),
            },
            "world_alignment": "gravity",
            "meter_anchor": {"pose_in_world": column_major(anchor), "ground_y_m": None},
            "consent": {"location": True},
        },
        "photos": photos,
        "streams": streams,
        "marks": [
            {"id": "m1", "kind": "meter", "points": [[0.0, 0.0, 0.0]], "t": photos[0]["t"]},
        ],
        "provenance": {
            "dataset": "ADVIO sequence 20 (Cortés, Solin, Rahtu, Kannala; ECCV 2018)",
            "license": "CC BY-NC 4.0: for accuracy testing only; never commit or redistribute",
            "source": "https://zenodo.org/record/1476931/files/advio-20.zip",
            "notes": [
                "t is ADVIO's own clock (seconds from the start of its recording), which every "
                "ADVIO file shares; it stands in for device uptime.",
                f"Photos are the evals replay's keyframes ({session['provenance']['keyframeRule']}"
                "), undistorted to pinhole; ADVIO's video is 1280 x 720, so this is its full "
                "resolution.",
                "There is no meter or wall in ADVIO. The meter frame follows the app replay's "
                f"assumption: a vertical wall parallel to the walk, {WALL_OFFSET_M} m to the side "
                "the camera faces, the meter level with the camera opposite the walk's middle.",
                "Streams are in ADVIO's units: accelerometer m/s^2, gyroscope rad/s, magnetometer "
                "microtesla, barometer kPa and meters. Location was recorded by the dataset "
                "authors and published with it.",
                "No exposure, ISO, depth, mesh, guidance or scene.json: ADVIO has none of them.",
                *notes,
            ],
        },
    }
    return w.finish(manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--advio", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(build(args.replay.expanduser(), args.advio.expanduser(), args.out.expanduser()))


if __name__ == "__main__":
    main()
