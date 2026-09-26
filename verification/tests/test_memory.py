from hsverify.memory import peak_rss_mb


def test_peak_memory_is_reported_in_megabytes():
    peak = peak_rss_mb()
    # A Python test process uses tens of MB, not bytes or gigabytes.
    assert 5 < peak["harness_mb"] < 2000
    assert peak["largest_child_mb"] >= 0
