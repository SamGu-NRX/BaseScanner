"""Hand-computed cases for the coverage eval's geometry, truth and cause bookkeeping."""

from collections import Counter

import numpy as np

from evals.coverage import (
    Wall,
    app_gates,
    app_pixels,
    deficient_rows,
    face_offsets,
    in_intervals,
    majority,
    project,
    rotation_to_y,
    straight_runs,
    to_arkit,
    two_positions,
)
from evals.eth3d import View

CFG = {
    "cellWidth": 0.1524,
    "wallBandHeight": 1.9812,
    "groundBandDepth": 1.2,
    "maxDistance": 6.0,
    "maxAngleFromNormal": np.radians(65),
    "imageMargin": 0.03,
    "rowsPerBand": 3,
    "coveringBaseline": 0.25,
}


def test_rotation_to_y_levels_a_tilted_up():
    up = np.array([np.sin(np.radians(10)), np.cos(np.radians(10)), 0.0])
    R = rotation_to_y(up)
    np.testing.assert_allclose(R @ up, [0, 1, 0], atol=1e-12)
    np.testing.assert_allclose(R @ R.T, np.eye(3), atol=1e-12)
    # A vector perpendicular to the tilt plane is untouched.
    np.testing.assert_allclose(R @ [0, 0, 1.0], [0, 0, 1], atol=1e-12)


def _view() -> View:
    # Identity world-to-camera: OpenCV camera at the origin looking along +z (y down).
    K = np.array([[100.0, 0, 49.5], [0, 100.0, 29.5], [0, 0, 1]])  # integer-centred, 100 x 60 px
    return View("v", None, 100, 60, K, np.eye(3), np.zeros(3))


def test_arkit_pose_projects_like_the_dataset_camera():
    view = _view()
    pose, intrinsics, size = to_arkit(view, np.eye(3))
    assert intrinsics == [100.0, 100.0, 50.0, 30.0]
    assert size == [100.0, 60.0]
    # (1, 0.5, 5) m: OpenCV pixel centre (49.5 + 20, 29.5 + 10) = (69.5, 39.5), so continuous (70, 40).
    point = np.array([[1.0, 0.5, 5.0]])
    u, v, front = app_pixels(pose, intrinsics, point)
    assert front[0]
    np.testing.assert_allclose([u[0], v[0]], [70.0, 40.0])
    pu, pv, _, ok = project(view, point)
    assert ok[0]
    np.testing.assert_allclose([pu[0], pv[0]], [70.0, 40.0])


def _wall() -> Wall:
    # Wall face on z = 0 facing +z, ground at y = 0, meter at x = 0.
    return Wall(np.array([0.0, 1.5, 0.0]), np.array([0.0, 0.0, 1.0]), 0.0, -3.0, 3.0, 0.0)


def test_wall_frame_matches_the_apps_axes():
    wall = _wall()
    # along = cross(-outward, up) = cross((0,0,-1), (0,1,0)) = (1, 0, 0): +s is to the right facing the wall.
    np.testing.assert_allclose(wall.along, [1, 0, 0])
    np.testing.assert_allclose(wall.world(np.array(2.0), np.array(1.0), 0.5), [2.0, 1.0, 0.5])


def test_app_gates_range_angle_and_frame():
    # ARKit camera 2 m out at height 1 m, looking straight at the wall (-z): identity rotation.
    pose = np.eye(4)
    pose[:3, 3] = [0.0, 1.0, 2.0]
    intrinsics, size = [100.0, 100.0, 50.0, 30.0], [100.0, 60.0]
    points = np.array(
        [
            [0.0, 1.0, 0.0],  # dead ahead: passes all
            [0.0, 1.0, -5.0],  # 7 m away: out of range (still in front, still framed)
            [1.2, 1.0, 0.0],  # 31 degrees off the normal but at u = 50 + 60 = 110: out of frame
        ]
    )
    g = app_gates(pose, intrinsics, size, points, np.array([0.0, 0.0, 1.0]), CFG)
    assert g["range"].tolist() == [True, False, True]
    assert g["frame"].tolist() == [True, True, False]
    assert g["angle"].tolist() == [True, True, True]
    # A wall point 5 m to the side is 68 degrees off the normal: past the 65 degree limit.
    far_side = app_gates(
        pose, intrinsics, size, np.array([[5.0, 1.0, 0.0]]), np.array([0.0, 0.0, 1.0]), CFG
    )
    assert not far_side["angle"][0]


def test_straight_runs_split_at_gaps():
    t = np.r_[np.arange(0, 2.5, 0.1), np.arange(4.0, 5.0, 0.1), np.arange(6.2, 9.0, 0.1)]
    runs = straight_runs(t, gap=1.0, min_length=2.0)
    # 0..2.4 and 4.0..4.9 are 1.1 m apart (split); 4.9 to 6.2 is 1.3 m (split); 4.0..4.9 is too short.
    assert [(round(a, 1), round(b, 1)) for a, b in runs] == [(0.0, 2.4), (6.2, 8.9)]


def test_two_positions_needs_a_quarter_metre_between_photos():
    centres = np.array([[0.0, 0, 0], [0.1, 0, 0], [0.5, 0, 0]])
    saw = np.array([[True, True, False], [True, False, True], [False, False, True]])
    # Photos 0 and 1 are 0.1 m apart (not enough); 0 and 2 are 0.5 m (enough); one photo is not.
    assert two_positions(saw, centres, 0.25).tolist() == [False, True, False]


def test_deficient_rows_replays_the_apps_greedy_record():
    centres = np.array([[0.0, 0, 0], [0.1, 0, 0], [0.4, 0, 0], [0.2, 0, 0]])
    # Row 0 seen from 0 then 2 (0.4 m apart): covered. Row 1 from 0, 1 (too close), 3 (0.2 m): not.
    # Row 2 never seen.
    sightings = [(0, {0, 1}), (1, {1}), (2, {0}), (3, {1})]
    assert deficient_rows(sightings, centres, 3, 0.25) == [1, 2]


def test_majority_breaks_ties_in_listed_order():
    assert (
        majority(Counter({"range": 2, "occlusion": 2}), ("occlusion", "frame edge", "range"))
        == "occlusion"
    )
    assert (
        majority(Counter({"range": 3, "occlusion": 2}), ("occlusion", "frame edge", "range"))
        == "range"
    )
    assert majority(Counter(), ("occlusion", "range")) == "occlusion"


def test_in_intervals_is_inclusive():
    s = np.array([-1.0, 0.0, 0.5, 1.0, 1.5])
    assert in_intervals(s, [[0.0, 1.0]]).tolist() == [False, True, True, True, False]


def test_face_offsets_find_a_pilaster_but_not_a_bush():
    wall = _wall()
    columns = -1.0 + 0.02 * (np.arange(100) + 0.5)  # s from -1 to 1
    rng = np.random.default_rng(0)
    xs, ys = np.meshgrid(np.arange(-1.2, 1.2, 0.01), np.arange(0.0, 2.0, 0.02))
    face = np.c_[xs.ravel(), ys.ravel(), np.zeros(xs.size)]
    # Pilaster 0.36 m proud over s in [0.2, 0.6], full height.
    on_pilaster = (face[:, 0] >= 0.2) & (face[:, 0] <= 0.6)
    face[on_pilaster, 2] = 0.36
    # Bush over s in [-0.8, -0.4]: scattered points 0.1 to 0.5 m out, up to 1.2 m high.
    bush = np.c_[
        rng.uniform(-0.8, -0.4, 4000), rng.uniform(0.0, 1.2, 4000), rng.uniform(0.1, 0.5, 4000)
    ]
    offsets = face_offsets(wall, np.r_[face, bush], columns)
    pilaster_cols = (columns > 0.22) & (columns < 0.58)
    np.testing.assert_allclose(offsets[pilaster_cols], 0.36, atol=1e-9)
    bush_cols = (columns > -0.78) & (columns < -0.42)
    assert (offsets[bush_cols] == 0).all()
    assert (offsets[(columns > -0.3) & (columns < 0.1)] == 0).all()
