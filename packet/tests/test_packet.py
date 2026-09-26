"""The validator on the committed fixture, and on copies of it broken one way at a time."""

import hashlib
import io
import json
import shutil
import zipfile
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from packet.__main__ import main
from packet.samples import synthetic
from packet.validate import validate

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "synthetic"


@pytest.fixture
def packet(tmp_path) -> Path:
    copy = tmp_path / "packet"
    shutil.copytree(FIXTURE, copy)
    return copy


def manifest(folder: Path) -> dict:
    return json.loads((folder / "manifest.json").read_text())


def save(folder: Path, m: dict) -> None:
    (folder / "manifest.json").write_text(json.dumps(m))


def replace_file(folder: Path, ref: dict, data: bytes) -> None:
    """Write new bytes and update the manifest entry, so only the content check can object."""
    (folder / ref["path"]).write_bytes(data)
    ref["bytes"], ref["sha256"] = len(data), hashlib.sha256(data).hexdigest()


def only_problem(folder: Path) -> str:
    report = validate(folder)
    assert len(report.problems) == 1, report.problems
    return report.problems[0]


def test_the_committed_fixture_is_what_the_builder_writes(tmp_path):
    rebuilt = synthetic.build(tmp_path / "synthetic")
    for f in FIXTURE.rglob("*"):
        if f.is_file():
            assert f.read_bytes() == (rebuilt / f.relative_to(FIXTURE)).read_bytes(), f


def test_the_fixture_is_valid_as_a_folder_and_as_a_zip(tmp_path):
    assert validate(FIXTURE).problems == []
    archive = tmp_path / "p.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for f in FIXTURE.rglob("*"):
            if f.is_file():
                z.write(f, f"synthetic/{f.relative_to(FIXTURE).as_posix()}")
    report = validate(archive)
    assert report.ok, report.problems
    assert report.summary["photos"] == 3


def test_cli_exit_codes(packet, capsys):
    assert main(["validate", str(packet)]) == 0
    assert capsys.readouterr().out.startswith(f"{packet}: valid")
    m = manifest(packet)
    m["packet_version"] = "2.0"
    save(packet, m)
    assert main(["validate", str(packet), "--json"]) == 1
    report = json.loads(capsys.readouterr().out)
    assert report["ok"] is False and report["problems"][0].startswith("schema: packet_version")


def test_a_newer_major_version_is_refused(packet):
    m = manifest(packet)
    m["packet_version"] = "2.0"
    save(packet, m)
    assert "packet_version" in only_problem(packet)


def test_an_unknown_field_is_accepted(packet):
    m = manifest(packet)
    m["session"]["something_new"] = {"added_in": "1.1"}
    save(packet, m)
    assert validate(packet).ok


def test_a_missing_file(packet):
    (packet / "photos" / "p00002.jpg").unlink()
    assert "is missing" in only_problem(packet)


def test_a_file_whose_size_changed(packet):
    with (packet / "streams" / "gyroscope.csv").open("a") as f:
        f.write("\n")
    assert "bytes, manifest says" in only_problem(packet)


def test_a_file_whose_content_changed(packet):
    path = packet / "lidar" / "mesh.ply"
    data = bytearray(path.read_bytes())
    data[-1] ^= 1  # same size, different bytes
    path.write_bytes(bytes(data))
    assert "sha256" in validate(packet).problems[0]


def test_an_unlisted_file_is_a_warning_only(packet):
    (packet / "notes.txt").write_text("hello")
    report = validate(packet)
    assert report.ok and "not in the manifest" in report.warnings[0]


def test_image_size_must_match_the_manifest(packet):
    m = manifest(packet)
    buf = io.BytesIO()
    Image.new("RGB", (80, 60)).save(buf, "JPEG")
    replace_file(packet, m["photos"][0]["image"], buf.getvalue())
    save(packet, m)
    assert "80x60" in only_problem(packet)


def test_a_rotated_photo_is_refused(packet):
    m = manifest(packet)
    img = Image.open(packet / m["photos"][0]["image"]["path"])
    exif = Image.Exif()
    exif[0x0112] = 6  # "rotate 90° clockwise to display"
    buf = io.BytesIO()
    img.save(buf, "JPEG", exif=exif.tobytes())
    replace_file(packet, m["photos"][0]["image"], buf.getvalue())
    save(packet, m)
    assert "EXIF orientation 6" in only_problem(packet)


def test_photos_out_of_time_order(packet):
    m = manifest(packet)
    m["photos"][0]["t"], m["photos"][1]["t"] = m["photos"][1]["t"], m["photos"][0]["t"]
    save(packet, m)
    assert any("time goes" in p for p in validate(packet).problems)


def test_a_photo_off_its_trajectory(packet):
    m = manifest(packet)
    m["photos"][1]["pose"][12] += 0.1  # 10 cm along x
    save(packet, m)
    assert "from the trajectory" in only_problem(packet)


def test_a_photo_between_trajectory_samples(packet):
    m = manifest(packet)
    m["photos"][2]["t"] = 102.3  # after the trajectory's last sample at 102.0, inside the capture
    save(packet, m)
    assert "no trajectory sample" in only_problem(packet)


def test_distance_walked_must_match_the_trajectory(packet):
    m = manifest(packet)
    m["session"]["capture"]["distance_walked_m"] = 2.5
    save(packet, m)
    assert "trajectory walks 2.000" in only_problem(packet)


def test_location_without_consent(packet):
    m = manifest(packet)
    m["session"]["consent"]["location"] = False
    save(packet, m)
    problems = validate(packet).problems
    assert [p.split(" is present")[0] for p in problems] == ["streams.location", "streams.heading"]


def test_depth_with_the_wrong_aspect(packet):
    m = manifest(packet)
    d = m["photos"][0]["depth"]
    replace_file(packet, d["map"], np.full((20, 20), 2.5, "<f4").tobytes())
    replace_file(packet, d["confidence"], np.full((20, 20), 2, "u1").tobytes())
    d["width"], d["height"] = 20, 20
    save(packet, m)
    assert "aspect" in only_problem(packet)


def test_depth_with_nan(packet):
    m = manifest(packet)
    d = m["photos"][0]["depth"]
    depth = np.full((d["height"], d["width"]), 2.5, "<f4")
    depth[3, 3] = np.nan
    replace_file(packet, d["map"], depth.tobytes())
    save(packet, m)
    assert "NaN" in only_problem(packet)


def test_depth_bytes_must_match_its_size(packet):
    m = manifest(packet)
    d = m["photos"][0]["depth"]
    d["width"], d["height"] = 12, 9  # same aspect, a quarter of the pixels
    save(packet, m)
    problems = validate(packet).problems
    assert len(problems) == 2
    assert "float32 is 432" in problems[0] and "uint8 is 108" in problems[1]


def test_confidence_above_high(packet):
    m = manifest(packet)
    d = m["photos"][0]["depth"]
    replace_file(packet, d["confidence"], np.full((d["height"], d["width"]), 3, "u1").tobytes())
    save(packet, m)
    assert "0, 1 or 2" in only_problem(packet)


def test_a_mark_naming_a_missing_photo(packet):
    m = manifest(packet)
    m["marks"][0]["photo_ids"] = ["p99999"]
    save(packet, m)
    assert "p99999" in only_problem(packet)


def test_a_wall_end_needs_its_side_and_kind(packet):
    m = manifest(packet)
    del m["marks"][1]["end_kind"]
    save(packet, m)
    assert "side and end_kind" in only_problem(packet)


def test_guidance_met_without_a_time(packet):
    m = manifest(packet)
    m["guidance"][0]["t_resolved"] = None
    save(packet, m)
    assert "needs t_resolved" in only_problem(packet)


def test_times_outside_the_capture(packet):
    m = manifest(packet)
    m["marks"][3]["t"] = 50.0
    save(packet, m)
    assert "outside the capture" in only_problem(packet)


def test_a_path_that_leaves_the_packet_breaks_the_schema(packet):
    m = manifest(packet)
    m["scene"]["path"] = "../scene.json"
    save(packet, m)
    assert validate(packet).problems[0].startswith("schema: scene/path")


# --- 1.1 additions ------------------------------------------------------------------------------


def as_1_0(m: dict) -> dict:
    """The fixture as a 1.0 writer would have written it: no 1.1 fields."""
    m["packet_version"] = "1.0"
    del m["depth_frames"]
    del m["session"]["device"]["mesh_classification_enabled"]
    m["lidar"]["planes"] = m.pop("planes")
    for plane in m["lidar"]["planes"]:
        plane.pop("boundary_m", None)
    for p in m["photos"]:
        del p["depth"]["confidence"]  # optional in 1.0 even for ARKit depth
    return m


def test_a_1_0_packet_still_validates(packet):
    save(packet, as_1_0(manifest(packet)))
    report = validate(packet)
    assert report.ok, report.problems
    assert len(report.warnings) == 1  # the files only 1.1 names are now unlisted


def test_arkit_depth_needs_confidence_from_1_1(packet):
    m = manifest(packet)
    del m["photos"][0]["depth"]["confidence"]
    (packet / "depth" / "p00001.conf.u8").unlink()
    save(packet, m)
    assert "needs confidence (required from 1.1)" in only_problem(packet)


def test_estimated_depth_needs_sigma(packet):
    m = manifest(packet)
    del m["depth_frames"][1]["sigma"]
    save(packet, m)
    assert only_problem(packet).startswith("schema: depth_frames/1")


def test_sigma_must_be_finite_and_sized(packet):
    m = manifest(packet)
    f = m["depth_frames"][1]
    sigma = np.full((f["height"], f["width"]), 0.15, "<f4")
    sigma[0, 0] = np.inf
    replace_file(packet, f["sigma"], sigma.tobytes())
    save(packet, m)
    assert "sigma has NaN or infinite values" in only_problem(packet)
    replace_file(packet, f["sigma"], sigma[:, :-1].tobytes())
    save(packet, m)
    assert "sigma is 1656 bytes" in only_problem(packet)


def test_a_depth_frame_off_its_trajectory(packet):
    m = manifest(packet)
    m["depth_frames"][0]["pose"][14] += 0.05  # 5 cm out from the wall
    save(packet, m)
    assert only_problem(packet).startswith("depth_frames[0] d00001: 0.050 m from the trajectory")


def test_depth_frame_intrinsics_describe_the_depth_grid(packet):
    m = manifest(packet)
    m["depth_frames"][0]["intrinsics"] = [80.0, 80.0, 48.0, 36.0]  # the photo's, not the map's
    save(packet, m)
    assert "principal point" in validate(packet).problems[0]


def test_depth_frames_in_time_order(packet):
    m = manifest(packet)
    a, b = m["depth_frames"]
    a["t"], b["t"] = b["t"], a["t"]
    save(packet, m)
    assert any(p.startswith("depth_frames (in manifest order)") for p in validate(packet).problems)


def test_planes_in_both_places(packet):
    m = manifest(packet)
    m["lidar"]["planes"] = m["planes"]
    save(packet, m)
    assert "use one (top level)" in only_problem(packet)


def test_a_boundary_outside_its_extent(packet):
    m = manifest(packet)
    m["planes"][0]["boundary_m"][0] = [-3.5, -1.2]  # half a meter past the 6 m extent
    save(packet, m)
    assert "leaves the 6.0 x 2.4 m extent" in only_problem(packet)


def test_a_mesh_needs_the_classification_flag_from_1_1(packet):
    m = manifest(packet)
    del m["session"]["device"]["mesh_classification_enabled"]
    save(packet, m)
    assert "mesh_classification_enabled is required" in only_problem(packet)


def test_classes_must_be_zero_when_classification_was_off(packet):
    m = manifest(packet)
    m["session"]["device"]["mesh_classification_enabled"] = False
    save(packet, m)
    assert "every face's class must be 0" in only_problem(packet)
