"""Peak memory of this harness process and of the child processes it waited for.

The Mac is shared by several agents and one oversized process froze it once, so every report
records these two numbers. macOS reports `ru_maxrss` in bytes.
"""

from __future__ import annotations

import os
import resource
import signal
import subprocess
import threading


def peak_rss_mb() -> dict[str, float]:
    own = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    children = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return {"harness_mb": round(own / 2**20, 1), "largest_child_mb": round(children / 2**20, 1)}


def tree_rss_mb(root: int) -> float:
    """Resident memory of `root` and all its descendants, from one `ps` listing."""
    listing = subprocess.run(
        ["ps", "-A", "-o", "pid=,ppid=,rss="], capture_output=True, text=True, check=True
    ).stdout
    children: dict[int, list[int]] = {}
    rss: dict[int, int] = {}
    for line in listing.splitlines():
        pid, ppid, kb = (int(field) for field in line.split())
        children.setdefault(ppid, []).append(pid)
        rss[pid] = kb
    total, stack = 0, [root]
    while stack:
        pid = stack.pop()
        total += rss.get(pid, 0)
        stack.extend(children.get(pid, []))
    return total / 1024


class TreeLimit:
    """Kills a process group once its resident memory passes `limit_mb`.

    A server under test is started in its own process group, so one signal stops `uv` and the
    Python it started. `peak_mb` and `killed` go into the report."""

    def __init__(self, proc: subprocess.Popen, limit_mb: float, interval_s: float = 0.5):
        self.proc, self.limit_mb, self.interval_s = proc, limit_mb, interval_s
        self.peak_mb, self.killed = 0.0, False
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._watch, daemon=True)

    def __enter__(self) -> TreeLimit:
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        self._thread.join()

    def reset(self) -> float:
        """Restart the peak from the group's current memory, and return that."""
        self.peak_mb = tree_rss_mb(self.proc.pid)
        return self.peak_mb

    def _watch(self) -> None:
        while not self._stop.wait(self.interval_s) and self.proc.poll() is None:
            used = tree_rss_mb(self.proc.pid)
            self.peak_mb = max(self.peak_mb, used)
            if used > self.limit_mb:
                self.killed = True
                os.killpg(self.proc.pid, signal.SIGKILL)
                return
