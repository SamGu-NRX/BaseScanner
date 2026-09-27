"""Hand-computed cases for the drift metric code."""

import numpy as np
import pytest

from evals.drift import (
    distance_errors,
    gps_local_meters,
    horizontal_path_length,
    position_errors,
    similarity_scale_2d,
    three_cornered_hat,
    tracking_failure_time,
    window_pairs,
    yaw_between,
)
from evals.geometry import rot_y


def _straight_walk(n: int, step: float) -> np.ndarray:
    """Walk along +x at `step` meters per sample, y up."""
    p = np.zeros((n, 3))
    p[:, 0] = np.arange(n) * step
    return p


def test_horizontal_path_ignores_height():
    p = np.array([[0, 0, 0], [3, 5, 4], [3, 9, 4]], dtype=float)
    np.testing.assert_allclose(horizontal_path_length(p), [0, 5, 5])


def test_window_pairs_hand_case():
    ref = _straight_walk(10, 0.5)  # 0, 0.5, ..., 4.5 m
    i, j = window_pairs(ref, 1.0, 3)  # starts 0, 3, 6, 9; 1 m is exactly two samples later
    np.testing.assert_array_equal(i, [0, 3, 6])
    np.testing.assert_allclose(j, [2, 5, 8])


def test_window_ends_between_samples():
    ref = _straight_walk(10, 0.5)
    # 0.75 m lands halfway between samples 1 and 2, not on the first sample past it.
    i, j = window_pairs(ref, 0.75, 100)
    np.testing.assert_allclose(j, [1.5])
    est = ref * 0.8
    np.testing.assert_allclose(distance_errors(est, ref, i, j), [-0.15])


def test_distance_error_for_a_short_reading_track():
    ref = _straight_walk(31, 0.1)  # 3 m
    est = ref * 0.9  # reads 10 % short
    i, j = window_pairs(ref, 3.0, 100)
    np.testing.assert_allclose(distance_errors(est, ref, i, j), [-0.3])


def test_distance_error_is_blind_to_heading():
    ref = _straight_walk(21, 0.1)
    est = ref @ rot_y(40).T  # same walk, different world heading
    i, j = window_pairs(ref, 2.0, 100)
    np.testing.assert_allclose(distance_errors(est, ref, i, j), [0.0], atol=1e-12)


def test_position_error_uses_start_heading():
    ref = _straight_walk(21, 0.1)
    est = ref @ rot_y(40).T
    # Orientations say the estimate's world is turned 40 degrees: after undoing it the walks match.
    est_R = np.stack([rot_y(40)] * 21)
    ref_R = np.stack([np.eye(3)] * 21)
    i, j = window_pairs(ref, 2.0, 100)
    np.testing.assert_allclose(position_errors(est, ref, est_R, ref_R, i, j), [0.0], atol=1e-12)
    # With no heading information the same walk is off by the chord of a 40 degree turn over 2 m.
    same = np.stack([np.eye(3)] * 21)
    chord = 2 * 2.0 * np.sin(np.radians(20))
    np.testing.assert_allclose(position_errors(est, ref, same, same, i, j), [chord])


def test_yaw_between_extracts_heading_only():
    tilt = np.array([[1, 0, 0], [0, np.cos(0.3), -np.sin(0.3)], [0, np.sin(0.3), np.cos(0.3)]])
    Y = yaw_between(tilt, rot_y(25) @ tilt)
    np.testing.assert_allclose(Y, rot_y(25), atol=1e-12)


def test_three_cornered_hat_algebra():
    # Own variances 1, 4, 9: pairwise difference variances 5, 10, 13.
    assert three_cornered_hat(5.0, 10.0, 13.0) == pytest.approx((1.0, 4.0, 9.0))


def test_similarity_scale_with_reflection():
    src = np.array([[0.0, 0], [10, 0], [10, 5], [0, 5]])
    # Scale 0.8, mirrored (x-z plane vs east-north), rotated 30 degrees, shifted.
    c, s = np.cos(np.radians(30)), np.sin(np.radians(30))
    R = np.array([[c, -s], [s, c]])
    dst = 0.8 * (src * [1, -1]) @ R.T + [3, -7]
    scale, res = similarity_scale_2d(src, dst)
    assert scale == pytest.approx(0.8)
    assert res.max() == pytest.approx(0, abs=1e-9)


def test_gps_local_meters_one_degree_north():
    en = gps_local_meters(np.array([60.0, 61.0]), np.array([25.0, 25.0]))
    assert en[1, 0] == pytest.approx(0)
    assert en[1, 1] == pytest.approx(6_371_000 * np.pi / 180)


def test_tracking_failure_time():
    p = _straight_walk(5, 0.15)  # 1.5 m/s at 10 Hz
    t = np.arange(5) / 10
    assert tracking_failure_time(p, t) is None
    p[3:, 0] += 2.0  # a 2 m jump between samples 2 and 3
    assert tracking_failure_time(p, t) == pytest.approx(0.2)


def test_position_error_with_scale_removed():
    ref = _straight_walk(21, 0.1)
    est = 0.9 * ref  # 10% short, same heading
    R = np.stack([np.eye(3)] * 21)
    i, j = window_pairs(ref, 2.0, 100)
    np.testing.assert_allclose(position_errors(est, ref, R, R, i, j), [0.2])
    np.testing.assert_allclose(position_errors(est, ref, R, R, i, j, 0.9), [0.0], atol=1e-12)
