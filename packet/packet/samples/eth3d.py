"""A sample packet from ETH3D's electro scene: full-resolution DSLR photos of building walls
within about 6 m, each with a depth map rendered from the terrestrial laser scan as a stand-in
for the depth a LiDAR iPhone records.

Inputs are the evals lane's extracted scene (scan points, COLMAP calibration) plus the original
undistorted photos from electro_dslr_undistorted.7z (sha256 in experiments/evals/README.md on
t3/evals), unpacked to <eth3d>/full/.

    uv run python -m packet.samples.eth3d --eth3d ~/house-scanning-data/evals/eth3d/electro \
        --out ~/house-scanning-data/packets/eth3d-electro
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image

from packet.write import (
    PACKET_VERSION,
    SHARPNESS_METHOD,
    PacketWriter,
    column_major,
    meter_frame,
    sharpness,
)

PHOTOS = [f"DSC_{n}" for n in range(9257, 9265)]  # one walk past the wall, in shooting order
# ARKit's depth map is 256 x 192 for a 1920 x 1440 image (1/7.5); a 1/16 map of a 24 MP photo
# is 387 x 258, the same order of pixel count, so the sample exercises the same alignment rule.
DEPTH_SCALE = 16
NEAR_M = 0.2
WALL_RADIUS_M = 0.25
OPENCV_TO_ARKIT_CAMERA = np.diag([1.0, -1.0, -1.0, 1.0])


def read_cameras(path: Path) -> dict[int, tuple[int, int, float, float, float, float]]:
    cams = {}
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        cid, model, w, h, *params = line.split()
        if model != "PINHOLE":
            raise ValueError(f"camera {cid} is {model}; the undistorted set should be PINHOLE")
        cams[int(cid)] = (int(w), int(h), *map(float, params))
    return cams


def read_images(path: Path) -> dict[str, tuple[np.ndarray, int]]:
    """Image name -> (world-to-camera 4x4 in OpenCV axes, camera id). COLMAP lists two lines per
    image; the second holds 2-D points and is skipped."""
    out = {}
    lines = [ln for ln in path.read_text().splitlines() if not ln.startswith("#")]
    for line in lines[::2]:
        f = line.split()
        qw, qx, qy, qz, tx, ty, tz = map(float, f[1:8])
        r = quaternion_wxyz(qw, qx, qy, qz)
        m = np.eye(4)
        m[:3, :3], m[:3, 3] = r, [tx, ty, tz]
        out[Path(f[9]).stem] = (m, int(f[8]))
    return out


def quaternion_wxyz(w: float, x: float, y: float, z: float) -> np.ndarray:
    n = math.sqrt(w * w + x * x + y * y + z * z)
    w, x, y, z = w / n, x / n, y / n, z / n
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
    )


def gravity_world(normals: np.ndarray) -> tuple[np.ndarray, float]:
    """World-from-scan rotation with +y up, and the scan's tilt in degrees. The scan is levelled
    with z roughly up; ground and roof normals (within 18° of z) give the exact up direction."""
    flat = normals[np.abs(normals[:, 2]) > 0.95]
    up = (flat * np.sign(flat[:, 2:3])).mean(axis=0)
    up /= np.linalg.norm(up)
    swap = np.array([[1.0, 0, 0], [0, 0, 1], [0, -1, 0]])  # scan z -> world y, right-handed
    u = swap @ up
    axis = np.cross(u, [0.0, 1.0, 0.0])
    s, c = np.linalg.norm(axis), u[1]
    if s < 1e-12:
        level = np.eye(3)
    else:
        k = axis / s
        kx = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
        level = np.eye(3) + s * kx + (1 - c) * kx @ kx
    m = np.eye(4)
    m[:3, :3] = level @ swap
    return m, math.degrees(math.acos(min(1.0, abs(up[2]))))


def render_depth(
    points: np.ndarray, cam_from_scan: np.ndarray, k: tuple, size: tuple
) -> np.ndarray:
    """Nearest scan depth per pixel of a map `size` = (w, h) covering the photo's field of view."""
    w, h, fx, fy, cx, cy = k
    dw, dh = size
    pc = points @ cam_from_scan[:3, :3].T + cam_from_scan[:3, 3]
    z = pc[:, 2]
    front = z > NEAR_M
    pc, z = pc[front], z[front]
    u = fx * pc[:, 0] / z + cx
    v = fy * pc[:, 1] / z + cy
    inside = (u >= 0) & (u < w) & (v >= 0) & (v < h)
    j = (u[inside] * dw / w).astype(int)
    i = (v[inside] * dh / h).astype(int)
    depth = np.full(dh * dw, np.inf)
    np.minimum.at(depth, i * dw + j, z[inside])
    depth[np.isinf(depth)] = 0
    return depth.reshape(dh, dw).astype(np.float32)


def build(eth3d: Path, out: Path) -> Path:
    cams = read_cameras(eth3d / "dslr_calibration_undistorted" / "cameras.txt")
    images = read_images(eth3d / "dslr_calibration_undistorted" / "images.txt")
    points = np.load(eth3d / "scan_points_10mm.npy").astype(np.float64)
    world_from_scan, tilt = gravity_world(np.load(eth3d / "normals.npy"))

    # Camera-to-world poses in ARKit camera axes, and depth maps, per photo.
    frames = []
    for name in PHOTOS:
        cam_from_scan, cid = images[name]
        k = cams[cid]
        size = (round(k[0] / DEPTH_SCALE), round(k[1] / DEPTH_SCALE))
        depth = render_depth(points, cam_from_scan, k, size)
        world_pose = world_from_scan @ np.linalg.inv(cam_from_scan) @ OPENCV_TO_ARKIT_CAMERA
        frames.append((name, k, depth, world_pose, cam_from_scan))

    # The meter frame: where the first photo's optical axis meets the wall.
    name, k, depth, world_pose, cam_from_scan = frames[0]
    centre = depth[depth.shape[0] // 2, depth.shape[1] // 2]
    if centre <= 0:
        raise ValueError(f"{name}: no scan depth at the image centre to anchor the meter on")
    hit_scan = np.linalg.inv(cam_from_scan) @ np.array([0.0, 0.0, centre, 1.0])
    near = points[np.linalg.norm(points - hit_scan[:3], axis=1) < WALL_RADIUS_M]
    normal = world_from_scan[:3, :3] @ np.linalg.svd(near - near.mean(axis=0))[2][2]
    if abs(normal[1]) > 0.5:
        raise ValueError(f"{name}: the image centre hits a surface that is not a wall")
    normal[1] = 0
    normal /= np.linalg.norm(normal)
    hit_world = (world_from_scan @ hit_scan)[:3]
    if normal @ (world_pose[:3, 3] - hit_world) < 0:
        normal = -normal  # point out of the wall, toward the camera
    anchor = meter_frame(hit_world, np.cross([0.0, 1.0, 0.0], normal))
    to_meter = np.linalg.inv(anchor)

    world_points_y = (points @ world_from_scan[:3, :3].T)[:, 1]
    horizontal = np.linalg.norm(
        (points - hit_scan[:3]) @ world_from_scan[:3, :3].T * [1, 0, 1], axis=1
    )
    ground_y = float(np.percentile(world_points_y[horizontal < 1.0], 2)) - hit_world[1]

    w = PacketWriter(out)
    photos = []
    for n, (name, k, depth, world_pose, _) in enumerate(frames):
        pid = f"p{n + 1:05d}"
        source = eth3d / "full" / f"{name}.JPG"
        with Image.open(source) as img:
            if img.size != (k[0], k[1]):
                raise ValueError(f"{name}: image is {img.size}, calibration says {k[:2]}")
            score = sharpness(img)
        confidence = np.where(depth > 0, 2, 0)
        photos.append(
            {
                "id": pid,
                "image": w.add_file(f"photos/{pid}.jpg", source),
                "width": k[0],
                "height": k[1],
                "t": float(n + 1),
                "pose": column_major(to_meter @ world_pose),
                "intrinsics": [round(v, 4) for v in k[2:]],
                "lens": {"camera": f"ETH3D DSLR, calibration camera {images[name][1]}"},
                "sharpness": {"method": SHARPNESS_METHOD, "value": round(score, 3)},
                "depth": w.add_depth(pid, depth, confidence)
                | {"source": "rendered_from_laser_scan"},
            }
        )

    manifest = {
        "packet_version": PACKET_VERSION,
        "session": {
            "id": "eth3d-electro-9257-9264",
            "producer": {"kind": "converter", "name": "packet.samples.eth3d", "version": "1"},
            "device": {"model": "ETH3D DSLR (24 MP)", "lidar": False},
            "capture": {"started_at_uptime": 0.0, "ended_at_uptime": float(len(frames) + 1)},
            "world_alignment": "gravity",
            "meter_anchor": {
                "pose_in_world": column_major(anchor),
                "ground_y_m": round(ground_y, 4),
            },
        },
        "photos": photos,
        "marks": [{"id": "m1", "kind": "meter", "points": [[0.0, 0.0, 0.0]], "t": 0.5}],
        "provenance": {
            "dataset": "ETH3D high-res multi-view, electro (Schöps et al., CVPR 2017)",
            "license": "CC BY-NC-SA 4.0: accuracy testing only; never commit or share",
            "source": "https://www.eth3d.net/data/electro_dslr_undistorted.7z and the evals "
            "lane's scan_points_10mm.npy / normals.npy",
            "notes": [
                "Photos are ETH3D's undistorted originals, unchanged. They carry no EXIF, so "
                "there is no capture time, exposure, ISO or lens data: t is the shooting order "
                "in seconds.",
                f"Depth is rendered from the laser scan (10 mm points, nearest point per pixel) "
                f"at 1/{DEPTH_SCALE} of each photo's size; confidence is 2 where a scan point "
                "landed and 0 elsewhere. It stands in for LiDAR depth: denser and more accurate "
                "than an iPhone's.",
                f"World is the scan levelled by its ground normals (tilt {tilt:.2f} degrees), "
                "with y up. There is no meter: the meter frame sits where the first photo's "
                "optical axis meets the wall, z out of the wall toward the camera. ground_y_m is "
                "the 2nd percentile scan height within 1 m of it.",
                "No trajectory, IMU, mesh, planes, guidance or scene.json: a DSLR records none.",
            ],
        },
    }
    return w.finish(manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--eth3d", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(build(args.eth3d.expanduser(), args.out.expanduser()))


if __name__ == "__main__":
    main()
