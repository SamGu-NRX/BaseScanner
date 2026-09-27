from meter_eval.leakcheck import find_leaks, pieces, windows
from meter_eval.match import digest


def known() -> set[str]:
    """A synthetic identifier's keyed digest, computed under the test key (see conftest)."""
    return {digest("1234567")}


def test_windows_yield_every_run_with_at_least_four_digits():
    # Four-digit identifiers exist (a utility plate), so windows start at four digits.
    parts = set(windows("AB12345"))
    assert parts == {"1234", "2345", "B1234", "12345", "AB1234", "B12345", "AB12345"}


def test_measurement_columns_are_exempt_only_when_they_hold_numbers():
    text = 'id,lap_var,number_box,count\nm01,62.5152,"[0.4157, 0.68]",1234567\n'
    found = pieces("x.csv", text)
    assert "62.5152" not in found and "[0.4157, 0.68]" not in found
    assert "1234567" in found
    assert "ABC 1234567" in pieces("x.csv", "id,lap_var\nm01,ABC 1234567\n")


def test_dotted_identifier_is_caught_outside_measurement_columns():
    for printed in ("1234.567", "1.234.567", "12-345-67"):
        text = f"id,notes\nm01,{printed}\n"
        assert find_leaks({"x.csv": text}, known()) == [("x.csv", 7)], printed


def test_dotted_identifier_in_a_measurement_column_is_the_documented_exemption():
    # Only the experiment's own code writes these columns, and only with measured numbers.
    assert find_leaks({"x.csv": "id,lap_var\nm01,1234.567\n"}, known()) == []


def test_identifier_in_prose_is_caught():
    assert find_leaks({"README.md": "The plate reads No. 1 234 567."}, known()) == [
        ("README.md", 7)
    ]


def test_digests_in_text_are_ignored():
    text = "number_hmac " + "a" * 64
    assert all("aaaa" not in p for p in pieces("x.md", text))


def test_cells_beyond_the_header_are_scanned():
    text = "id,lap_var\nm01,62.5,1234.567\n"
    assert find_leaks({"x.csv": text}, known()) == [("x.csv", 7)]


def test_a_file_with_an_empty_first_line_is_scanned_in_full():
    text = "\nm01,1.234.567\n"
    assert find_leaks({"x.csv": text}, known()) == [("x.csv", 7)]


def test_identifier_is_caught_across_every_separator_normalize_drops():
    for sep in (" ", ".", "-", "/", "_", ":", ";", "|", ",", "\\", "\t", "\n", "#", "*"):
        text = f"see 123{sep}4567 here"
        assert find_leaks({"notes.md": text}, known()) == [("notes.md", 7)], repr(sep)


def test_the_scan_covers_tracked_files_outside_the_experiment(tmp_path):
    import subprocess

    from meter_eval.leakcheck import repository_files

    root = tmp_path / "repo"
    (root / "docs").mkdir(parents=True)
    (root / "experiments" / "meter-closeup").mkdir(parents=True)
    (root / "docs" / "how-it-works.html").write_text("<p>plate 123 4567</p>\n")
    (root / "experiments" / "meter-closeup" / "README.md").write_text("clean\n")
    (root / "web").mkdir()
    (root / "web" / "pnpm-lock.yaml").write_text("integrity: 1234567\n")  # lockfiles are skipped
    for args in (["init", "-q"], ["add", "."]):
        subprocess.run(["git", *args], cwd=root, check=True)
    (root / "notes.md").write_text("draft 1234567\n")  # untracked but not ignored: scanned
    files = repository_files(root)
    assert set(files) == {
        "docs/how-it-works.html",
        "experiments/meter-closeup/README.md",
        "notes.md",
    }
    assert find_leaks(files, known()) == [("docs/how-it-works.html", 7), ("notes.md", 7)]
