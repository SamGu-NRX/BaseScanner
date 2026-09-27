from meter_eval.leakcheck import pieces, windows


def test_windows_only_yield_runs_with_five_digits():
    parts = set(windows("AB12345"))
    assert parts == {"B12345", "AB12345", "12345"}


def test_csv_cells_skip_decimal_measurements_but_keep_integers():
    text = "id,value,count\nm01,62.5152,1234567\n"
    assert "62.5152" not in pieces("x.csv", text)
    assert "1234567" in pieces("x.csv", text)


def test_digests_in_text_are_ignored():
    text = "number_hmac " + "a" * 64
    assert all("aaaa" not in p for p in pieces("x.md", text))
