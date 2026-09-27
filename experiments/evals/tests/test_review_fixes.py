"""Regressions for review findings on PR #12: each case has one right answer."""

import json
from pathlib import Path

import numpy as np
import pytest

from evals import coverage_options, replay
from evals.coverage import PhotoTruth, photo_truth
from evals.eth3d import View, read_ply_xyz
from evals.map3d import span_columns, within_bar
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


@pytest.mark.parametrize("cells", [1, 2, 4])
def test_span_columns_tile_whole_half_foot_cells(cells):
    # 0.1524 m cells leave a partial 2 cm strip at the end (0.0024 m for 1 cell, 0.0048 m for 2);
    # the widths must still add up to the span, and every centre must lie inside it.
    hi = cells * 0.1524
    cols, w = span_columns(0.0, hi)
    assert w.sum() == pytest.approx(hi, abs=1e-12)
    assert (w > 0).all() and (w <= 0.02 + 1e-12).all()
    assert cols[0] > 0 and cols[-1] < hi


def test_span_columns_on_a_foot_keep_the_last_strip():
    cols, w = span_columns(0.0, 0.3048)
    assert len(cols) == 16 and w[-1] == pytest.approx(0.0048)
    cols, w = span_columns(0.0, 0.30)  # a whole number of columns gets no sliver
    assert len(cols) == 15 and w[-1] == pytest.approx(0.02)


def test_a_claim_of_exactly_the_bar_passes():
    _, w = span_columns(0.0, 0.1524)  # one 0.5 ft cell, all of it unseen
    assert within_bar(w.sum() / 0.3048)
    _, w = span_columns(0.0, 0.1544)
    assert not within_bar(w.sum() / 0.3048)


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


def test_fit_key_changes_with_each_image_and_depth_file(tmp_path: Path):
    import os

    from evals.pose_priors import fit_inputs

    T = {"a": np.eye(4), "b": np.eye(4)}
    K = {"a": np.eye(3), "b": np.eye(3)}
    files = {}
    for kind in ("image", "depth"):
        for m in "ab":
            files[kind, m] = tmp_path / f"{kind}-{m}"
            files[kind, m].write_bytes(f"{kind} {m}".encode())

    def key():
        return fit_inputs(
            T, K, 2.0, {m: files["image", m] for m in "ab"}, {m: files["depth", m] for m in "ab"}
        )

    base = key()
    assert key() == base
    seen = {base}
    for kind in ("image", "depth"):
        path = files[kind, "b"]
        path.write_bytes(path.read_bytes() + b" changed")
        # A new size is enough on its own, but move the clock too, as a rewrite would.
        st = path.stat()
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000))
        changed = key()
        assert changed not in seen  # each file changing alone gives a new key
        seen.add(changed)


def _strict_loads(text: str):
    def refuse(token):
        raise ValueError(f"{token} is not JSON")

    return json.loads(text, parse_constant=refuse)


def test_failed_percentiles_serialise_as_strict_json():
    from evals.pairs import results_json, summarize

    errors = np.r_[np.full(8, 0.01), np.full(2, np.inf)]  # 20% failed: the p90 is a failure
    row = summarize(errors)
    assert row["p90_in"] == float("inf")
    doc = _strict_loads(results_json({"row": row, "empty": float("nan"), "ok": [1.5]}))
    assert doc["row"]["p90_in"] == "failed"
    assert doc["row"]["failed_pct"] == 20.0
    assert doc["empty"] is None and doc["ok"] == [1.5]
    with pytest.raises(ValueError, match="-inf"):
        results_json({"x": float("-inf")})


@pytest.mark.parametrize(
    "path", sorted((Path(__file__).parents[1] / "results").glob("*.json")), ids=lambda p: p.name
)
def test_committed_results_are_strict_json(path: Path):
    _strict_loads(path.read_text())


def test_marvin_scores_only_pinned_walks_with_pinned_content(tmp_path: Path):
    import hashlib

    from evals import modern_arkit

    files = {"bar/seq2/ARkitPose.txt": b"two", "bar/seq10/ARkitPose.txt": b"ten"}
    for rel, data in files.items():
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_bytes(data)
    stale = tmp_path / "bar/seq3/ARkitPose.txt"  # on disk but not pinned: never read
    stale.parent.mkdir(parents=True)
    stale.write_bytes(b"stale")
    pinned = {rel: hashlib.sha256(data).hexdigest() for rel, data in files.items()}
    assert modern_arkit.pinned_walks(pinned, "bar") == ["seq2", "seq10"]
    modern_arkit.verify(pinned, tmp_path)
    (tmp_path / "bar/seq10/ARkitPose.txt").write_bytes(b"edited")
    with pytest.raises(RuntimeError, match="missing or differ"):
        modern_arkit.verify(pinned, tmp_path)
    (tmp_path / "bar/seq10/ARkitPose.txt").unlink()
    with pytest.raises(RuntimeError, match="missing or differ"):
        modern_arkit.verify(pinned, tmp_path)


def test_marvin_manifest_covers_every_scored_scene():
    from evals import modern_arkit

    pinned = modern_arkit.manifest()
    for scene in modern_arkit.SCENES:
        assert {f"{scene}/train.txt", f"{scene}/test.txt"} <= set(pinned)
        assert modern_arkit.pinned_walks(pinned, scene)


def _archive(tmp_path: Path, members=("d/a.csv", "d/sub/")):
    from evals.datasets import Archive

    return Archive("https://example.org/x.zip", 1, "f" * 64, tmp_path, "d/a.csv", members)


def test_an_interrupted_unpack_is_not_complete(tmp_path: Path):
    from evals import datasets

    archive = _archive(tmp_path)
    (tmp_path / "d").mkdir()
    (tmp_path / "d/a.csv").write_text("a")  # the marker alone, as an interrupted unpack leaves it
    assert not datasets.is_complete(archive)
    with pytest.raises(SystemExit, match="d/sub/"):
        datasets.write_record(archive, ["d/a.csv"])
    assert not datasets.is_complete(archive)


def test_a_recorded_unpack_is_complete_until_a_file_goes_missing_or_changes_size(tmp_path: Path):
    from evals import datasets

    archive = _archive(tmp_path)
    (tmp_path / "d/sub").mkdir(parents=True)
    (tmp_path / "d/a.csv").write_text("a")
    (tmp_path / "d/sub/b.csv").write_text("bb")
    datasets.write_record(archive, ["d/", "d/a.csv", "d/sub/", "d/sub/b.csv"])
    assert datasets.is_complete(archive)
    other = datasets.Archive(archive.url, 1, "e" * 64, tmp_path, archive.marker, archive.members)
    assert not datasets.is_complete(other)  # a record for another archive hash does not count
    (tmp_path / "d/sub/b.csv").write_text("b")  # truncated
    assert not datasets.is_complete(archive)
    (tmp_path / "d/sub/b.csv").unlink()
    assert not datasets.is_complete(archive)


def _run(root: Path, gid: str, poses_sha256=None):
    (root / gid).mkdir(parents=True)
    doc = {"members": [gid]}
    if poses_sha256 is not None:
        doc["poses_sha256"] = poses_sha256
    (root / gid / "run.json").write_text(json.dumps(doc))


def test_mapanything_rows_are_labelled_by_the_poses_they_recorded(tmp_path: Path):
    import hashlib

    from evals.pose_priors import HISTORICAL_MAPANYTHING, mapanything_label, uses_historical_rows

    poses = tmp_path / "advio_2018.json"
    poses.write_text('{"g": 1}')
    current = hashlib.sha256(poses.read_bytes()).hexdigest()
    # The published runs record no pose hash: they keep the historical label and its note.
    historical = tmp_path / "historical"
    _run(historical, "n2-a")
    label = mapanything_label(historical, "advio_2018", poses)
    assert label == HISTORICAL_MAPANYTHING["advio_2018"]
    assert uses_historical_rows({"electro": {"all": {f"mapanything@392 + {label}": {}}}})
    # A fresh run on the current poses is labelled by them, with no historical note.
    fresh = tmp_path / "fresh"
    _run(fresh, "n2-a", current)
    _run(fresh, "n4-a", current)
    label = mapanything_label(fresh, "advio_2018", poses)
    assert label == "advio_2018 poses"
    assert not uses_historical_rows({"electro": {"all": {f"mapanything@392 + {label}": {}}}})
    # Recorded runs on other poses, or a mix, are refused rather than mislabelled.
    mixed = tmp_path / "mixed"
    _run(mixed, "n2-a", current)
    _run(mixed, "n4-a")
    with pytest.raises(SystemExit, match="rerun"):
        mapanything_label(mixed, "advio_2018", poses)
    other = tmp_path / "other"
    _run(other, "n2-a", "0" * 64)
    with pytest.raises(SystemExit, match="rerun"):
        mapanything_label(other, "advio_2018", poses)
