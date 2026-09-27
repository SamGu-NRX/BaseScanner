import json

import pytest

from meter_eval import sweep
from meter_eval.analyze import check_complete
from meter_eval.degrade import LEVELS


@pytest.fixture
def rows_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(sweep, "ROWS_DIR", tmp_path)
    return tmp_path


def full_rows(label="h1"):
    return [
        {"id": "m01", "label_hmac": label, "family": family, "level": level, "ok": 1}
        for family in ("blur", "motion", "glare")
        for level in LEVELS[family]
    ]


def test_written_rows_are_current_for_their_label_only(rows_dir):
    sweep.write_rows("m01", full_rows("h1"))
    assert sweep.is_current("m01", "h1")
    assert not sweep.is_current("m01", "h2")  # the label changed: sweep again
    assert not sweep.is_current("m02", "h1")  # never swept


def test_an_interrupted_write_leaves_no_rows_file(rows_dir, monkeypatch):
    def interrupted(src, dst):
        raise KeyboardInterrupt

    monkeypatch.setattr(sweep.os, "replace", interrupted)
    with pytest.raises(KeyboardInterrupt):
        sweep.write_rows("m01", full_rows())
    assert not sweep.rows_path("m01").exists()
    assert not sweep.is_current("m01", "h1")


def test_a_complete_photo_passes():
    assert check_complete("m01", full_rows()) == []


def test_missing_levels_duplicates_and_unknown_levels_are_named():
    rows = full_rows()
    dropped = rows.pop()  # the last glare level
    rows.append(dict(rows[0]))  # a duplicate blur row
    rows.append({**rows[0], "level": 0.99})  # a level the sweep never uses
    problems = check_complete("m01", rows)
    assert any("duplicate" in p for p in problems)
    assert any(f"glare missing levels [{dropped['level']}]" in p for p in problems)
    assert any("unexpected" in p for p in problems)


def test_rows_file_is_json_lines(rows_dir):
    sweep.write_rows("m01", full_rows())
    lines = sweep.rows_path("m01").read_text().splitlines()
    assert [json.loads(line)["level"] for line in lines][:2] == LEVELS["blur"][:2]
