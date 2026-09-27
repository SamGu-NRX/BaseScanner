"""Regressions for review findings on PR #12: each case has one right answer."""

import json
from pathlib import Path

import numpy as np
import pytest

from evals import coverage_options, replay
from evals.coverage import PhotoTruth, photo_truth
from evals.eth3d import View, read_ply_xyz
from evals.map3d import column_weights
from evals.recon import comparable_groups


def test_fractional_replay_bounds_are_refused():
    with pytest.raises(ValueError, match="whole seconds"):
        replay.replay_identity(20, 40.1, 75.1)
    assert replay.replay_identity(20, 40, 75)[0] == "advio-20-0040-0075"


def test_a_replay_from_other_inputs_is_not_deleted(tmp_path: Path):
    folder = tmp_path / "advio-20-0040-0075"
    folder.mkdir()
    (folder / "session.json").write_text(
        json.dumps({"replaySource": {"sequence": 20, "start": 40, "end": 76}})
    )
    with pytest.raises(ValueError, match="not built from"):
        replay.clear_replay(folder, {"sequence": 20, "start": 40, "end": 75})
    assert folder.exists()
    replay.clear_replay(folder, {"sequence": 20, "start": 40, "end": 76})
    assert not folder.exists()


def test_truncated_ply_header_fails(tmp_path: Path):
    path = tmp_path / "scan.ply"
    path.write_bytes(b"ply\nformat binary_little_endian 1.0\nelement vertex 3\n")
    with pytest.raises(ValueError, match="end_header"):
        read_ply_xyz(path)


def _view() -> View:
    K = np.array([[100.0, 0, 49.5], [0, 100.0, 29.5], [0, 0, 1]])
    return View("v", None, 100, 60, K, np.eye(3), np.zeros(3))


def test_an_empty_scan_pixel_is_unknown_not_seen():
    empty = np.full((6, 10), 1e6, np.float32)  # no scan point anywhere
    t = photo_truth(
        _view(), np.eye(3), empty, np.zeros((6, 10), bool), np.array([[0.0, 0, 3]]), True, 6.0
    )
    assert t.framed[0] and t.no_scan[0] and not t.hidden[0]
    assert not t.saw[0]
    scanned = np.full((6, 10), 3.0, np.float32)
    t = photo_truth(
        _view(), np.eye(3), scanned, np.zeros((6, 10), bool), np.array([[0.0, 0, 3]]), True, 6.0
    )
    assert t.saw[0]


def test_the_depth_test_option_rejects_rows_without_depth(monkeypatch):
    class Wall:
        pass

    class Setup:  # the fields depth_hidden reads
        cfg = {  # noqa: RUF012
            "rowsPerBand": 3,
            "maxDistance": 6.0,
            "cellWidth": 0.1524,
            "wallBandHeight": 1.98,
            "groundBandDepth": 1.2,
        }
        views = (_view(),)
        wall, R = Wall(), np.eye(3)
        zbufs, missing = (None,), (None,)

    unknown = PhotoTruth(*(np.array([[x, x]]) for x in (True, True, True, False, True)))
    monkeypatch.setattr(coverage_options, "row_points", lambda *a: np.zeros((3, 2, 3)))
    monkeypatch.setattr(coverage_options, "photo_truth", lambda *a: unknown)
    hidden = coverage_options.depth_hidden(
        Setup(), [{"keyframe": "v", "band": "wall", "index": 0, "rows": [0]}], 3, None, 0.1
    )
    assert hidden and hidden[0]["rows"] == [0]


def test_column_weights_cover_exactly_the_span():
    lo, hi = 0.0, 0.1524  # one 0.5 ft cell: eight 2 cm columns would count 0.16 m
    cols = np.arange(lo + 0.01, hi, 0.02)
    assert len(cols) == 8
    assert column_weights(cols, lo, hi).sum() == pytest.approx(hi)


def test_comparable_groups_keep_one_seed_population():
    groups = {
        "1": [["a"], ["b"], ["c"]],
        "2": [["a", "x"], ["b", "x"], ["c", "x"]],
        "8": [["a"] * 8, ["b"] * 8],  # seed c lacks neighbours for eight photos
    }
    out = comparable_groups(groups, [1, 2, 8])
    assert {n: [m[0] for m in g] for n, g in out.items()} == {
        "1": ["a", "b"],
        "2": ["a", "b"],
        "8": ["a", "b"],
    }
