"""Hand-computed cases for the geometry and camera-convention code."""

import numpy as np
import pytest

from evals.camera import (
    DEVICE_TO_LANDSCAPE_CAMERA,
    column_major,
    landscape_intrinsics_from_portrait,
    landscape_pose,
    relative_rotation_cv,
)
from evals.check_replay import epipolar_distances, fundamental
from evals.geometry import (
    path_length,
    quat_wxyz_to_matrix,
    rot_y,
    rotation_angle_deg,
    umeyama,
    yaw_align,
)
from evals.replay import select_keyframes


def test_quaternion_90_about_z_maps_x_to_y():
    s = np.sqrt(0.5)
    R = quat_wxyz_to_matrix(np.array([s, 0, 0, s]))
    np.testing.assert_allclose(R @ [1, 0, 0], [0, 1, 0], atol=1e-12)
    np.testing.assert_allclose(R @ [0, 1, 0], [-1, 0, 0], atol=1e-12)


def test_rotation_angle():
    assert rotation_angle_deg(np.eye(3), rot_y(30)) == pytest.approx(30)
    assert rotation_angle_deg(rot_y(10), rot_y(-20)) == pytest.approx(30)


def test_rot_y_right_handed():
    # +90 about +y takes +z to +x.
    np.testing.assert_allclose(rot_y(90) @ [0, 0, 1], [1, 0, 0], atol=1e-12)


def test_landscape_intrinsics_hand_computed():
    # Portrait 720 wide, OpenCV principal point (359.5, 639.5) is the exact centre; the landscape
    # image is 1280 x 720 and its continuous centre is (640, 360). Focal lengths swap.
    fx, fy, cx, cy = landscape_intrinsics_from_portrait(1000.0, 1010.0, 359.5, 639.5, 720)
    assert (fx, fy, cx, cy) == (1010.0, 1000.0, 640.0, 360.0)


def test_landscape_camera_axes_for_upright_portrait_phone():
    # Phone upright in portrait, screen facing the user, looking along world -z: device frame is the
    # world frame. The landscape image's right edge is the portrait screen's bottom (world -y) and
    # its up is the portrait screen's right (world +x). The camera still looks along world -z.
    T = landscape_pose(np.zeros(3), np.eye(3))
    R = T[:3, :3]
    np.testing.assert_allclose(R[:, 0], [0, -1, 0])
    np.testing.assert_allclose(R[:, 1], [1, 0, 0])
    np.testing.assert_allclose(R[:, 2], [0, 0, 1])
    assert np.linalg.det(DEVICE_TO_LANDSCAPE_CAMERA) == pytest.approx(1)


def test_column_major_layout():
    T = np.arange(16, dtype=float).reshape(4, 4)
    # Column by column: first four numbers are the first column.
    assert column_major(T)[:4] == [0.0, 4.0, 8.0, 12.0]


def test_relative_rotation_identity_and_yaw():
    np.testing.assert_allclose(relative_rotation_cv(np.eye(3), np.eye(3)), np.eye(3))
    # Camera j is camera i turned 10 degrees left (about world +y): relative angle is 10 degrees.
    assert rotation_angle_deg(
        np.eye(3), relative_rotation_cv(np.eye(3), rot_y(10))
    ) == pytest.approx(10)


def _kf(T: np.ndarray, intr=(500.0, 500.0, 320.0, 240.0)) -> dict:
    return {"pose": column_major(T), "intrinsics": list(intr)}


def test_fundamental_zero_for_true_correspondence():
    # Camera a at origin, camera b 1 m to the right (+x), both looking along -z (Measure Lab frame).
    Ta, Tb = np.eye(4), np.eye(4)
    Tb[0, 3] = 1.0
    X = np.array([0.3, -0.2, -4.0])  # world point 4 m in front

    def project(T, X):
        Xc = T[:3, :3].T @ (X - T[:3, 3])
        # Measure Lab: u = fx x/(-z) + cx, v = -fy y/(-z) + cy (continuous) -> OpenCV subtract 0.5
        u = 500 * Xc[0] / -Xc[2] + 320 - 0.5
        v = -500 * Xc[1] / -Xc[2] + 240 - 0.5
        return np.array([[u, v]])

    F = fundamental(_kf(Ta), _kf(Tb))
    d = epipolar_distances(F, project(Ta, X), project(Tb, X))
    assert d[0] == pytest.approx(0, abs=1e-9)
    # Moving the point in b off the (horizontal) epipolar line by 7 px vertically gives 7 px in b.
    pb = project(Tb, X) + np.array([0.0, 7.0])
    d2 = epipolar_distances(F, project(Ta, X), pb)
    assert d2[0] == pytest.approx(7, rel=1e-6)


def test_umeyama_recovers_similarity():
    rng = np.random.default_rng(0)
    src = rng.normal(size=(20, 3))
    R = rot_y(33)
    dst = 2.5 * src @ R.T + [1, 2, 3]
    s, R_est, t = umeyama(src, dst, with_scale=True)
    assert s == pytest.approx(2.5)
    np.testing.assert_allclose(R_est, R, atol=1e-9)
    np.testing.assert_allclose(t, [1, 2, 3], atol=1e-9)


def test_yaw_align_hand_case():
    src = np.array([[1.0, 0, 0], [0, 0, 1], [0, 1, 0], [2, 0, 2]])
    dst = src @ rot_y(-40).T + [5, 0, -1]
    R, t = yaw_align(src, dst, up_axis=1)
    np.testing.assert_allclose(R, rot_y(-40), atol=1e-12)
    np.testing.assert_allclose(t, [5, 0, -1], atol=1e-12)


def test_path_length():
    p = np.array([[0, 0, 0], [3, 4, 0], [3, 4, 2]], dtype=float)
    np.testing.assert_allclose(path_length(p), [0, 5, 7])


def test_select_keyframes_spacing_rule():
    p = np.array([[0, 0, 0], [0.3, 0, 0], [0.5, 0, 0], [0.6, 0, 0], [1.0, 0, 0]], dtype=float)
    R = np.stack([np.eye(3)] * 4 + [rot_y(0)])
    assert select_keyframes(p, R, 0.5, 15) == [0, 2, 4]
    # A 20 degree turn in place is enough on its own.
    R2 = np.stack([np.eye(3), rot_y(20)])
    assert select_keyframes(np.zeros((2, 3)), R2, 0.5, 15) == [0, 1]
