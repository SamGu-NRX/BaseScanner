"""Hand-computed cases for AR-like pose degradation, normals, and the fixed-set prediction logic."""

from dataclasses import dataclass

import numpy as np
import pytest

from evals.ar_poses import PoseError, degrade, small_rotation
from evals.eth3d import point_normals
from evals.geometry import rotation_angle_deg
from evals.recon import predict


def test_degrade_scales_offsets_from_first_camera():
    T = [np.eye(4), np.eye(4)]
    T[1][:3, 3] = [2.0, 0.0, 4.0]
    no_noise = PoseError((0.9,), 0.0, 0.0, 2.0)
    out = degrade(T, 0.9, no_noise, np.random.default_rng(0))
    np.testing.assert_allclose(out[0][:3, 3], [0, 0, 0])
    np.testing.assert_allclose(out[1][:3, 3], [1.8, 0.0, 3.6])
    np.testing.assert_allclose(out[1][:3, :3], np.eye(3))


def test_small_rotation_angle():
    R = small_rotation(np.radians([0.0, 0.0, 30.0]))
    assert rotation_angle_deg(np.eye(3), R) == pytest.approx(30.0)
    np.testing.assert_allclose(R @ [1, 0, 0], [np.cos(np.pi / 6), np.sin(np.pi / 6), 0], atol=1e-12)


def test_point_normals_of_a_plane():
    xs, ys = np.meshgrid(np.arange(10.0), np.arange(10.0))
    plane = np.c_[xs.ravel(), ys.ravel(), np.zeros(100)] * 0.1
    n = point_normals(plane, k=8)
    np.testing.assert_allclose(np.abs(n[:, 2]), 1.0, atol=1e-9)


@dataclass
class _View:
    center: np.ndarray


class _Scene:
    """Two cameras on the z axis, about 2 m and 10 m from three points at z = 5 m."""

    def __init__(self):
        self.cands = np.array([[0.0, 0, 5], [1.0, 0, 5], [2.0, 0, 5]])
        self.views = {"a": _View(np.array([0.0, 0, 3])), "b": _View(np.array([0.0, 0, -5]))}
        # Both views see points 0 and 1; only b sees point 2. uv is unused by the stub depth below.
        self._vis = {
            "a": (np.array([0, 1]), np.zeros((2, 2))),
            "b": (np.array([0, 1, 2]), np.zeros((3, 2))),
        }

    def visible(self, name):
        index, uv = self._vis[name]
        return index, uv, np.zeros(len(index), bool)


@dataclass
class _EvalSet:
    index: np.ndarray
    gt: np.ndarray


def test_predict_filters_each_view_by_its_own_range(monkeypatch):
    scene = _Scene()
    ev = _EvalSet(index=np.array([0, 1, 2]), gt=scene.cands)
    # Each view "predicts" the true point plus its own offset: a +1 m in x, b +3 m in x.
    offsets = {"a": np.array([1.0, 0, 0]), "b": np.array([3.0, 0, 0])}

    def fake_camera_points(depth, K, uv):  # returns camera-frame points = world (identity pose)
        return depth[: len(uv)]

    monkeypatch.setattr("evals.recon.camera_points", fake_camera_points)

    def per_view(name):
        index, _, _ = scene.visible(name)
        return scene.cands[index] + offsets[name], np.eye(3), np.eye(4), False

    # No range limit: points 0 and 1 average a and b (+2 m), point 2 only b (+3 m).
    pts = predict(scene, ev, ["a", "b"], per_view, None)
    np.testing.assert_allclose(pts.r[:, 0] - scene.cands[:, 0], [2.0, 2.0, 3.0])
    # Within 6 m: camera b is 10 m from every point, so only a contributes; point 2 has none.
    pts = predict(scene, ev, ["a", "b"], per_view, 6.0)
    np.testing.assert_allclose(pts.r[:2, 0] - scene.cands[:2, 0], [1.0, 1.0])
    assert np.isnan(pts.r[2]).all()
