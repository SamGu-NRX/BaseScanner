"""Geometry of the ETH3D electro capture packet (packet 1.1) and its laser scan, in the meter frame.

Conventions (packet/README.md and docs/00): poses map ARKit camera coordinates (x right, y up,
looking down -z) into the meter frame (+y up, +z out of the meter's wall), 16 numbers column-major.
Intrinsics are for the stored landscape photo. Depth is float32 meters along the camera's -z axis
on a grid 1/16 of the photo, 0 = none. The ray through photo pixel (u, v) is
((u - cx) / fx, -(v - cy) / fy, -1) before rotation.

The laser scan (ETH3D scan_points_10mm.npy, from the evals lane) is in ETH3D's frame. Its map to
the meter frame is meter_from_cam @ diag(1, -1, -1) @ cam_from_scan, where cam_from_scan is
ETH3D's COLMAP pose; all eight photos give the same map to 1e-15 m.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import cache
from pathlib import Path

import numpy as np

from .paths import DATA, ELECTRO

EVALS = Path.home() / "house-scanning-data" / "evals" / "eth3d" / "electro"
FT = 3.280839895


@dataclass
class Photo:
    id: str
    W: int
    H: int
    K: np.ndarray  # fx, fy, cx, cy for the full photo
    pose: np.ndarray  # 4x4 camera (ARKit axes) to meter frame
    depth: np.ndarray  # (h, w) meters along -z, 0 = none

    def ray(self, u: np.ndarray, v: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Origin and unit direction in the meter frame of rays through full-photo pixels."""
        fx, fy, cx, cy = self.K
        d = np.stack([(u - cx) / fx, -(v - cy) / fy, -np.ones_like(u, dtype=float)], -1)
        d = d @ self.pose[:3, :3].T
        return self.pose[:3, 3], d / np.linalg.norm(d, axis=-1, keepdims=True)

    def depth_points(self, x0: float, y0: float, x1: float, y1: float) -> np.ndarray:
        """Meter-frame points of every depth pixel whose centre lies in a normalized box."""
        h, w = self.depth.shape
        c0, c1 = int(np.floor(max(x0, 0) * w)), int(np.ceil(min(x1, 1) * w))
        r0, r1 = int(np.floor(max(y0, 0) * h)), int(np.ceil(min(y1, 1) * h))
        rr, cc = np.mgrid[r0:r1, c0:c1]
        z = self.depth[r0:r1, c0:c1]
        ok = z > 0
        u = (cc[ok] + 0.5) * self.W / w
        v = (rr[ok] + 0.5) * self.H / h
        fx, fy, cx, cy = self.K
        pc = np.stack([(u - cx) / fx * z[ok], -(v - cy) / fy * z[ok], -z[ok]], -1)
        return pc @ self.pose[:3, :3].T + self.pose[:3, 3]

    def project(self, p: np.ndarray) -> np.ndarray:
        """Normalized image coordinates (x, y in [0, 1] inside the photo) of meter-frame points."""
        R, t = self.pose[:3, :3], self.pose[:3, 3]
        pc = (p - t) @ R  # into camera axes
        fx, fy, cx, cy = self.K
        u = fx * pc[..., 0] / -pc[..., 2] + cx
        v = -fy * pc[..., 1] / -pc[..., 2] + cy
        return np.stack([u / self.W, v / self.H], -1)


@cache
def manifest() -> dict:
    return json.loads((ELECTRO / "manifest.json").read_text())


def ground_y() -> float:
    return manifest()["session"]["meter_anchor"]["ground_y_m"]


@cache
def photos() -> dict[str, Photo]:
    out = {}
    for p in manifest()["photos"]:
        d = p["depth"]
        depth = np.fromfile(ELECTRO / d["map"]["path"], "<f4").reshape(d["height"], d["width"])
        pose = np.array(p["pose"], dtype=float).reshape(4, 4).T  # column-major
        out[p["id"]] = Photo(p["id"], p["width"], p["height"], np.array(p["intrinsics"], float), pose, depth)
    return out


def _colmap_poses() -> dict[str, np.ndarray]:
    out = {}
    for line in (EVALS / "dslr_calibration_undistorted" / "images.txt").read_text().splitlines():
        f = line.split()
        if line.startswith("#") or len(f) != 10 or not f[9].startswith("dslr_images"):
            continue
        w, x, y, z = map(float, f[1:5])
        R = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ])
        T = np.eye(4)
        T[:3, :3], T[:3, 3] = R, list(map(float, f[5:8]))
        out[f[9].split("/")[-1]] = T
    return out


def meter_from_scan() -> np.ndarray:
    """Scan frame to meter frame; raises if the eight photos disagree by more than 1 mm."""
    first = int(manifest()["session"]["id"].split("-")[2])  # eth3d-electro-9257-9264
    cols = _colmap_poses()
    Ts = [
        photos()[p["id"]].pose @ np.diag([1.0, -1.0, -1.0, 1.0]) @ cols[f"DSC_{first + k}.JPG"]
        for k, p in enumerate(manifest()["photos"])
    ]
    spread = np.abs(np.array(Ts) - Ts[0]).max()
    if spread > 1e-3:
        raise ValueError(f"photos disagree on the scan-to-meter map by {spread}")
    return Ts[0]


@cache
def scan() -> np.ndarray:
    """Laser points in the meter frame (float32, cached in DATA)."""
    cached = DATA / "scan_meter_frame.npy"
    if cached.exists():
        return np.load(cached)
    T = meter_from_scan()
    P = np.load(EVALS / "scan_points_10mm.npy")
    Q = (P @ T[:3, :3].T + T[:3, 3]).astype(np.float32)
    np.save(cached, Q)
    return Q


@dataclass
class WallFrame:
    """A vertical plane: origin, outward unit normal (toward the cameras), and unit axis along
    the wall to the right as seen facing it. Height is meter-frame y above the meter's ground."""

    origin: np.ndarray
    normal: np.ndarray
    along: np.ndarray

    @staticmethod
    def from_normal(origin: np.ndarray, normal: np.ndarray) -> "WallFrame":
        n = np.array([normal[0], 0.0, normal[2]])
        n /= np.linalg.norm(n)
        along = np.cross([0.0, 1.0, 0.0], n)  # up x out = right, facing the wall
        return WallFrame(np.asarray(origin, float), n, along / np.linalg.norm(along))

    def coords(self, p: np.ndarray) -> np.ndarray:
        """(along, height, out) in meters."""
        d = p - self.origin
        return np.stack([d @ self.along, p[..., 1] - ground_y(), d @ self.normal], -1)

    def intersect(self, o: np.ndarray, d: np.ndarray) -> np.ndarray:
        t = ((self.origin - o) @ self.normal) / (d @ self.normal)
        return o + t[..., None] * d


def fit_vertical_plane(pts: np.ndarray, toward: np.ndarray, tol: float = 0.02, iters: int = 400, seed: int = 0) -> tuple[WallFrame, float]:
    """RANSAC plane whose normal is within 10 degrees of horizontal, oriented toward `toward`.
    Returns the frame (origin = inlier centroid) and the inlier fraction."""
    rng = np.random.default_rng(seed)
    best, best_n = None, -1
    for _ in range(iters):
        a, b, c = pts[rng.choice(len(pts), 3, replace=False)]
        n = np.cross(b - a, c - a)
        if np.linalg.norm(n) < 1e-9:
            continue
        n /= np.linalg.norm(n)
        if abs(n[1]) > np.sin(np.radians(10)):
            continue
        inl = np.abs((pts - a) @ n) < tol
        if inl.sum() > best_n:
            best, best_n = inl, inl.sum()
    if best is None:
        raise ValueError("no vertical plane found")
    q = pts[best]
    c = q.mean(0)
    # refine: normal = smallest singular vector of the inliers, forced vertical
    n = np.linalg.svd(q - c, full_matrices=False)[2][-1]
    if (toward - c) @ n < 0:
        n = -n
    return WallFrame.from_normal(c, n), best_n / len(pts)
