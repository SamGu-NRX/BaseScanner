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
    out = walk_errors(ark, truth, np.zeros(len(truth)))
    for ft, w in out.items():
        assert len(w["truth"]) > 0
        np.testing.assert_allclose(w["truth"], ft * 0.3048, rtol=1e-12)
        np.testing.assert_allclose(w["ark"] / w["truth"], 0.98, rtol=1e-12)


def test_turn_and_heading():
    from evals.modern_arkit import heading, turn

    v = np.array([[0.0, 0.0, 1.0]])  # heading 0 (along +z)
    t = turn(v, np.array([np.pi / 2]))
    np.testing.assert_allclose(t, [[1.0, 0.0, 0.0]], atol=1e-12)  # heading +90 degrees (along +x)
    assert heading(t)[0] == pytest.approx(np.pi / 2)


def test_align_headings_recovers_a_mirrored_world():
    from evals.modern_arkit import align_headings

    # Truth walks along +x looking along +x. ARKit's world is the truth's mirrored in z (Unity's
    # left-handed axes) and turned 40 degrees; its identity quaternion looks along +z.
    truth = np.c_[np.arange(10.0), np.zeros(10), np.zeros(10)]
    truth_fwd = np.tile([1.0, 0.0, 0.0], (10, 1))
    R = rot_y(40)
    ark = (truth @ R.T) * np.array([1.0, 1.0, -1.0])
    # Camera forward in ARKit's (mirrored) world: +x turned the same way, then mirrored.
    fwd = (R @ np.array([1.0, 0.0, 0.0])) * np.array([1.0, 1.0, -1.0])
    # A quaternion (w, x, y, z) whose rotation takes +z to `fwd`: a turn about y.
    ang = np.arctan2(fwd[0], fwd[2])
    q = np.tile([np.cos(ang / 2), 0.0, np.sin(ang / 2), 0.0], (10, 1))
    p, delta, spread = align_headings(ark, q, truth, truth_fwd)
    assert spread == pytest.approx(0.0, abs=1e-6)
    turned = np.c_[
        p[:, 0] * np.cos(delta) + p[:, 2] * np.sin(delta),
        p[:, 1],
        p[:, 2] * np.cos(delta) - p[:, 0] * np.sin(delta),
    ]
    np.testing.assert_allclose(turned - turned[0], truth - truth[0], atol=1e-9)
