"""Summaries in inches, and a bootstrap over points for p90."""

from __future__ import annotations

import numpy as np

M_PER_IN = 0.0254


def summary(err_m: np.ndarray, points: np.ndarray | None = None) -> dict:
    """Median and p90 of |error| in inches, with the number of values and of distinct points."""
    e = np.abs(np.asarray(err_m, np.float64))
    e = e[np.isfinite(e)]
    out: dict = {"n": len(e)}
    if points is not None:
        pts = np.asarray(points)[np.isfinite(np.asarray(err_m, np.float64))]
        out["points"] = len(np.unique(pts))
    if len(e):
        out["median_in"] = round(float(np.median(e)) / M_PER_IN, 2)
        out["p90_in"] = round(float(np.percentile(e, 90)) / M_PER_IN, 2)
    return out


def bootstrap_p90(err_m: np.ndarray, points: np.ndarray, reps: int = 2000, seed: int = 7):
    """95% percentile-bootstrap interval of the p90 of |error| in inches, resampling points with
    replacement and keeping every value of a drawn point (draws of one point are not independent)."""
    e = np.abs(np.asarray(err_m, np.float64))
    ok = np.isfinite(e)
    e, pts = e[ok], np.asarray(points)[ok]
    if len(e) < 2:
        return None
    _, cluster = np.unique(pts, return_inverse=True)
    n_clusters = cluster.max() + 1
    order = np.argsort(e)
    e_sorted, c_sorted = e[order], cluster[order]
    rng = np.random.default_rng(seed)
    p90 = np.empty(reps)
    for b in range(reps):
        weight = np.bincount(rng.integers(n_clusters, size=n_clusters), minlength=n_clusters)
        w = weight[c_sorted].astype(np.float64)
        cum = np.cumsum(w)
        p90[b] = e_sorted[np.searchsorted(cum, 0.9 * cum[-1])]
    lo, hi = np.percentile(p90, [2.5, 97.5]) / M_PER_IN
    return [round(float(lo), 2), round(float(hi), 2)]
