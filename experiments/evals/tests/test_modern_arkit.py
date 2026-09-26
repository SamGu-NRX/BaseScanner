"""Hand-computed cases for the modern-iPhone ARKit scale measurement."""

import numpy as np
import pytest

from evals.geometry import rot_y
from evals.modern_arkit import level_frame, walk_errors


def test_level_frame_finds_the_vertical_of_a_tilted_walk():
    # A walk on the plane z = 0.5 x (tilted), with the plane normal (-0.5, 0, 1) / |.|.
    xs, ys = np.meshgrid(np.linspace(0, 20, 21), np.linspace(0, 10, 11))
    pts = np.c_[xs.ravel(), ys.ravel(), 0.5 * xs.ravel()]
    normal = np.array([-0.5, 0.0, 1.0]) / np.hypot(0.5, 1.0)
    assert abs(level_frame(pts)[2] @ normal) == pytest.approx(1.0)


def test_walk_errors_of_a_tracker_reading_two_percent_short():
    truth = np.c_[np.arange(0, 20.0, 0.25), np.zeros(80), np.zeros(80)]  # 20 m along x, y up
    ark = 0.98 * truth @ rot_y(70).T  # 2% short, in its own world heading
    out = walk_errors(ark, truth)
    for ft, w in out.items():
        assert len(w["truth"]) > 0
        np.testing.assert_allclose(w["truth"], ft * 0.3048, rtol=1e-12)
        np.testing.assert_allclose(w["ark"] / w["truth"], 0.98, rtol=1e-12)
