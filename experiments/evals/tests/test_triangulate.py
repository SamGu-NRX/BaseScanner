"""Hand-computed cases for per-photo depth scales from triangulated features."""

import cv2
import numpy as np
import pytest

from evals.triangulate import (
    ScaleFit,
    projection,
    sample_depth,
    triangulate,
    triangulate_pair,
    view_scales,
)

F, W, H = 500.0, 640, 480
K0 = np.array([[F, 0, (W - 1) / 2], [0, F, (H - 1) / 2], [0, 0, 1.0]])


def _pose(center, R=None) -> np.ndarray:
    T = np.eye(4)
    if R is not None:
        T[:3, :3] = R
    T[:3, 3] = center
    return T


def _project(K, T, X):
    p = projection(K, T) @ np.r_[X, 1.0]
    return p[:2] / p[2]


def test_sample_depth_bilinear_and_invalid():
    d = np.array([[1.0, 2.0, 5.0], [3.0, 4.0, np.nan]])
    uv = np.array([[0.5, 0.5], [0.0, 0.0], [0.25, 0.0], [1.5, 0.5], [-0.1, 0.0], [0.0, 1.0]])
    got = sample_depth(d, uv)
    # Centre of the first 2x2 block: mean of 1, 2, 3, 4. A quarter of the way from 1 to 2 is 1.25.
    np.testing.assert_allclose(got[:3], [2.5, 1.0, 1.25])
    # A NaN neighbour, a position left of the image, and the last row (no row below) give NaN.
    assert np.isnan(got[3:]).all()


def test_triangulate_recovers_known_point():
    X = np.array([0.3, -0.2, 5.0])
    c = np.cos(np.radians(10))
    s = np.sin(np.radians(10))
    T1 = _pose([0.0, 0.0, 0.0])
    # Second camera 1 m to the right, turned 10 degrees left (about camera y) toward the point.
    T2 = _pose([1.0, 0.1, 0.2], np.array([[c, 0, -s], [0, 1, 0], [s, 0, c]]))
    x1, x2 = _project(K0, T1, X), _project(K0, T2, X)
    got = triangulate(projection(K0, T1), projection(K0, T2), x1[None], x2[None])
    np.testing.assert_allclose(got[0], X, atol=1e-9)


def test_filters_reject_tiny_baseline_and_displaced_match():
    X = np.array([0.0, 0.0, 5.0])
    T1 = _pose([0.0, 0.0, 0.0])
    wide, tiny = _pose([1.0, 0.0, 0.0]), _pose([0.001, 0.0, 0.0])

    def run(T2, shift):
        x1 = _project(K0, T1, X)[None]
        x2 = _project(K0, T2, X)[None] + np.array(shift)
        return triangulate_pair(K0, T1, K0, T2, x1, x2, max_reproj_px=2.0, min_angle_deg=2.0)

    # 1 m baseline at 5 m: rays about 11 degrees apart, kept.
    assert run(wide, [0.0, 0.0]).keep[0]
    # 1 mm baseline: rays 0.011 degrees apart, rejected by the angle test.
    assert not run(tiny, [0.0, 0.0]).keep[0]
    # The baseline is along x, so a 10 px shift in y cannot be explained by any depth: the best
    # point leaves about 5 px of error in each view, rejected by the reprojection test.
    assert not run(wide, [0.0, 10.0]).keep[0]


def _plane_scene():
    """Three photos of a textured plane 4 m ahead, cameras with no rotation, 0.4 m apart in x and
    in y. At f = 500 px a 0.4 m shift moves the plane's image by exactly 500 * 0.4 / 4 = 50 px, so
    each photo is an integer crop of one texture and the true depth is 4 m at every pixel."""
    noise = np.random.default_rng(0).uniform(0, 255, (H + 100, W + 100)).astype(np.float32)
    tex = cv2.normalize(cv2.GaussianBlur(noise, (0, 0), 2.0), None, 0, 255, cv2.NORM_MINMAX)
    tex = tex.astype(np.uint8)
    # A camera at +x sees the plane shifted left in its image: its crop starts 50 px further right.
    images = {
        "a": tex[0:H, 0:W].copy(),
        "b": tex[0:H, 50 : 50 + W].copy(),
        "c": tex[50 : 50 + H, 0:W].copy(),
    }
    poses = {
        "a": _pose([0.0, 0.0, 0.0]),
        "b": _pose([0.4, 0.0, 0.0]),
        "c": _pose([0.0, 0.4, 0.0]),
    }
    K = {n: K0 for n in images}
    return images, K, poses


def test_view_scales_undo_depth_scale():
    images, K, poses = _plane_scene()
    depth = {n: np.full((H, W), 4.0 * 1.25) for n in images}
    fits = view_scales(images, K, poses, depth)
    for n, fit in fits.items():
        assert fit.points >= 100, n
        assert fit.scale == pytest.approx(0.8, rel=1e-4), n
        assert fit.spread < 0.01, n


def test_view_scales_follow_pose_scale():
    """Poses stretched by 0.9 about the first camera triangulate the plane at 0.9 x 4 m; the fit
    trusts the poses, so each depth map is scaled by 0.9 / 1.25."""
    images, K, poses = _plane_scene()
    origin = poses["a"][:3, 3]
    shrunk = {}
    for n, T in poses.items():
        S = T.copy()
        S[:3, 3] = origin + 0.9 * (T[:3, 3] - origin)
        shrunk[n] = S
    depth = {n: np.full((H, W), 4.0 * 1.25) for n in images}
    fits = view_scales(images, K, shrunk, depth)
    for n, fit in fits.items():
        assert fit.scale == pytest.approx(0.9 / 1.25, rel=1e-4), n


def test_view_scales_skips_invalid_depth_and_reports_too_few_points():
    images, K, poses = _plane_scene()
    depth = {n: np.full((H, W), 5.0) for n in images}
    depth["a"][:] = np.nan
    fits = view_scales(images, K, poses, depth)
    assert fits["a"] == ScaleFit(scale=None, points=0, spread=None)
    assert fits["b"].scale == pytest.approx(0.8, rel=1e-4)
    few = view_scales(images, K, poses, depth, min_points=100_000)["b"]
    assert few.scale is None and few.spread is None and few.points == fits["b"].points


def test_view_scales_rejects_mismatched_inputs():
    images, K, poses = _plane_scene()
    depth = {n: np.full((H, W), 5.0) for n in images}
    del depth["c"]
    with pytest.raises(ValueError, match="depth names"):
        view_scales(images, K, poses, depth)
    depth["c"] = np.full((H, W + 1), 5.0)
    with pytest.raises(ValueError, match=r"c: depth \(480, 641\) != image \(480, 640\)"):
        view_scales(images, K, poses, depth)
