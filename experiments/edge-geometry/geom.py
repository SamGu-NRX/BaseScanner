"""Geometry with one correct answer: planes, rays, the wall frame, view-angle bins, triangulation.

A plane is (n, d) with unit normal n and n . x = d. Rays are origin + t * direction, t > 0.
"""

from __future__ import annotations

import numpy as np
from scipy.spatial import cKDTree

ANGLE_EDGES_DEG = (0.0, 15.0, 30.0, 45.0, 90.0)
ANGLE_LABELS = ("0-15", "15-30", "30-45", ">45")


def ray_plane(origin: np.ndarray, direction: np.ndarray, n: np.ndarray, d: float) -> np.ndarray:
    """Where each ray meets the plane, (N, 3). NaN for rays parallel to it or meeting it behind
    the origin. `origin` is (3,) or (N, 3); `direction` is (N, 3) and need not be unit length."""
    direction = np.atleast_2d(direction).astype(np.float64)
    origin = np.broadcast_to(np.asarray(origin, np.float64), direction.shape)
    denom = direction @ n
    with np.errstate(divide="ignore", invalid="ignore"):
        t = (d - origin @ n) / denom
        out = origin + t[:, None] * direction
    bad = (np.abs(denom) < 1e-12) | ~(t > 0)
    out[bad] = np.nan
    return out


def along_wall_axis(n: np.ndarray, up: np.ndarray) -> np.ndarray:
    """The horizontal unit vector lying in a plane with normal n: up x n, normalised. Its sign is
    fixed by n and up, so a plane's along-wall coordinate is well defined."""
    h = np.cross(up, n)
    norm = np.linalg.norm(h)
    if norm < 1e-6:
        raise ValueError(f"plane normal {n} is parallel to up {up}; it has no along-wall axis")
    return h / norm


def wall_frame(n: np.ndarray, up: np.ndarray) -> np.ndarray:
    """Orthonormal rows (h, n, w): along the wall, out of it, and w = n x h up the wall."""
    n = n / np.linalg.norm(n)
    h = along_wall_axis(n, up)
    return np.stack([h, n, np.cross(n, h)])


def decompose(err: np.ndarray, n: np.ndarray, up: np.ndarray) -> dict[str, np.ndarray]:
    """Split (N, 3) error vectors into signed along-wall and out-of-plane parts, and the 3-D norm."""
    frame = wall_frame(n, up)
    err = np.atleast_2d(err)
    return {
        "along": err @ frame[0],
        "out": err @ frame[1],
        "3d": np.linalg.norm(err, axis=1),
    }


def view_angle_deg(ray: np.ndarray, n: np.ndarray) -> np.ndarray:
    """Angle between each viewing ray (N, 3) and the plane normal, 0 to 90 degrees, either side."""
    ray = np.atleast_2d(ray)
    c = np.abs(ray @ n) / (np.linalg.norm(ray, axis=1) * np.linalg.norm(n))
    return np.degrees(np.arccos(np.clip(c, 0.0, 1.0)))


def angle_bin(angle_deg: np.ndarray) -> np.ndarray:
    """Bin index into ANGLE_LABELS: [0, 15), [15, 30), [30, 45), [45, 90]."""
    a = np.asarray(angle_deg, np.float64)
    if np.any((a < 0) | (a > 90) | ~np.isfinite(a)):
        raise ValueError("view angles must lie in [0, 90] degrees")
    return np.minimum(np.searchsorted(ANGLE_EDGES_DEG, a, side="right") - 1, len(ANGLE_LABELS) - 1)


def fit_plane(points: np.ndarray, trim_rounds: int = 2, k: float = 3.0, floor: float = 0.01):
    """Least-squares plane (n, d) through (N, 3) points, refitted `trim_rounds` times without
    points whose residual exceeds max(k robust sigmas, `floor` metres)."""
    pts = np.asarray(points, np.float64)
    if len(pts) < 3:
        raise ValueError(f"a plane needs at least 3 points, got {len(pts)}")
    keep = np.ones(len(pts), bool)
    for rnd in range(trim_rounds + 1):
        c = pts[keep].mean(axis=0)
        n = np.linalg.svd(pts[keep] - c, full_matrices=False)[2][2]
        if rnd == trim_rounds:
            break
        r = np.abs((pts - c) @ n)
        sigma = 1.4826 * np.median(r[keep])
        new = r <= max(k * sigma, floor)
        if new.sum() < 3 or np.array_equal(new, keep):
            break
        keep = new
    return n, float(n @ c)


def signed_yaw(n_est: np.ndarray, n_ref: np.ndarray, up: np.ndarray) -> float:
    """Rotation about up (radians) taking n_ref's horizontal part to n_est's, after flipping n_est
    to face the same way. Positive is counter-clockwise seen from above."""
    a = n_ref - (n_ref @ up) * up
    b = n_est - (n_est @ up) * up
    if a @ b < 0:
        b = -b
    return float(np.arctan2(up @ np.cross(a, b), a @ b))


def yaw_shift(s: np.ndarray, psi: np.ndarray, ray: np.ndarray, n: np.ndarray, up: np.ndarray):
    """First-order along-wall error when the wall plane is turned by yaw psi about a vertical axis
    through a point s metres (signed, along `along_wall_axis`) from the edge: -s psi (r.h)/(r.n)."""
    h = along_wall_axis(n, up)
    ray = np.atleast_2d(ray)
    return -np.asarray(s) * np.asarray(psi) * (ray @ h) / (ray @ n)


def midpoint_triangulate(c1, d1, c2, d2) -> tuple[np.ndarray, float]:
    """Midpoint of the shortest segment between rays c1 + t d1 and c2 + u d2, and the angle
    between the rays in degrees. NaN point for parallel rays or a point behind either camera."""
    d1 = d1 / np.linalg.norm(d1)
    d2 = d2 / np.linalg.norm(d2)
    w = c1 - c2
    b = d1 @ d2
    denom = 1.0 - b * b
    angle = float(np.degrees(np.arccos(np.clip(b, -1.0, 1.0))))
    if denom < 1e-12:
        return np.full(3, np.nan), angle
    t = (b * (d2 @ w) - (d1 @ w)) / denom
    u = ((d2 @ w) - b * (d1 @ w)) / denom
    if t <= 0 or u <= 0:
        return np.full(3, np.nan), angle
    return 0.5 * ((c1 + t * d1) + (c2 + u * d2)), angle


def ransac_planes(
    points: np.ndarray,
    normals: np.ndarray,
    up: np.ndarray,
    tol: float,
    max_tilt_deg: float,
    agree_deg: float = 25.0,
    min_inliers: int = 1500,
    max_planes: int = 40,
    hypotheses: int = 600,
    score_sample: int = 50_000,
    seed: int = 0,
) -> list[tuple[np.ndarray, float]]:
    """Sequential RANSAC for near-vertical planes. Each hypothesis is three nearby points; it is
    scored by points within `tol` whose own normal agrees within `agree_deg`, refitted by least
    squares on its inliers, and those inliers are removed before the next plane."""
    rng = np.random.default_rng(seed)
    sin_tilt = np.sin(np.radians(max_tilt_deg))
    cos_agree = np.cos(np.radians(agree_deg))
    remaining = np.arange(len(points))
    planes: list[tuple[np.ndarray, float]] = []

    def inliers(pts, nrm, n, d):
        return (np.abs(pts @ n - d) < tol) & (np.abs(nrm @ n) > cos_agree)

    while len(planes) < max_planes and len(remaining) >= min_inliers:
        pts = points[remaining].astype(np.float64)
        nrm = normals[remaining].astype(np.float64)
        k = min(64, len(pts))
        seeds = rng.integers(len(pts), size=hypotheses)
        _, nn = cKDTree(pts).query(pts[seeds], k=k)
        pick = nn[np.arange(hypotheses)[:, None], rng.integers(1, k, size=(hypotheses, 2))]
        a, b, c = pts[seeds], pts[pick[:, 0]], pts[pick[:, 1]]
        n = np.cross(b - a, c - a)
        norm = np.linalg.norm(n, axis=1)
        ok = norm > 1e-9
        n = n[ok] / norm[ok, None]
        a = a[ok]
        ok = np.abs(n @ up) <= sin_tilt
        n, a = n[ok], a[ok]
        if not len(n):
            break
        d = np.sum(n * a, axis=1)
        sub = rng.choice(len(pts), size=min(score_sample, len(pts)), replace=False)
        score = (np.abs(pts[sub] @ n.T - d) < tol) & (np.abs(nrm[sub] @ n.T) > cos_agree)
        best = int(np.argmax(score.sum(axis=0)))
        inl = inliers(pts, nrm, n[best], d[best])
        if inl.sum() < min_inliers:
            break
        nb, db = fit_plane(pts[inl], trim_rounds=0)
        if abs(nb @ up) <= sin_tilt:
            refit = inliers(pts, nrm, nb, db)
            if refit.sum() >= inl.sum():
                inl, n_best, d_best = refit, nb, db
            else:
                n_best, d_best = n[best], d[best]
        else:
            n_best, d_best = n[best], d[best]
        planes.append((n_best, float(d_best)))
        remaining = remaining[~inl]
    return planes
