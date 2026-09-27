import json

import numpy as np
import pytest
from PIL import Image

from meter_eval import sweep
from meter_eval.degrade import LEVELS, expected_levels

BOX = [0.25, 0.4, 0.5, 0.1]  # on a 400 x 200 photo: a 20 px line, room for some edge margins


class BlankReader:
    """Stands in for meterocr: reads nothing, so every degraded read fails."""

    def read(self, path, config="accurate", crop=None, barcodes=False):
        assert path.exists(), "Vision must read a saved file"
        return {"lines": [], "barcodes": []}


@pytest.fixture
def fresh_data(tmp_path, monkeypatch):
    """A data directory with one photo and no sweep directory yet."""
    (tmp_path / "images").mkdir()
    pixels = (np.indices((200, 400)).sum(axis=0) % 2 * 200).astype(np.uint8)
    Image.fromarray(pixels).convert("RGB").save(tmp_path / "images" / "m01.jpg")
    monkeypatch.setattr(sweep, "DATA_DIR", tmp_path)
    monkeypatch.setattr(sweep, "SWEEP_DIR", tmp_path / "sweep")
    monkeypatch.setattr(sweep, "ROWS_DIR", tmp_path / "sweep" / "rows")
    return tmp_path


def rows_for(expected, label="h1"):
    return [
        {"id": "m01", "label_hmac": label, "family": f, "level": level, "ok": 1}
        for f, level in sorted(expected)
    ]


def test_a_fresh_sweep_creates_its_directory_and_yields_exactly_the_expected_levels(fresh_data):
    row = {"id": "m01", "number_hmac": "h1", "number_len": "7", "number_core_hmac": "c1"}
    records = sweep.sweep_image(BlankReader(), row, BOX)
    assert (fresh_data / "sweep").is_dir()
    got = {(r["family"], r["level"]) for r in records}
    assert got == sweep.expected_for("m01", BOX) == expected_levels(BOX, 400, 200)


def test_expected_levels_skip_only_what_the_photo_cannot_take():
    expected = expected_levels(BOX, 400, 200)
    # A 20 px line cannot be downscaled to 26 px or more, only to smaller heights.
    assert {level for f, level in expected if f == "scale"} == {
        level for level in LEVELS["scale"] if level < 20
    }
    # The number ends at 300 px: margins up to 5 line heights (100 px) fit, 6 would not.
    assert ("edge", 2.0) in expected and ("edge", -2.0) in expected
    for family in ("blur", "motion", "glare"):
        assert {level for f, level in expected if f == family} == set(LEVELS[family])


def test_complete_current_rows_need_no_new_sweep(fresh_data):
    expected = sweep.expected_for("m01", BOX)
    sweep.write_rows("m01", rows_for(expected))
    assert sweep.problems_with("m01", "h1", expected) == []


@pytest.mark.parametrize(
    "keep, reason",
    [
        (lambda rows: [], "missing"),  # an empty file
        (lambda rows: rows[:1], "missing"),  # one row
        (lambda rows: [r for r in rows if r["family"] not in ("scale", "edge")], "missing"),
    ],
)
def test_partial_files_with_the_current_label_are_swept_again(fresh_data, keep, reason):
    expected = sweep.expected_for("m01", BOX)
    sweep.write_rows("m01", keep(rows_for(expected)))
    problems = sweep.problems_with("m01", "h1", expected)
    assert problems and reason in problems[0]


def test_stale_label_duplicates_and_unknown_levels_are_named(fresh_data):
    expected = sweep.expected_for("m01", BOX)
    rows = rows_for(expected)
    rows.append(dict(rows[0]))
    rows.append({**rows[0], "level": 0.99})
    problems = " ".join(sweep.check_rows("m01", rows, "h2", expected))
    assert "another label" in problems
    assert "duplicate" in problems
    assert "unexpected" in problems


def test_never_swept_photo_is_reported(fresh_data):
    assert sweep.problems_with("m02", "h1", set()) == ["m02: not swept"]


def test_an_interrupted_write_leaves_no_rows_file(fresh_data, monkeypatch):
    def interrupted(src, dst):
        raise KeyboardInterrupt

    monkeypatch.setattr(sweep.os, "replace", interrupted)
    with pytest.raises(KeyboardInterrupt):
        sweep.write_rows("m01", rows_for(sweep.expected_for("m01", BOX)))
    assert not sweep.rows_path("m01").exists()


def test_rows_file_is_json_lines(fresh_data):
    sweep.write_rows("m01", rows_for({("blur", 0.02), ("blur", 0.04)}))
    lines = sweep.rows_path("m01").read_text().splitlines()
    assert sorted(json.loads(line)["level"] for line in lines) == [0.02, 0.04]
