import csv
import json
import re
import subprocess

from meter_eval import labels
from meter_eval.review import TEMPLATE


def keep_answer(previous) -> dict:
    """Run the review page's own keepAnswer() in Node."""
    source = re.search(r"function keepAnswer\(previous\) \{.*?\n\}", TEMPLATE, re.DOTALL).group(0)
    script = f"{source}\nconsole.log(JSON.stringify(keepAnswer({json.dumps(previous)})));"
    out = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def test_keep_after_a_correction_confirms_the_corrected_number():
    assert keep_answer({"verdict": "fix", "number": "ABC 7654321"}) == {
        "verdict": "keep",
        "number": "ABC 7654321",
    }


def test_keep_on_an_untouched_photo_confirms_the_readers_number():
    assert keep_answer(None) == {"verdict": "keep", "number": ""}


def write(path, rows):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def test_build_treats_a_kept_correction_as_human_confirmed(tmp_path, monkeypatch):
    reader = {
        "id": "m01",
        "meter_number": "1111111",
        "other_numbers": "",
        "number_sure": "sure",
        "class_label": "NONE",
        "class_sure": "",
        "notes": "",
    }
    source = {
        "id": "m01",
        "title": "t",
        "page_url": "p",
        "image_url": "i",
        "license": "CC0",
        "license_url": "",
        "author": "a",
    }
    write(tmp_path / "r1.csv", [reader])
    write(tmp_path / "r2.csv", [reader])
    write(tmp_path / "src.csv", [source])
    write(tmp_path / "human.csv", [{"id": "m01", "verdict": "keep", "number": "ABC 7654321"}])
    monkeypatch.setattr(labels, "READER1", tmp_path / "r1.csv")
    monkeypatch.setattr(labels, "READER2", [tmp_path / "r2.csv"])
    monkeypatch.setattr(labels, "SOURCES", tmp_path / "src.csv")
    monkeypatch.setattr(labels, "HUMAN", tmp_path / "human.csv")
    [row] = labels.build()
    assert row["number_hmac"] == labels.digest("ABC7654321")
    assert row["number_agreed"] == row["number_agreed_strict"] == "yes"
    assert row["human_check"] == "keep"
    assert "ABC7654321" in labels.known_numbers()
