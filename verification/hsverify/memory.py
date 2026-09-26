"""Peak memory of this harness process and of the child processes it waited for.

The Mac is shared by several agents and one oversized process froze it once, so every report
records these two numbers. macOS reports `ru_maxrss` in bytes.
"""

from __future__ import annotations

import resource


def peak_rss_mb() -> dict[str, float]:
    own = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    children = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return {"harness_mb": round(own / 2**20, 1), "largest_child_mb": round(children / 2**20, 1)}
