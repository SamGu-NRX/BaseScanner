"""The ETH3D facade scene builder replaces only its own outputs."""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scenes" / "eth3d-facade" / "build_scene.py"
spec = importlib.util.spec_from_file_location("build_scene", SCRIPT)
build_scene = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = build_scene  # dataclasses look their module up there
spec.loader.exec_module(build_scene)


def test_earlier_outputs_are_replaced(tmp_path):
    (tmp_path / "bundle").mkdir()
    (tmp_path / "bundle" / "k00001.jpg").write_bytes(b"old")
    (tmp_path / "scene.json").write_text("{}")
    (tmp_path / "overlays").mkdir()
    build_scene.clear_outputs(tmp_path)
    assert list(tmp_path.iterdir()) == []


def test_a_folder_with_other_files_is_refused_and_left_alone(tmp_path):
    (tmp_path / "scene.json").write_text("{}")
    (tmp_path / "datasets").mkdir()
    (tmp_path / "notes.txt").write_text("keep me")
    with pytest.raises(SystemExit, match=r"did not write \(datasets, notes\.txt\)"):
        build_scene.clear_outputs(tmp_path)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["datasets", "notes.txt", "scene.json"]


def test_a_missing_folder_is_fine_and_a_file_is_refused(tmp_path):
    build_scene.clear_outputs(tmp_path / "new")
    target = tmp_path / "a-file"
    target.write_text("x")
    with pytest.raises(SystemExit, match="is a file"):
        build_scene.clear_outputs(target)
    assert target.read_text() == "x"


def test_a_symlinked_output_is_unlinked_not_followed(tmp_path):
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "precious").write_text("keep")
    out = tmp_path / "out"
    out.mkdir()
    (out / "bundle").symlink_to(elsewhere, target_is_directory=True)
    build_scene.clear_outputs(out)
    assert (elsewhere / "precious").read_text() == "keep"
    assert not (out / "bundle").exists()
