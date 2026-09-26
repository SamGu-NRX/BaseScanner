import subprocess
import sys
import time

from hsverify.memory import TreeLimit, peak_rss_mb, tree_rss_mb

# A child that writes `mb` megabytes, so they are resident, then waits.
HOLD_MB = "import time; b = b'x' * ({mb} * 2**20); time.sleep(10)"


def test_peak_memory_is_reported_in_megabytes():
    peak = peak_rss_mb()
    # A Python test process uses tens of MB, not bytes or gigabytes.
    assert 5 < peak["harness_mb"] < 2000
    assert peak["largest_child_mb"] >= 0


def test_tree_rss_counts_descendants():
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            HOLD_MB.format(mb=60),
        ],
        start_new_session=True,
    )
    try:
        time.sleep(1.0)
        assert tree_rss_mb(child.pid) > 50
    finally:
        child.kill()
        child.wait()


def test_a_process_group_over_the_limit_is_killed():
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            HOLD_MB.format(mb=80),
        ],
        start_new_session=True,
    )
    with TreeLimit(child, limit_mb=40, interval_s=0.1) as limit:
        child.wait(timeout=5)
    assert limit.killed and limit.peak_mb > 40
