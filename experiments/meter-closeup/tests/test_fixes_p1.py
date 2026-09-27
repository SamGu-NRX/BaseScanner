import csv

from meter_eval import labels


def write(path, header, rows):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=header)
        writer.writeheader()
        writer.writerows(rows)


def test_a_human_correction_joins_the_leak_digest_set(tmp_path, monkeypatch):
    cols = ["id", "meter_number", "other_numbers", "number_sure"]
    write(
        tmp_path / "r1.csv",
        cols,
        [{"id": "m01", "meter_number": "1111111", "other_numbers": "", "number_sure": "sure"}],
    )
    write(
        tmp_path / "r2.csv",
        cols,
        [{"id": "m01", "meter_number": "1111111", "other_numbers": "", "number_sure": "sure"}],
    )
    write(
        tmp_path / "human.csv",
        ["id", "verdict", "number"],
        [{"id": "m01", "verdict": "fix", "number": "ABC 2222222"}],
    )
    monkeypatch.setattr(labels, "READER1", tmp_path / "r1.csv")
    monkeypatch.setattr(labels, "READER2", [tmp_path / "r2.csv"])
    monkeypatch.setattr(labels, "HUMAN", tmp_path / "human.csv")
    found = labels.known_numbers()
    assert {"1111111", "ABC2222222", "2222222"} <= found


class BlankReader:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        pass

    def read(self, path, config="accurate", crop=None, barcodes=False):
        return {"lines": [], "barcodes": []}


def test_fieldtest_leaves_the_photo_folder_exactly_as_it_was(tmp_path, monkeypatch):
    import sys

    from PIL import Image

    from meter_eval import fieldtest

    Image.new("RGB", (64, 48), "gray").save(tmp_path / "a.jpg")
    # A photo of the user's that happens to have the old working-file name.
    Image.new("RGB", (32, 32), "white").save(tmp_path / ".upright.jpg")
    before = {p.name: p.read_bytes() for p in tmp_path.iterdir()}
    monkeypatch.setattr(fieldtest, "Reader", BlankReader)
    monkeypatch.setattr(sys, "argv", ["fieldtest", str(tmp_path), "--number", "1234567"])
    fieldtest.main()
    assert {p.name: p.read_bytes() for p in tmp_path.iterdir()} == before
