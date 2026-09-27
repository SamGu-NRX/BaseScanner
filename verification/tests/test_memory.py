import os
import signal
import subprocess
import sys
import time

from hsverify.memory import TreeLimit, peak_rss_mb, sum_tree_mb, tree_rss_mb


def start(code: str) -> subprocess.Popen:
    return subprocess.Popen(
        [sys.executable, "-c", code], stdout=subprocess.PIPE, text=True, start_new_session=True
    )


def stop(child: subprocess.Popen) -> None:
    """Kill the child's whole group and reap it, whatever state the test left it in."""
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
    child.wait(timeout=10)
    child.stdout.close()


def test_peak_memory_is_reported_in_megabytes():
    peak = peak_rss_mb()
    # A Python test process uses tens of MB, not bytes or gigabytes.
    assert 5 < peak["harness_mb"] < 2000
    assert peak["largest_child_mb"] >= 0


def test_the_tree_sums_a_process_and_all_its_descendants_only():
    # pid ppid rss_kb: 10 -> 11 -> 12, and 20 is unrelated.
    listing = "   10     1  1024\n   11    10  2048\n   12    11  1024\n   20     1  9999\n"
    assert sum_tree_mb(listing, 10) == 4.0
    assert sum_tree_mb(listing, 11) == 3.0
    assert sum_tree_mb(listing, 99) == 0.0


def test_this_process_is_measured():
    # What the OS keeps resident moves with memory pressure on a shared Mac, so only the reading
    # itself is checked here; the tree arithmetic is checked above on a fixed listing.
    assert tree_rss_mb(os.getpid()) > 1


def test_a_process_group_over_the_limit_is_killed():
    child = start("import time; time.sleep(60)")
    try:
        with TreeLimit(child, limit_mb=40, interval_s=0.05, measure=lambda pid: 100.0) as limit:
            child.wait(timeout=5)
        assert limit.killed and limit.peak_mb == 100.0
        assert child.returncode == -signal.SIGKILL
    finally:
        stop(child)


def test_a_process_group_under_the_limit_is_left_running():
    child = start("import time; time.sleep(60)")
    try:
        with TreeLimit(child, limit_mb=40, interval_s=0.05, measure=lambda pid: 10.0) as limit:
            time.sleep(0.3)
        assert not limit.killed and limit.peak_mb == 10.0
        assert child.poll() is None
    finally:
        stop(child)
