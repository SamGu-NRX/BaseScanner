"""Hand-computed cases for the worker's adapters, depth helpers, fusion, coverage output and GLB."""

import json
from pathlib import Path

import numpy as np
import pytest

from recon import capture as cap
from recon.coverage import CELL_M, CellCoverage, _runs, observed
from recon.depth import Depth, lidar, rotated_intrinsics, upright_turns
from recon.fusion import integrate, mesh
from recon.glb import read_glb, write_glb


def test_outward_is_the_baseline_turned_clockwise_from_above():
    # Facing a wall along +x from +z: +x is to the right, so outward is +z.
    np.testing.assert_allclose(cap.outward_of(np.array([1.0, 0, 0])), [0, 0, 1])


def test_column_major_snaps_a_rounded_rotation_and_refuses_a_non_rotation():
    c, s = np.cos(0.3), np.sin(0.3)
    R = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    T = np.eye(4)
    T[:3, :3] = np.round(R, 4)
    T[:3, 3] = [1, 2, 3]
    out = cap.column_major(T.T.reshape(-1).tolist())
    np.testing.assert_allclose(out[:3, :3] @ out[:3, :3].T, np.eye(3), atol=1e-12)
    np.testing.assert_allclose(out[:3, 3], [1, 2, 3])
    with pytest.raises(ValueError):
        cap.column_major(np.diag([1.0, 1.0, -1.0, 1.0]).reshape(-1).tolist())  # a mirror


def test_scan_bundle_reads_feet_into_meters(tmp_path: Path):
    pose = np.eye(4)
    pose[:3, 3] = [10.0, 5.0, 0.0]  # feet
    scene = {
        "schema_version": "1.0",
        "meter": {"pos": [0.0, 5.0, 0.0], "wall_id": "w"},
        "walls": [{"id": "w", "baseline": [[-10.0, 0.0], [10.0, 0.0]]}],
        "keyframes": [
            {
                "id": "k1",
                "img": "k1.jpg",
                "w": 4,
                "h": 3,
                "intrinsics": [2, 2, 2, 1.5],
                "pose": pose.T.reshape(-1).tolist(),
            }
        ],
    }
    (tmp_path / "scene.json").write_text(json.dumps(scene))
    c = cap.load(tmp_path, tmp_path / "work")
    assert c.source == "scan-bundle" and c.ground_y == 0.0
    np.testing.assert_allclose(c.frames[0].center, [3.048, 1.524, 0.0])
    np.testing.assert_allclose(c.meter, [0.0, 1.524, 0.0])
    np.testing.assert_allclose(c.wall.along, [1, 0, 0])
    np.testing.assert_allclose(c.wall.outward, [0, 0, 1])


def test_rotated_intrinsics_follow_np_rot90():
    # A 4 x 2 image, one turn counter-clockwise: pixel (u, v) goes to (v, w - u).
    k = np.array([10.0, 20.0, 1.0, 0.5])
    np.testing.assert_allclose(rotated_intrinsics(k, 4, 2, 1), [20, 10, 0.5, 3.0])
    np.testing.assert_allclose(rotated_intrinsics(k, 4, 2, 2), [10, 20, 3.0, 1.5])
    np.testing.assert_allclose(rotated_intrinsics(k, 4, 2, 3), [20, 10, 1.5, 1.0])


def test_upright_turns_for_a_phone_held_upright():
    # Portrait phone: the sensor's +x points up in the world, so one turn counter-clockwise.
    T = np.eye(4)
    T[:3, :3] = np.array([[0.0, -1, 0], [1, 0, 0], [0, 0, 1]])  # camera +x -> world +y
    assert upright_turns(T) == 1
    assert upright_turns(np.eye(4)) == 0


def test_lidar_reads_float_meters_and_drops_low_confidence(tmp_path: Path):
    import cv2

    cv2.imwrite(str(tmp_path / "k.jpg"), np.zeros((6, 8, 3), np.uint8))
    np.array([[1.0, 2.0], [3.0, 0.0]], "<f4").tofile(tmp_path / "k.depth.f32")
    np.array([[2, 0], [1, 2]], np.uint8).tofile(tmp_path / "k.conf.u8")
    f = cap.Frame(
        "k",
        tmp_path / "k.jpg",
        8,
        6,
        np.array([8.0, 8, 4, 3]),
        np.eye(4),
        cap.LidarDepth(tmp_path / "k.depth.f32", tmp_path / "k.conf.u8", 2, 2),
    )
    d = lidar(f)
    assert d.depth[0, 0] == 1.0 and d.depth[1, 0] == 3.0
    assert np.isnan(d.depth[0, 1]) and np.isnan(d.depth[1, 1])  # low confidence; zero depth
    np.testing.assert_allclose(d.intrinsics, [2, 2, 1, 0.75])


def test_fused_wall_is_where_the_depth_says_and_faces_the_camera():
    # A camera at the origin looking along -z at a flat wall 2 m away.
    w, h = 64, 48
    depth = Depth(
        np.full((h, w), 2.0, np.float32),
        np.array([40.0, 40, w / 2, h / 2]),
        np.full((h, w, 3), 128, np.uint8),
        "lidar",
    )
    vol = integrate({"a": depth}, {"a": np.eye(4)}, voxel=0.05)
    m = mesh(vol)
    assert abs(np.median(m.vertices[:, 2]) + 2.0) < 0.05
    assert np.median(m.normals[:, 2]) > 0.9  # toward the camera (+z)
    v = m.vertices[m.faces.astype(int)]
    winding = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])[:, 2]
    assert np.median(winding) > 0  # counter-clockwise seen from the camera
    assert vol.occupied(np.array([[0.0, 0, -2.1]]))[0]
    assert (
        not vol.occupied(np.array([[0.0, 0, -1.0]]))[0]
        and vol.observed(np.array([[0.0, 0, -1.0]]))[0]
    )
    assert not vol.observed(np.array([[0.0, 0, -2.5]]))[0]  # behind the wall: never seen


def test_observed_entries_in_feet():
    cells = np.arange(4) * CELL_M
    cov = CellCoverage(
        cells=cells,
        wall=np.array([True, True, False, True]),
        ground_out=np.array([1.3, 1.3, 0.0, 0.0]),  # 4.27 ft out for the first two cells
        facing_gap=np.array([np.nan, 1.0, 1.0, np.nan]),
        facing_clear=np.array([2.0, 0.0, 0.0, 0.5]),
        overhead_clearance=np.full(4, np.nan),
        overhead_clear=np.array([2.5, 2.5, 0.0, 0.0]),
    )
    e = observed(cov)
    assert {"band": "wall", "span_ft": [0.0, 1.0]} in e
    assert {"band": "wall", "span_ft": [1.5, 2.0]} in e
    assert {"band": "ground", "span_ft": [0.0, 1.0], "out_ft": 4.0} in e
    assert not any(x["band"] == "ground" and x["out_ft"] == 6.0 for x in e)
    assert {"band": "facing", "span_ft": [0.5, 1.5]} in e  # something measured in front
    assert {"band": "facing", "span_ft": [0.0, 0.5], "out_ft": 6.5} in e  # 2.0 m seen clear
    assert {"band": "overhead", "span_ft": [0.0, 1.0], "out_ft": 8.0} in e


def test_runs():
    assert _runs(np.array([True, True, False, True])) == [(0, 2), (3, 4)]
    assert _runs(np.array([False])) == []


def test_glb_round_trip(tmp_path: Path):
    v = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], float)
    write_glb(
        tmp_path / "m.glb",
        v,
        np.array([[0, 1, 2]]),
        np.array([[255, 0, 0]] * 3),
        np.tile([0, 0, 1.0], (3, 1)),
    )
    doc, blob = read_glb(tmp_path / "m.glb")
    prim = doc["meshes"][0]["primitives"][0]
    assert set(prim["attributes"]) == {"POSITION", "COLOR_0", "NORMAL"}
    pos = doc["accessors"][prim["attributes"]["POSITION"]]
    assert pos["count"] == 3 and pos["max"] == [1.0, 1.0, 0.0]
    view = doc["bufferViews"][pos["bufferView"]]
    got = np.frombuffer(blob, np.float32, 9, view["byteOffset"]).reshape(3, 3)
    np.testing.assert_allclose(got, v)
