"""Acceptance on ETH3D (Schöps et al., CVPR 2017): the worker against a laser scan.

`python -m recon.eth3d [scene]` runs the worker on one ETH3D scene twice, once with MoGe-2 depth
rescaled by the (exact) poses, the photos-only path, and once with depth rendered from the laser
scan standing in for LiDAR. It then measures:
- wall geometry: the fitted wall plane against a plane fitted to the laser scan's wall, and the
  reconstruction's point at each pixel where a laser wall point is visible, as the evals measured
  learned depth (point-pair errors over 1 to 3 m spans, inches);
- coverage: wall the worker calls observed where at least 10 cm of the band was seen by no photo
  (false-observed length, feet), against the laser scan's visibility, as in experiments/evals
  README section 7 on t3/evals. Pre-registered bar: at most 0.5 ft.

Data: the prepared scene from `make recon-data` in experiments/evals (t3/evals): COLMAP text model,
the scan voxelized to `scan_points_10mm.npy`, occlusion splats to `occluders_20mm.npy`, images at
1024 px in `images_1024/`, masks. Non-commercial (CC BY-NC-SA 4.0): accuracy only, never
committed.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from scipy.spatial import cKDTree

from recon import depth as dep
from recon.capture import FEET, UP, Capture, Frame
from recon.coverage import CELL_M, HIDE_ABS_M, HIDE_REL
from recon.fusion import MAX_RANGE_M, Volume
from recon.pipeline import reconstruct

DATA = Path(os.environ.get("HOUSE_SCANNING_DATA", Path.home() / "house-scanning-data"))
ETH3D = DATA / "evals" / "eth3d"
RESULTS = Path(__file__).resolve().parents[1] / "results"
WIDTH = 1024
LIDAR_WIDTH = 256  # an iPhone LiDAR depth map is 256 x 192
PASS_FT = 0.5
MISSING_FROM_SCAN = 2  # ETH3D mask label: people, vegetation and other things the scanner missed


@dataclass(frozen=True)
class View:
    name: str
    width: int
    height: int
    K: np.ndarray  # fx, fy, cx, cy at full size, (0, 0) at the top-left corner
    R_wc: np.ndarray
    t_wc: np.ndarray

    @property
    def center(self) -> np.ndarray:
        return -self.R_wc.T @ self.t_wc


def quat_wxyz(q: np.ndarray) -> np.ndarray:
    w, x, y, z = q / np.linalg.norm(q)
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
    )


def read_views(scene_dir: Path) -> list[View]:
    """COLMAP's text model of the undistorted images. COLMAP's pixel (0, 0) is a corner, as here."""
    cal = scene_dir / "dslr_calibration_undistorted"
    cams = {}
    for line in (cal / "cameras.txt").read_text().splitlines():
        if line and not line.startswith("#"):
            cid, model, w, h, *p = line.split()
            if model != "PINHOLE":
                raise ValueError(f"camera {cid} is {model}, expected PINHOLE")
            cams[cid] = (int(w), int(h), np.array(list(map(float, p))))
    lines = [x for x in (cal / "images.txt").read_text().splitlines() if not x.startswith("#")]
    views = []
    for pose in lines[0::2]:
        if not pose.strip():
            continue
        f = pose.split()
        w, h, K = cams[f[8]]
        views.append(View(Path(f[9]).stem, w, h, K, quat_wxyz(np.array(list(map(float, f[1:5])))),
                          np.array(list(map(float, f[5:8])))))
    return sorted(views, key=lambda v: v.name)


def rotation_to_y(up: np.ndarray) -> np.ndarray:
    v = np.cross(up, UP)
    s, c = np.linalg.norm(v), float(up @ UP)
    V = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + V + V @ V * ((1 - c) / s**2) if s > 1e-12 else np.eye(3)


def level(views: list[View], scan: np.ndarray) -> tuple[np.ndarray, float]:
    """Rotation into a world whose +y is up, from a plane through the ground under the cameras,
    and the ground's height in it. The cameras' mean up axis alone was 10 degrees off on facade."""
    guess = np.mean([v.R_wc.T @ [0, -1.0, 0] for v in views], axis=0)
    guess /= np.linalg.norm(guess)
    a = np.cross(guess, [1.0, 0, 0])
    a /= np.linalg.norm(a)
    b = np.cross(guess, a)
    h = scan @ guess
    tree = cKDTree(np.c_[scan @ a, scan @ b])
    feet = []
    for v in views:
        c = v.center
        idx = np.asarray(tree.query_ball_point([c @ a, c @ b], 0.7), dtype=np.int64)
        below = idx[(h[idx] < c @ guess - 1.0) & (h[idx] > c @ guess - 2.5)]
        if len(below) >= 30:
            feet.append(scan[below][np.argsort(h[below])[: len(below) // 2]].mean(axis=0))
    feet = np.asarray(feet)
    centre = feet.mean(axis=0)
    n = np.linalg.svd(feet - centre)[2][2]
    n *= np.sign(n @ guess)
    R = rotation_to_y(n)
    return R, float((R @ centre)[1])


def load_scene(scene: str) -> tuple[list[View], np.ndarray, np.ndarray, Capture]:
    root = ETH3D / scene
    scan_file = root / "scan_points_10mm.npy"
    if not scan_file.exists():
        raise FileNotFoundError(f"{scan_file} missing: prepare ETH3D with `make recon-data` in experiments/evals")
    views = read_views(root)
    scan = np.concatenate([np.load(scan_file), np.load(root / "occluders_20mm.npy")])
    R, ground = level(views, np.load(scan_file)[::3].astype(np.float64))
    frames = []
    for v in views:
        img = root / "images_1024" / f"{v.name}.jpg"
        h = round(v.height * WIDTH / v.width)
        T = np.eye(4)
        T[:3, :3] = R @ v.R_wc.T @ np.diag([1.0, -1.0, -1.0])
        T[:3, 3] = R @ v.center
        frames.append(Frame(v.name, img, WIDTH, h, v.K * WIDTH / v.width, T))
    capture = Capture("eth3d", root, frames, ground, None, None, None)
    return views, R, scan, capture


def zbuffer(view: View, points: np.ndarray, width: int, window: int) -> np.ndarray:
    """Nearest laser depth per pixel of a `width`-wide image, holes closed by a minimum filter;
    NaN where nothing projects."""
    height = round(view.height * width / view.width)
    Xc = points @ view.R_wc.T.astype(np.float32) + view.t_wc.astype(np.float32)
    z = Xc[:, 2]
    ok = z > 0.1
    s = width / view.width
    u = (view.K[0] * Xc[ok, 0] / z[ok] + view.K[2]) * s
    v = (view.K[1] * Xc[ok, 1] / z[ok] + view.K[3]) * s
    inside = (u >= 0) & (u < width) & (v >= 0) & (v < height)
    buf = np.full((height, width), 1e6, np.float32)
    np.minimum.at(buf, (v[inside].astype(np.int64), u[inside].astype(np.int64)), z[ok][inside])
    buf = cv2.erode(buf, np.ones((window, window), np.uint8))
    buf[buf >= 1e5] = np.nan
    return buf


def missing_mask(scene: str, view: View, width: int) -> np.ndarray:
    """ETH3D's mask of things the scanner missed, stretched to the undistorted frame and dilated
    (the masks are drawn on the distorted images; see experiments/evals/evals/eth3d.py)."""
    height = round(view.height * width / view.width)
    path = ETH3D / scene / "masks_for_images" / "dslr_images" / f"{view.name}.png"
    if not path.exists():
        return np.zeros((height, width), bool)
    m = cv2.resize((cv2.imread(str(path), cv2.IMREAD_GRAYSCALE) == MISSING_FROM_SCAN).astype(np.uint8),
                   (width, height), interpolation=cv2.INTER_NEAREST)
    k = max(1, round(13 * width / 1024))
    return cv2.dilate(m, np.ones((2 * k + 1, 2 * k + 1), np.uint8)).astype(bool)


def laser_depths(scene: str, views: list[View], capture: Capture, scan: np.ndarray) -> dict:
    """The laser scan rendered at LiDAR resolution: metric depth with exact occlusion. Things the
    scanner missed (ETH3D's masks) are left unknown rather than guessed."""
    out = {}
    for v, f in zip(views, capture.frames, strict=True):
        d = zbuffer(v, scan, LIDAR_WIDTH, 3)
        d[missing_mask(scene, v, LIDAR_WIDTH)] = np.nan
        color = cv2.resize(cv2.imread(str(f.image)), (d.shape[1], d.shape[0]), interpolation=cv2.INTER_AREA)
        out[f.id] = dep.Depth(d, f.intrinsics * LIDAR_WIDTH / f.width, color, "lidar")
    return out


# --- Geometry against the scan ---------------------------------------------------------------


def surface_along(vol: Volume, origin: np.ndarray, dirs: np.ndarray, far: float = 8.0) -> np.ndarray:
    """Where each ray from `origin` first crosses the reconstruction's surface (NaN if never)."""
    step = vol.voxel / 2
    ts = np.arange(0.3, far, step)
    out = np.full((len(dirs), 3), np.nan)
    for i in range(0, len(dirs), 2048):
        d = dirs[i : i + 2048]
        pts = origin + d[:, None, :] * ts[None, :, None]
        t, w = vol.lookup(pts)
        inside = (w > 0) & (t <= 0)
        first = np.where(inside.any(axis=1), inside.argmax(axis=1), -1)
        for k, j in enumerate(first):
            if j <= 0:
                continue
            t0, t1 = t[k, j - 1], t[k, j]
            frac = t0 / (t0 - t1) if t0 != t1 else 0.0
            out[i + k] = origin + d[k] * (ts[j - 1] + frac * step)
    return out


def geometry_errors(r: dict, views: list[View], R: np.ndarray, scan_lev: np.ndarray,
                    rng: np.random.Generator) -> dict:
    wall = r["wall"]
    loc = wall.local(scan_lev)
    lo, hi = wall.s_range
    keep = (np.abs(loc[:, 2]) < 0.3) & (loc[:, 1] > 0.3) & (loc[:, 1] < 2.0)
    keep &= (loc[:, 0] > lo) & (loc[:, 0] < hi)
    s, out = loc[keep, 0], loc[keep, 2]
    b, a = np.polyfit(s, out, 1)  # the laser wall face in the fitted wall's coordinates
    ends = {name: (a + b * x) / FEET * 12 for name, x in (("left", lo), ("middle", (lo + hi) / 2), ("right", hi))}

    # Per-pixel correspondence: each sampled laser wall point, seen from its nearest view.
    pts = scan_lev[keep][rng.choice(keep.sum(), min(3000, keep.sum()), replace=False)]
    centers = np.array([R @ v.center for v in views])
    recon = np.full_like(pts, np.nan)
    order = np.argsort(np.linalg.norm(pts[:, None] - centers[None], axis=-1), axis=1)[:, 0]
    for j in np.unique(order):
        sel = np.flatnonzero(order == j)
        dirs = pts[sel] - centers[j]
        dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
        recon[sel] = surface_along(r["volume"], centers[j], dirs)
    ok = np.isfinite(recon[:, 0])
    along = np.linalg.norm(recon[ok] - pts[ok], axis=1)
    idx = np.flatnonzero(ok)
    i, j = rng.integers(0, len(idx), (2, 20000))
    dt = np.linalg.norm(pts[idx[i]] - pts[idx[j]], axis=1)
    sel = (dt >= 1.0) & (dt <= 3.0)
    dr = np.linalg.norm(recon[idx[i]] - recon[idx[j]], axis=1)
    pair = np.abs(dr[sel] - dt[sel]) / FEET * 12
    return {
        "wall_offset_in": {k: round(float(v), 2) for k, v in ends.items()},
        "wall_angle_deg": round(float(np.degrees(np.arctan(b))), 2),
        "laser_wall_points": int(keep.sum()),
        "points_found": f"{int(ok.sum())} of {len(pts)}",
        "point_error_in": {"median": round(float(np.median(along)) / FEET * 12, 2),
                           "p90": round(float(np.percentile(along, 90)) / FEET * 12, 2)},
        "pair_error_1_3m_in": {"pairs": int(sel.sum()), "median": round(float(np.median(pair)), 2),
                               "p90": round(float(np.percentile(pair, 90)), 2)},
        "laser_face": (float(a), float(b)),
    }


# --- Coverage against the scan's visibility --------------------------------------------------


def false_observed(r: dict, scene: str, views: list[View], R: np.ndarray, scan: np.ndarray,
                   face: tuple[float, float]) -> dict:
    """README section 7's metric on the worker's claim: claimed wall columns (2 cm) where at least
    two 5 cm samples of the band were seen by no photo, on the laser's wall face."""
    wall, cov = r["wall"], r["coverage"]
    lo, hi = wall.s_range
    cols = np.arange(lo + 0.01, hi, 0.02)
    heights = 1.9812 * (np.arange(40) + 0.5) / 40
    a, b = face
    S, H = np.meshgrid(cols, heights, indexing="ij")
    pts = wall.world(S, H, a + b * S).reshape(-1, 3)
    X = pts @ R  # levelled -> ETH3D world
    seen = np.zeros(len(pts), bool)
    for v in views:
        Xc = X @ v.R_wc.T + v.t_wc
        z = Xc[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = v.K[0] * Xc[:, 0] / z + v.K[2]
            vv = v.K[1] * Xc[:, 1] / z + v.K[3]
        framed = (z > 0.05) & (u >= 0) & (u <= v.width) & (vv >= 0) & (vv <= v.height)
        near = np.linalg.norm(X - v.center, axis=1) <= MAX_RANGE_M
        front = (R @ v.center - pts) @ wall.outward > 0
        buf = zbuffer(v, scan, 512, 5)
        miss = missing_mask(scene, v, 1024)
        s = 512 / v.width
        iu = np.clip(np.nan_to_num(u * s).astype(int), 0, buf.shape[1] - 1)
        iv = np.clip(np.nan_to_num(vv * s).astype(int), 0, buf.shape[0] - 1)
        nearest = buf[iv, iu]
        hidden = np.isfinite(nearest) & (nearest < z - np.maximum(HIDE_ABS_M, HIDE_REL * z))
        m = 1024 / v.width
        hidden |= miss[np.clip(np.nan_to_num(vv * m).astype(int), 0, miss.shape[0] - 1),
                       np.clip(np.nan_to_num(u * m).astype(int), 0, miss.shape[1] - 1)]
        seen |= framed & near & front & ~hidden
    unseen = (~seen).reshape(len(cols), len(heights)).sum(axis=1)
    cell = np.floor((cols - cov.cells[0]) / CELL_M).astype(int)
    claimed = cov.wall[np.clip(cell, 0, len(cov.wall) - 1)] & (cell >= 0) & (cell < len(cov.wall))
    bad = claimed & (unseen >= 2)
    return {
        "wall_ft": round((hi - lo) / FEET, 1),
        "claimed_ft": round(claimed.sum() * 0.02 / FEET, 2),
        "false_observed_ft": round(bad.sum() * 0.02 / FEET, 2),
        "passes": bool(bad.sum() * 0.02 / FEET <= PASS_FT),
    }


def run(scene: str, work: Path) -> dict:
    views, R, scan, capture = load_scene(scene)
    scan_lev = np.load(ETH3D / scene / "scan_points_10mm.npy")[::2].astype(np.float64) @ R.T
    rng = np.random.default_rng(0)
    rows = {}
    for label in ("laser as LiDAR", "MoGe-2, photos only"):
        if label.startswith("laser"):
            depths, report = laser_depths(scene, views, capture, scan), {"source": "lidar"}
        else:
            raw = dep.moge(capture, work / scene / "moge2")
            depths, report = dep.rescale(capture, raw)
            report["source"] = "moge2-triangulated"
        r = reconstruct(capture, depths, report)
        geo = geometry_errors(r, views, R, scan_lev, rng)
        cov = false_observed(r, scene, views, R, scan, geo.pop("laser_face"))
        rows[label] = {"wall": geo, "coverage": cov, "notes": list(capture.notes)}
        capture.notes.clear()
        print(label, json.dumps(rows[label]), file=sys.stderr)
    return rows


def markdown(scene: str, rows: dict) -> str:
    lines = [
        f"# Worker acceptance on ETH3D {scene} (generated by `make accept`)",
        "",
        "Wall offset: the laser's wall face relative to the worker's fitted plane at the wall's ends "
        "and middle. Point error: the reconstruction's surface along each pixel's ray against the "
        "laser point seen there. Pair error: |reconstructed - laser| distance between two such "
        f"points 1 to 3 m apart. False-observed: pass at {PASS_FT} ft or less.",
        "",
        "| Depth | Wall offset L / mid / R (in) | Angle | Point error median / p90 (in) | Pair error median / p90 (in) | Wall | Claimed | False-observed | Pass |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for label, row in rows.items():
        w, c = row["wall"], row["coverage"]
        o = w["wall_offset_in"]
        lines.append(
            f"| {label} | {o['left']:+.1f} / {o['middle']:+.1f} / {o['right']:+.1f} | {w['wall_angle_deg']:+.2f}° | "
            f"{w['point_error_in']['median']:.1f} / {w['point_error_in']['p90']:.1f} | "
            f"{w['pair_error_1_3m_in']['median']:.1f} / {w['pair_error_1_3m_in']['p90']:.1f} | "
            f"{c['wall_ft']:.1f} ft | {c['claimed_ft']:.1f} ft | {c['false_observed_ft']:.2f} ft | "
            f"{'yes' if c['passes'] else 'no'} |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    scene = sys.argv[1] if len(sys.argv) > 1 else "electro"
    rows = run(scene, DATA / "recon" / "work" / "eth3d")
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"eth3d_{scene}.json").write_text(json.dumps(rows, indent=1))
    md = markdown(scene, rows)
    (RESULTS / f"eth3d_{scene}.md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
