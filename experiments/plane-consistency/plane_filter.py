"""The parts of the plane-consistency filter that have one correct answer.

Cameras are world-to-camera (R, t) in OpenCV axes (+x right, +y down, +z forward), with pixel
centres on integers. A plane is n . X = d in world coordinates, n a unit vector.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence

import cv2
import numpy as np


def plane_homography(
    K_a: np.ndarray,
    R_a: np.ndarray,
    t_a: np.ndarray,
    K_b: np.ndarray,
    R_b: np.ndarray,
    t_b: np.ndarray,
    n: np.ndarray,
    d: float,
) -> np.ndarray:
    """The 3x3 map from pixels of camera A to pixels of camera B of points on the plane n . X = d.

    In A's frame the plane is n_a . X_a = d_a with n_a = R_a n and d_a = d + n_a . t_a. A point on
    it maps to B's frame as X_b = (R + t n_a^T / d_a) X_a, where R and t take A's frame to B's.
    """
    n_a = R_a @ n
    d_a = d + n_a @ t_a
    if abs(d_a) < 1e-9:
        raise ValueError("camera A lies on the plane; its homography is undefined")
    R = R_b @ R_a.T
    t = t_b - R @ t_a
    return K_b @ (R + np.outer(t, n_a) / d_a) @ np.linalg.inv(K_a)


def apply_homography(H: np.ndarray, uv: np.ndarray) -> np.ndarray:
    """Pixels (..., 2) through H. Points H sends to infinity come back as inf or NaN."""
    uv = np.asarray(uv, dtype=np.float64)
    p = uv @ H[:, :2].T + H[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        return p[..., :2] / p[..., 2:3]


def parallax_px(H_wall: np.ndarray, H_front: np.ndarray, uv: np.ndarray) -> np.ndarray:
    """How far apart in B the wall plane and a plane in front of it put A's pixel `uv`."""
    return np.linalg.norm(apply_homography(H_wall, uv) - apply_homography(H_front, uv), axis=-1)


def parallax_gate(
    H_wall: np.ndarray, H_front: np.ndarray, uv: np.ndarray, min_px: float
) -> tuple[float, bool]:
    """The pair's parallax at `uv`, and whether it is enough to tell the two planes apart."""
    p = float(parallax_px(H_wall, H_front, uv))
    return p, p >= min_px


def zncc(a: np.ndarray, b: np.ndarray) -> float:
    """Zero-mean normalized cross-correlation of two equal-shaped patches, NaN if either is flat."""
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    if a.shape != b.shape:
        raise ValueError(f"patch shapes differ: {a.shape} vs {b.shape}")
    a = a - a.mean()
    b = b - b.mean()
    denom = np.sqrt((a @ a) * (b @ b))
    return float(a @ b / denom) if denom > 0 else float("nan")


def plain_threshold(noise_sigma: float, ncc_min: float) -> float:
    """Patch standard deviation below which even a perfect match cannot reach `ncc_min`.

    A patch with signal standard deviation s, seen twice with independent noise sigma, has an
    expected ZNCC of s^2 / (s^2 + sigma^2). With the observed deviation T = sqrt(s^2 + sigma^2),
    that is 1 - sigma^2 / T^2, which reaches `ncc_min` only when T >= sigma / sqrt(1 - ncc_min).
    """
    if not 0 <= ncc_min < 1:
        raise ValueError(f"ncc_min must be in [0, 1), got {ncc_min}")
    return noise_sigma / np.sqrt(1.0 - ncc_min)


def too_plain(patch: np.ndarray, threshold: float) -> bool:
    return float(np.std(np.asarray(patch, dtype=np.float64))) < threshold


def noise_sigma(gray: np.ndarray) -> float:
    """Robust image noise standard deviation (Immerkaer's operator, median instead of mean).

    The 3x3 operator below cancels any locally planar intensity, and applied to white noise of
    deviation sigma it gives deviation 6 sigma (its weights' squares sum to 36). The median of its
    absolute response, over 0.6745 for a Gaussian, ignores the minority of pixels on edges.

    On an 8-bit image the response is a whole number, so a plain median moves in steps of 0.25
    grey levels of sigma. The median is instead read off the histogram with each whole number k
    spread over [k - 0.5, k + 0.5] (the grouped-data median).
    """
    kernel = np.array([[1, -2, 1], [-2, 4, -2], [1, -2, 1]], dtype=np.float32)
    response = cv2.filter2D(gray.astype(np.float32), -1, kernel, borderType=cv2.BORDER_REFLECT)
    return grouped_median(np.abs(response[1:-1, 1:-1])) / (0.6745 * 6.0)


def grouped_median(values: np.ndarray) -> float:
    """Median of non-negative whole numbers, each k taken as spread evenly over [k - 0.5, k + 0.5]
    (0 over [0, 0.5])."""
    k = np.rint(values).astype(np.int64).ravel()
    if k.size == 0 or k.min() < 0:
        raise ValueError("grouped_median needs non-negative values")
    counts = np.bincount(k)
    cdf = np.cumsum(counts) / k.size
    m = int(np.searchsorted(cdf, 0.5))
    below = cdf[m - 1] if m else 0.0
    lo, width = (0.0, 0.5) if m == 0 else (m - 0.5, 1.0)
    return float(lo + (0.5 - below) / (counts[m] / k.size) * width)


def patch_pixels(centre: Sequence[float], half: int) -> np.ndarray:
    """(2*half+1)^2 integer pixels (u, v) around `centre` rounded to the nearest pixel, (N, 2)."""
    cu, cv_ = round(centre[0]), round(centre[1])
    du, dv = np.meshgrid(np.arange(-half, half + 1), np.arange(-half, half + 1))
    return np.stack([cu + du.ravel(), cv_ + dv.ravel()], axis=-1).astype(np.float64)


def sample_bilinear(image: np.ndarray, uv: np.ndarray) -> np.ndarray | None:
    """Bilinear samples of a single-channel float image at pixels uv (N, 2); None if any falls
    outside the image."""
    h, w = image.shape
    u, v = uv[:, 0], uv[:, 1]
    if not (np.all(np.isfinite(uv)) and u.min() >= 0 and v.min() >= 0):
        return None
    if u.max() > w - 1 or v.max() > h - 1:
        return None
    u0 = np.minimum(np.floor(u).astype(np.int64), w - 2)
    v0 = np.minimum(np.floor(v).astype(np.int64), h - 2)
    fu, fv = u - u0, v - v0
    top = image[v0, u0] * (1 - fu) + image[v0, u0 + 1] * fu
    bottom = image[v0 + 1, u0] * (1 - fu) + image[v0 + 1, u0 + 1] * fu
    return top * (1 - fv) + bottom * fv


def covered_cells(
    sightings: Iterable[tuple[int, int, Iterable[int]]],
    positions: np.ndarray,
    rows: int,
    baseline: float,
    allowed: Iterable[int] | None = None,
) -> set[int]:
    """`CoverageMap.record` (HouseScanKit beede15, CoverageMap.swift lines 171-195) over a list of
    (photo, cell, rows seen) in capture order: the cells every row of which holds two camera
    positions at least `baseline` apart.

    Like the app, a row keeps the first position that sees it and then the first later one far
    enough from it, and stops at two, so a pair that only a third position would complete is not
    found. `allowed`, if given, is the set of cells inside the marked ends.
    """
    allow = None if allowed is None else set(allowed)
    held: dict[int, list[list[np.ndarray]]] = {}
    for photo, cell, seen in sightings:
        if allow is not None and cell not in allow:
            continue
        cell_rows = held.setdefault(cell, [[] for _ in range(rows)])
        p = positions[photo]
        for r in seen:
            if not 0 <= r < rows:
                continue
            kept = cell_rows[r]
            if len(kept) < 2 and all(np.linalg.norm(q - p) >= baseline for q in kept):
                kept.append(p)
    return {c for c, rs in held.items() if all(len(k) >= 2 for k in rs)}


def covered_intervals(
    cells: Iterable[int], cell_width: float, left: float, right: float
) -> list[list[float]]:
    """`CoverageMap.coveredIntervals` (lines 335-349): covered cells merged into runs of s, the
    first and last run clipped to the marked ends."""
    runs: list[list[float]] = []
    for index in sorted(cells):
        lo, hi = index * cell_width, (index + 1) * cell_width
        if runs and abs(runs[-1][1] - lo) < cell_width * 0.01:
            runs[-1][1] = hi
        else:
            runs.append([lo, hi])
    if runs:
        runs[0][0] = max(runs[0][0], left)
        runs[-1][1] = min(runs[-1][1], right)
    return runs
