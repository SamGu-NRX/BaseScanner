"""Each validator check on its own, with inputs built by hand."""

import math
import zipfile

import numpy as np
import pytest

from packet.files import PacketError, PacketFiles, safe_relative
from packet.samples.synthetic import mesh_ply
from packet.validate import (
    STREAM_COLUMNS,
    increasing_problems,
    intrinsics_problems,
    mesh_problems,
    rigid_problems,
    stream_problems,
)
from packet.write import column_major, quaternion_xyzw, trajectory_row


def pose(r=None, t=(0.0, 0.0, 0.0)) -> list[float]:
    m = np.eye(4)
    if r is not None:
        m[:3, :3] = r
    m[:3, 3] = t
    return column_major(m)


def yaw(deg: float) -> np.ndarray:
    a = math.radians(deg)
    return np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])


# --- Poses --------------------------------------------------------------------------------------


def test_a_rotation_with_translation_is_rigid():
    assert rigid_problems(pose(yaw(30), (1, 2, 3)), "p") == []


def test_a_reflection_is_not_a_rotation():
    assert "reflection" in rigid_problems(pose(np.diag([1, 1, -1])), "p")[0]


def test_a_scaled_rotation_is_not_orthonormal():
    assert "not orthonormal" in rigid_problems(pose(yaw(30) * 1.01), "p")[0]


def test_rotation_rounded_to_seven_digits_passes():
    rounded = [round(v, 7) for v in pose(yaw(33.3), (1, 2, 3))]
    assert rigid_problems(rounded, "p") == []


def test_a_row_major_pose_is_caught_by_its_last_row():
    m = np.eye(4)
    m[:3, 3] = [1, 2, 3]
    row_major = [float(v) for v in m.reshape(-1)]  # translation lands in the last row
    assert "column-major" in rigid_problems(row_major, "p")[0]


def test_nan_in_a_pose_is_refused():
    bad = pose()
    bad[12] = math.nan
    assert rigid_problems(bad, "p") == ["p: pose must be 16 finite numbers"]


# --- Intrinsics ---------------------------------------------------------------------------------


def test_phone_intrinsics_fit_a_landscape_image():
    assert intrinsics_problems([1440.0, 1440.0, 960.0, 720.0], 1920, 1440, "p") == []


def test_a_portrait_image_is_refused():
    assert "landscape" in intrinsics_problems([1440.0, 1440.0, 720.0, 960.0], 1440, 1920, "p")[0]


def test_principal_point_outside_the_image():
    assert "outside" in intrinsics_problems([1440.0, 1440.0, 2000.0, 720.0], 1920, 1440, "p")[0]


def test_unequal_focal_lengths_suggest_a_rotated_image():
    assert "rotated" in intrinsics_problems([1440.0, 1080.0, 960.0, 720.0], 1920, 1440, "p")[0]


def test_intrinsics_for_a_larger_image_do_not_fit():
    # Intrinsics of a 4032-wide photo attached to a 480-wide thumbnail: a 19° field of view.
    msgs = intrinsics_problems([1440.0, 1440.0, 240.0, 180.0], 480, 360, "p")
    assert any("field of view" in m for m in msgs)


# --- Time ---------------------------------------------------------------------------------------


def test_increasing_times_pass_and_repeats_fail():
    assert increasing_problems([1.0, 2.0, 3.0], "s") == []
    assert "row 3" in increasing_problems([1.0, 2.0, 2.0], "s")[0]
    assert "row 2" in increasing_problems([2.0, 1.0], "s")[0]


# --- Streams ------------------------------------------------------------------------------------


def trajectory_rows(n: int = 3) -> list[list[str]]:
    return [[str(v) for v in trajectory_row(10 + i / 60, "normal", np.eye(4))] for i in range(n)]


def test_a_good_trajectory_passes():
    rows = trajectory_rows()
    assert stream_problems("trajectory", STREAM_COLUMNS["trajectory"], rows, {"rows": 3}) == []


def test_stream_header_must_match_exactly():
    header = ["t", "x", "y"]
    assert "header" in stream_problems("gyroscope", header, [], {"rows": 0})[0]


def test_stream_row_count_must_match_the_manifest():
    msg = stream_problems(
        "trajectory", STREAM_COLUMNS["trajectory"], trajectory_rows(), {"rows": 4}
    )
    assert "3 rows" in msg[0]


def test_stream_values_must_be_numeric():
    rows = [["1.0", "0.1", "x", "0.3"]]
    assert (
        "not numeric"
        in stream_problems("gyroscope", STREAM_COLUMNS["gyroscope"], rows, {"rows": 1})[0]
    )


def test_stream_time_must_increase():
    rows = [["1.0", "0", "0", "0"], ["1.0", "0", "0", "0"]]
    assert (
        "time goes"
        in stream_problems("gyroscope", STREAM_COLUMNS["gyroscope"], rows, {"rows": 2})[0]
    )


def test_trajectory_tracking_and_quaternions_are_checked():
    rows = trajectory_rows()
    rows[1][1] = "good"
    rows[2][8] = "0.9"  # qw: no longer unit length
    msgs = stream_problems("trajectory", STREAM_COLUMNS["trajectory"], rows, {"rows": 3})
    assert any("tracking" in m for m in msgs)
    assert any("unit length" in m for m in msgs)


def test_quaternion_round_trip():
    q = quaternion_xyzw(yaw(120))
    x, y, z, w = q
    assert math.isclose(math.hypot(x, y, z, w), 1)
    assert math.isclose(math.degrees(2 * math.acos(w)), 120, abs_tol=1e-9)
    assert math.isclose(y, math.sin(math.radians(60)))


# --- Mesh ---------------------------------------------------------------------------------------


def test_the_fixture_mesh_passes():
    assert mesh_problems(mesh_ply()) == []


def test_mesh_face_index_out_of_range():
    data = bytearray(mesh_ply())
    # The last face's first index sits 13 bytes from the end: count(1) + 3 x int32 + class(1).
    data[-13:-9] = (99).to_bytes(4, "little")
    assert "out of range" in mesh_problems(bytes(data))[0]


def test_mesh_classification_above_seven():
    data = bytearray(mesh_ply())
    data[-1] = 8
    assert "classification" in mesh_problems(bytes(data))[0]


def test_truncated_mesh_is_caught():
    assert "bytes" in mesh_problems(mesh_ply()[:-5])[0]


def test_mesh_with_another_layout_is_refused():
    data = mesh_ply().replace(b"property float z", b"property double z")
    assert "header line" in mesh_problems(data)[0]


# --- Opening packets ----------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("path", "ok"),
    [("photos/p1.jpg", True), ("/etc/passwd", False), ("a/../../b", False), ("a\\b", False)],
)
def test_safe_relative(path, ok):
    assert safe_relative(path) is ok


def test_a_zip_entry_that_climbs_out_is_refused(tmp_path):
    archive = tmp_path / "p.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("manifest.json", "{}")
        z.writestr("../evil.txt", "x")
    with pytest.raises(PacketError, match="leave the packet"):
        PacketFiles(archive)


def test_a_zip_with_two_manifests_is_refused(tmp_path):
    archive = tmp_path / "p.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("a/manifest.json", "{}")
        z.writestr("b/manifest.json", "{}")
    with pytest.raises(PacketError, match="exactly one manifest"):
        PacketFiles(archive)


def test_a_folder_without_a_manifest_is_refused(tmp_path):
    with pytest.raises(PacketError, match="no manifest"):
        PacketFiles(tmp_path)


def test_an_unclassified_mesh_has_only_class_zero():
    data = bytearray(mesh_ply())
    for i in range(1, 5):  # the class byte ends each 14-byte face
        data[-14 * i + 13] = 0
    assert mesh_problems(bytes(data), classified=False) == []
    assert mesh_problems(mesh_ply(), classified=False) != []
