"""Synthetic checks of the filter's parts that have one correct answer."""

from __future__ import annotations

import numpy as np
import pytest

from plane_filter import (
    apply_homography,
    covered_cells,
    covered_intervals,
    grouped_median,
    noise_sigma,
    parallax_gate,
    parallax_px,
    patch_pixels,
    plain_threshold,
    plane_homography,
    sample_bilinear,
    too_plain,
    zncc,
)


def rotation(axis_angle: np.ndarray) -> np.ndarray:
    theta = np.linalg.norm(axis_angle)
    k = axis_angle / theta
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(theta) * K + (1 - np.cos(theta)) * K @ K


def look_at(centre: np.ndarray, target: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """World-to-camera (R, t), OpenCV axes, looking from `centre` at `target`, world up -y."""
    z = (target - centre) / np.linalg.norm(target - centre)
    x = np.cross([0.0, -1.0, 0.0], z)
    x /= np.linalg.norm(x)
    y = np.cross(z, x)
    R = np.stack([x, y, z])
    return R, -R @ centre


def K_of(f: float, cx: float, cy: float) -> np.ndarray:
    return np.array([[f, 0, cx], [0, f * 1.001, cy], [0, 0, 1.0]])


# Plane-induced homography


@pytest.mark.parametrize("seed", range(5))
def test_homography_matches_unproject_then_project(seed):
    rng = np.random.default_rng(seed)
    n = rng.normal(size=3)
    n /= np.linalg.norm(n)
    d = rng.uniform(-2, 2)
    on_plane = n * d
    K_a, K_b = K_of(560, 512, 341), K_of(610, 500, 330)
    c_a = on_plane + 4 * n + rng.normal(size=3)
    c_b = on_plane + 3 * n + rng.normal(size=3)
    R_a, t_a = look_at(c_a, on_plane)
    R_b, t_b = look_at(c_b, on_plane)
    # Perturb B so the rotation isn't a pure look-at.
    R_b = rotation(np.array([0.02, -0.03, 0.05])) @ R_b
    t_b = -R_b @ c_b
    uv = rng.uniform([200, 150], [800, 550], size=(50, 2))

    rays = (R_a.T @ (np.linalg.inv(K_a) @ np.c_[uv, np.ones(50)].T)).T
    s = (d - n @ c_a) / (rays @ n)
    X = c_a + s[:, None] * rays
    assert np.allclose(X @ n, d)
    x_b = (K_b @ (R_b @ X.T + t_b[:, None])).T
    direct = x_b[:, :2] / x_b[:, 2:]

    H = plane_homography(K_a, R_a, t_a, K_b, R_b, t_b, n, d)
    assert np.allclose(apply_homography(H, uv), direct, atol=1e-8)


def test_homography_is_identity_for_the_same_camera():
    R, t = look_at(np.array([0.0, 0, -5]), np.zeros(3))
    K = K_of(560, 512, 341)
    H = plane_homography(K, R, t, K, R, t, np.array([0.0, 0, 1]), 0.0)
    assert np.allclose(H / H[2, 2], np.eye(3))


def test_homography_refuses_a_camera_on_the_plane():
    R, t = look_at(np.array([0.0, 0, 0]), np.array([0.0, 0, 5]))
    K = K_of(560, 512, 341)
    with pytest.raises(ValueError, match="on the plane"):
        plane_homography(K, R, t, K, R, t, np.array([1.0, 0, 0]), 0.0)


# Parallax gate


def stereo_pair(baseline: float):
    """Two cameras at z = 0, B `baseline` m to the right of A, both looking along +z."""
    K = K_of(560, 512, 341)
    K[1, 1] = 560
    R = np.eye(3)
    return K, R, np.zeros(3), R, np.array([-baseline, 0.0, 0.0])


def test_parallax_is_the_disparity_difference_of_the_two_planes():
    K, R_a, t_a, R_b, t_b = stereo_pair(0.3)
    n, wall = np.array([0.0, 0, 1]), 5.0  # wall at z = 5, the cameras at z = 0
    H_wall = plane_homography(K, R_a, t_a, K, R_b, t_b, n, wall)
    H_front = plane_homography(K, R_a, t_a, K, R_b, t_b, n, wall - 0.5)
    expected = 560 * 0.3 * (1 / 4.5 - 1 / 5.0)
    uv = np.array([[512.0, 341.0], [100.0, 600.0]])
    assert np.allclose(parallax_px(H_wall, H_front, uv), expected)


def test_parallax_gate_admits_at_three_px_and_refuses_just_below():
    n, wall = np.array([0.0, 0, 1]), 5.0
    per_metre = 560 * (1 / 4.5 - 1 / 5.0)  # parallax per metre of baseline
    uv = np.array([512.0, 341.0])
    for baseline, admitted in ((3.0 / per_metre, True), (2.99 / per_metre, False)):
        K, R_a, t_a, R_b, t_b = stereo_pair(baseline)
        H_wall = plane_homography(K, R_a, t_a, K, R_b, t_b, n, wall)
        H_front = plane_homography(K, R_a, t_a, K, R_b, t_b, n, wall - 0.5)
        p, ok = parallax_gate(H_wall, H_front, uv, 3.0 - 1e-9)
        assert ok is admitted, p


def test_parallax_gate_refuses_a_pure_rotation():
    K = K_of(560, 512, 341)
    R_b = rotation(np.array([0.0, 0.2, 0.0]))
    n, wall = np.array([0.0, 0, 1]), 5.0
    H_wall = plane_homography(K, np.eye(3), np.zeros(3), K, R_b, np.zeros(3), n, wall)
    H_front = plane_homography(K, np.eye(3), np.zeros(3), K, R_b, np.zeros(3), n, wall - 0.5)
    p, ok = parallax_gate(H_wall, H_front, np.array([512.0, 341.0]), 3.0)
    assert p == pytest.approx(0, abs=1e-9)
    assert not ok


# NCC


def test_zncc_values():
    rng = np.random.default_rng(0)
    a = rng.normal(size=(11, 11))
    assert zncc(a, a) == pytest.approx(1.0)
    assert zncc(a, 3 * a + 40) == pytest.approx(1.0)
    assert zncc(a, -a) == pytest.approx(-1.0)
    x = np.array([1.0, -1, 1, -1])
    y = np.array([1.0, 1, -1, -1])
    assert zncc(x, y) == pytest.approx(0.0)
    assert zncc(np.array([1.0, 2, 3, 4]), np.array([1.0, 2, 4, 3])) == pytest.approx(0.8)


def test_zncc_of_a_flat_patch_is_nan():
    assert np.isnan(zncc(np.full(121, 7.0), np.arange(121.0)))


def test_zncc_refuses_patches_of_different_size():
    with pytest.raises(ValueError, match="shapes differ"):
        zncc(np.zeros(121), np.zeros(120))


# Too plain


def test_plain_threshold_formula():
    assert plain_threshold(1.0, 0.6) == pytest.approx(1 / np.sqrt(0.4))
    assert plain_threshold(0.573, 0.6) == pytest.approx(0.906, abs=1e-3)
    with pytest.raises(ValueError):
        plain_threshold(1.0, 1.0)


def test_a_patch_at_the_threshold_matches_itself_at_the_ncc_it_was_derived_from():
    """The derivation: signal of deviation s, seen twice with independent noise sigma, correlates
    at s^2 / (s^2 + sigma^2) on average; at the threshold that is 0.6."""
    rng = np.random.default_rng(1)
    sigma = 2.0
    T = plain_threshold(sigma, 0.6)
    s = np.sqrt(T**2 - sigma**2)
    scores = []
    for _ in range(4000):
        signal = rng.normal(0, s, 121)
        scores.append(zncc(signal + rng.normal(0, sigma, 121), signal + rng.normal(0, sigma, 121)))
    assert np.mean(scores) == pytest.approx(0.6, abs=0.01)


def test_too_plain_is_strictly_below_the_threshold():
    patch = np.tile([0.0, 2.0], 60)  # standard deviation exactly 1
    assert not too_plain(patch, 1.0)
    assert too_plain(patch, 1.0 + 1e-9)
    assert too_plain(np.full((11, 11), 128.0), 0.5)


@pytest.mark.parametrize("sigma", [0.8, 3.0])
def test_noise_sigma_recovers_gaussian_noise_on_a_ramp(sigma):
    rng = np.random.default_rng(2)
    yy, xx = np.mgrid[0:400, 0:600]
    ramp = 50 + 0.2 * xx + 0.1 * yy  # planar intensity, cancelled by the operator
    img = np.clip(np.rint(ramp + rng.normal(0, sigma, ramp.shape)), 0, 255)
    assert noise_sigma(img) == pytest.approx(sigma, rel=0.08)


def test_grouped_median():
    # Half the values are 0 and half 2: the median sits at the top of 0's bin.
    assert grouped_median(np.array([0, 0, 2, 2])) == pytest.approx(0.5)
    # 1 fills [0.5, 1.5]; its bin holds the middle, three quarters in.
    assert grouped_median(np.array([0, 1, 1, 1, 1, 1, 1, 2])) == pytest.approx(0.5 + 3 / 6)
    with pytest.raises(ValueError):
        grouped_median(np.array([-1, 2]))


# Patches


def test_patch_pixels_and_bilinear_sampling():
    grid = patch_pixels((10.4, 20.6), 5)
    assert grid.shape == (121, 2)
    assert grid[:, 0].min() == 5 and grid[:, 0].max() == 15
    assert grid[:, 1].min() == 16 and grid[:, 1].max() == 26
    yy, xx = np.mgrid[0:40, 0:30].astype(np.float32)
    img = 3 * xx + 5 * yy
    uv = np.array([[2.25, 7.5], [29.0, 39.0], [0.0, 0.0]])
    assert np.allclose(sample_bilinear(img, uv), 3 * uv[:, 0] + 5 * uv[:, 1])
    assert sample_bilinear(img, np.array([[29.01, 3.0]])) is None
    assert sample_bilinear(img, np.array([[-0.01, 3.0]])) is None
    assert sample_bilinear(img, np.array([[np.nan, 3.0]])) is None


# The claim rule over surviving sightings


P = np.array([[0.0, 0, 0], [0.3, 0, 0], [0.2, 0, 0], [-0.2, 0, 0], [1.0, 0, 0], [1.1, 0, 0]])


def test_two_positions_apart_cover_every_row():
    assert covered_cells([(0, 5, [0, 1, 2]), (1, 5, [0, 1, 2])], P, 3, 0.25) == {5}


def test_positions_closer_than_the_baseline_do_not_cover():
    assert covered_cells([(0, 5, [0, 1, 2]), (2, 5, [0, 1, 2])], P, 3, 0.25) == set()


def test_rows_may_be_covered_by_different_photos():
    s = [(0, 5, [0, 1]), (1, 5, [0, 1]), (4, 5, [2]), (0, 5, [2])]
    assert covered_cells(s, P, 3, 0.25) == {5}


def test_a_row_left_without_two_positions_leaves_the_cell_unclaimed():
    s = [(0, 5, [0, 1]), (1, 5, [0, 1]), (4, 5, [2])]
    assert covered_cells(s, P, 3, 0.25) == set()


def test_a_row_keeps_its_first_position_as_the_app_does():
    # 0.2 and -0.2 are 0.4 apart, but each is within 0.25 of the first position, 0.0.
    s = [(0, 5, [0]), (2, 5, [0]), (3, 5, [0])]
    assert covered_cells(s, P, 1, 0.25) == set()
    # A later position far enough from the first completes the row.
    assert covered_cells([*s, (1, 5, [0])], P, 1, 0.25) == {5}


def test_dropping_a_sighting_can_uncover_a_cell():
    kept = [(0, 7, [0]), (1, 7, [0]), (4, 8, [0]), (5, 8, [0])]
    assert covered_cells(kept, P, 1, 0.25) == {7}  # 1.0 and 1.1 are 0.1 apart
    assert covered_cells(kept[1:], P, 1, 0.25) == set()


def test_cells_outside_the_marked_ends_are_ignored():
    s = [(0, 5, [0]), (1, 5, [0]), (0, 6, [0]), (1, 6, [0])]
    assert covered_cells(s, P, 1, 0.25, allowed={6}) == {6}


def test_covered_intervals_merge_split_and_clip():
    w = 0.5
    assert covered_intervals({1, 2, 4}, w, left=0.6, right=2.2) == [[0.6, 1.5], [2.0, 2.2]]
    assert covered_intervals(set(), w, 0, 1) == []
