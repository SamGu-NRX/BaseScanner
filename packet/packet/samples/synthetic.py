"""A tiny synthetic packet that uses every part of the spec: the test fixture in fixtures/.

Nothing in it is measured. A camera slides 2 m along a flat wall 2.5 m away, facing it, and every
sensor reports the values that motion implies (or a fixed plausible value). It exists so readers
and the validator have one packet with every optional section, small enough to commit.

    uv run python -m packet.samples.synthetic --out fixtures/synthetic
"""

from __future__ import annotations

import argparse
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from packet.validate import horizontal_distance
from packet.write import (
    PACKET_VERSION,
    SHARPNESS_METHOD,
    PacketWriter,
    column_major,
    sharpness,
    trajectory_row,
)

T0, T1, RATE = 100.0, 102.0, 60
W, H, FX = 96, 72, 80.0
DEPTH_W, DEPTH_H = 24, 18
PHOTO_TICKS = (15, 60, 105)  # trajectory samples the photos are taken at
DEPTH_FRAME_TICKS = (30, 75)  # depth recorded between photos (1.1)
WALL_DISTANCE = 2.5


def camera_pose(t: float) -> np.ndarray:
    """Camera to meter frame: sliding along +x from -1 to +1 m, 2.5 m out, facing the wall.
    The camera looks along its -z, which is the meter frame's -z (into the wall)."""
    pose = np.eye(4)
    pose[:3, 3] = [-1.0 + 2.0 * (t - T0) / (T1 - T0), 0.0, WALL_DISTANCE]
    return pose


def photo(index: int) -> bytes:
    img = Image.new("RGB", (W, H), (200, 190, 170))
    draw = ImageDraw.Draw(img)
    for x in range(0, W, 12):
        draw.line([(x + 4 * index, 0), (x + 4 * index, H)], fill=(120, 60, 40), width=2)
    draw.rectangle([30, 20, 50, 40], outline=(40, 40, 40), width=2)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def build(out: Path) -> Path:
    w = PacketWriter(out)
    ticks = np.arange(0, round((T1 - T0) * RATE) + 1)
    times = T0 + ticks / RATE
    poses = [camera_pose(t) for t in times]

    photos = []
    for n, k in enumerate(PHOTO_TICKS, start=1):
        pid = f"p{n:05d}"
        data = photo(n)
        # A flat wall straight ahead: every depth pixel is the wall distance.
        depth = np.full((DEPTH_H, DEPTH_W), WALL_DISTANCE, dtype=np.float32)
        depth[:, :2] = 0  # a strip with no measurement, as at a real depth map's edge
        confidence = np.where(depth > 0, 2, 0)
        photos.append(
            {
                "id": pid,
                "image": w.add_bytes(f"photos/{pid}.jpg", data),
                "width": W,
                "height": H,
                "t": float(times[k]),
                "pose": column_major(poses[k]),
                "intrinsics": [FX, FX, W / 2, H / 2],
                "tracking": {"state": "normal", "reason": None},
                "exposure": {"duration_s": 1 / 500, "iso": 50},
                "lens": {"focal_length_mm": 5.1, "f_number": 1.8, "camera": "wide"},
                "sharpness": {
                    "method": SHARPNESS_METHOD,
                    "value": round(sharpness(Image.open(io.BytesIO(data))), 3),
                },
                "depth": w.add_depth(pid, depth, confidence) | {"source": "arkit_scene_depth"},
            }
        )

    traj = [trajectory_row(t, "normal", p) for t, p in zip(times, poses, strict=True)]
    imu_t = np.round(T0 + np.arange(0, 2.0, 0.01), 3)
    streams = {
        "trajectory": w.add_stream("trajectory", traj, RATE),
        # Device held still in landscape: gravity along the device's -x.
        "accelerometer": w.add_stream("accelerometer", [[t, -9.81, 0.0, 0.0] for t in imu_t], 100),
        "gyroscope": w.add_stream("gyroscope", [[t, 0.0, 0.0, 0.0] for t in imu_t], 100),
        "magnetometer": w.add_stream("magnetometer", [[t, 20.0, -5.0, -40.0] for t in imu_t], 100),
        "device_motion": w.add_stream(
            "device_motion",
            [[t, 0, 0, 0, 1, -1, 0, 0, 0, 0, 0, 0, 0, 0, 90.0] for t in imu_t],
            100,
        ),
        "barometer": w.add_stream("barometer", [[T0 + 0.5, 101.3, 0.0], [T0 + 1.5, 101.3, 0.0]], 1),
        "location": w.add_stream("location", [[T0 + 0.5, 0.0, 0.0, 10.0, 5.0, 3.0]], 1),
        "heading": w.add_stream("heading", [[T0 + 0.5, 90.0, 90.0, 10.0]], 1),
    }

    mesh = mesh_ply()
    wall_plane = np.eye(4)
    wall_plane[:3, :3] = [[1, 0, 0], [0, 0, -1], [0, 1, 0]]  # plane normal (+y) = meter +z
    ground_plane = np.eye(4)
    ground_plane[1, 3] = -1.2
    anchor = np.eye(4)
    anchor[:3, :3] = [[0.866025, 0, 0.5], [0, 1, 0], [-0.5, 0, 0.866025]]
    anchor[:3, 3] = [3.0, 0.2, -1.5]

    manifest = {
        "packet_version": PACKET_VERSION,
        "session": {
            "id": "synthetic-0001",
            "producer": {"kind": "converter", "name": "packet.samples.synthetic", "version": "1"},
            "device": {
                "model": "synthetic",
                "ios_version": "n/a",
                "lidar": True,
                "scene_depth_enabled": True,
                "mesh_enabled": True,
                "mesh_classification_enabled": True,
            },
            "capture": {
                "started_at": "2026-09-26T12:00:00Z",
                "started_at_uptime": T0 - 0.5,
                "ended_at_uptime": T1 + 0.5,
                "distance_walked_m": round(
                    horizontal_distance(np.array([p[:3, 3] for p in poses])), 4
                ),
            },
            "world_alignment": "gravity",
            "meter_anchor": {"pose_in_world": column_major(anchor), "ground_y_m": -1.2},
            "consent": {"location": True},
        },
        "photos": photos,
        "streams": streams,
        "depth_frames": depth_frames(w, times, poses),
        "lidar": {"mesh": w.add_bytes("lidar/mesh.ply", mesh)},
        "planes": [
            {
                "id": "wall",
                "alignment": "vertical",
                "classification": "wall",
                "pose": column_major(wall_plane),
                "extent_m": [6.0, 2.4],
                # An L of wall: a window cut out of the top right (plane x, z = -height).
                "boundary_m": [
                    [-3.0, -1.2],
                    [3.0, -1.2],
                    [3.0, 0.2],
                    [0.0, 0.2],
                    [0.0, 1.2],
                    [-3.0, 1.2],
                ],
            },
            {
                "id": "ground",
                "alignment": "horizontal",
                "classification": "floor",
                "pose": column_major(ground_plane),
                "extent_m": [6.0, 3.0],
            },
        ],
        "marks": [
            {
                "id": "m1",
                "kind": "meter",
                "points": [[0.0, 0.0, 0.0]],
                "t": T0 - 0.2,
                "photo_ids": ["p00001"],
            },
            {
                "id": "m2",
                "kind": "wall_end",
                "points": [[-3.0, 0.0, 0.0]],
                "t": T0 + 0.1,
                "side": "left",
                "end_kind": "unexplored",
            },
            {
                "id": "m3",
                "kind": "wall_end",
                "points": [[3.0, 0.0, 0.0]],
                "t": T0 + 1.9,
                "side": "right",
                "end_kind": "limit",
            },
            {"id": "m4", "kind": "gas_meter", "points": [[1.5, -0.6, 0.1]], "t": T0 + 1.2},
            {
                "id": "m5",
                "kind": "window",
                "points": [[-2.0, 0.2, 0.0], [-1.2, 1.2, 0.0]],
                "t": T0 + 0.4,
                "attrs": {"operable": True},
            },
            {
                "id": "m6",
                "kind": "drive_edge",
                "points": [[2.0, -1.2, 0.5], [2.0, -1.2, 4.0]],
                "t": T0 + 1.5,
            },
        ],
        "guidance": [
            {
                "id": "g1",
                "kind": "walk",
                "origin": "phone",
                "message": "Walk slowly to your left",
                "t_shown": T0,
                "t_resolved": T0 + 0.8,
                "outcome": "met",
            },
            {
                "id": "g2",
                "kind": "tilt_to_ground",
                "origin": "phone",
                "band": "ground",
                "message": "Tilt down to show the ground",
                "t_shown": T0 + 0.9,
                "t_resolved": T0 + 1.3,
                "outcome": "met",
            },
            {
                "id": "g3",
                "kind": "gap_band",
                "origin": "server",
                "band": "ground",
                "span_m": [1.0, 2.5],
                "message": "Show the ground around your meter",
                "t_shown": T0 + 1.6,
                "t_resolved": T0 + 1.9,
                "outcome": "cannot_reach",
            },
        ],
        "scene": w.add_bytes("scene.json", scene_json()) | {"schema_version": "1.0"},
        "provenance": {
            "dataset": "synthetic",
            "license": "same as this repository",
            "source": "packet/packet/samples/synthetic.py",
            "notes": ["Every value is invented; nothing was measured."],
        },
    }
    return w.finish(manifest)


def depth_frames(w: PacketWriter, times: np.ndarray, poses: list[np.ndarray]) -> list[dict]:
    """Depth between photos: one frame from ARKit (with confidence), one estimated from the image
    (with sigma), at the depth map's own resolution."""
    scale = DEPTH_W / W
    frames = []
    for n, k in enumerate(DEPTH_FRAME_TICKS, start=1):
        fid = f"d{n:05d}"
        depth = np.full((DEPTH_H, DEPTH_W), WALL_DISTANCE, dtype=np.float32)
        if n == 1:
            data = w.add_depth(
                fid, depth, confidence=np.full(depth.shape, 2), folder="depth_frames"
            )
            data["source"] = "arkit_scene_depth"
        else:
            sigma = np.full(depth.shape, 0.15, dtype=np.float32)
            data = w.add_depth(fid, depth, sigma=sigma, folder="depth_frames")
            data["source"] = "estimated"
        frames.append(
            {
                "id": fid,
                "t": float(times[k]),
                "pose": column_major(poses[k]),
                "intrinsics": [FX * scale, FX * scale, DEPTH_W / 2, DEPTH_H / 2],
                "tracking": {"state": "normal", "reason": None},
                **data,
            }
        )
    return frames


def mesh_ply() -> bytes:
    """A wall quad (class 1, wall) and a ground quad (class 2, floor), two triangles each."""
    v = np.array(
        [
            [-3, -1.2, 0],
            [3, -1.2, 0],
            [3, 1.2, 0],
            [-3, 1.2, 0],
            [-3, -1.2, 0],
            [3, -1.2, 0],
            [3, -1.2, 3],
            [-3, -1.2, 3],
        ],
        dtype="<f4",
    )
    faces = [((0, 1, 2), 1), ((0, 2, 3), 1), ((4, 6, 5), 2), ((4, 7, 6), 2)]
    header = (
        "ply\nformat binary_little_endian 1.0\ncomment synthetic\n"
        f"element vertex {len(v)}\nproperty float x\nproperty float y\nproperty float z\n"
        f"element face {len(faces)}\nproperty list uchar int vertex_indices\n"
        "property uchar classification\nend_header\n"
    ).encode()
    face_dtype = np.dtype([("n", "u1"), ("i", "<i4", 3), ("c", "u1")])
    f = np.array([(3, idx, c) for idx, c in faces], dtype=face_dtype)
    return header + v.tobytes() + f.tobytes()


def scene_json() -> bytes:
    scene = {
        "schema_version": "1.0",
        "meter": {"pos": [0.0, 4.0, 0.0], "wall_id": "w1"},
        "walls": [{"id": "w1", "baseline": [[-9.84, 0.0], [9.84, 0.0]]}],
    }
    return (json.dumps(scene, indent=1) + "\n").encode()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True)
    print(build(parser.parse_args().out))


if __name__ == "__main__":
    main()
