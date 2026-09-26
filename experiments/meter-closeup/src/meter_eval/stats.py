import math
from collections.abc import Sequence


def wilson(successes: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """95% Wilson score interval for a proportion."""
    if n == 0:
        return (0.0, 1.0)
    p = successes / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def auc(scores: Sequence[float], labels: Sequence[bool]) -> float | None:
    """Probability that a random positive scores above a random negative (ties count half)."""
    pos = [s for s, y in zip(scores, labels, strict=True) if y]
    neg = [s for s, y in zip(scores, labels, strict=True) if not y]
    if not pos or not neg:
        return None
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def loosest_threshold(
    values: Sequence[float], ok: Sequence[bool], target: float, higher_is_better: bool
) -> tuple[float, int, float] | None:
    """Most permissive cut-off whose accepted photos read correctly at least `target` of the time.

    A photo is accepted when its value is >= the cut-off (or <= it when lower is better).
    Returns (cut-off, photos accepted, their read rate), or None if no cut-off reaches target.
    """
    pairs = sorted(zip(values, ok, strict=True), reverse=higher_is_better)
    best = None
    good = 0
    for count, (value, success) in enumerate(pairs, start=1):
        good += success
        # Only cut between distinct values, so every photo at the cut-off value is included.
        if count < len(pairs) and pairs[count][0] == value:
            continue
        if good / count >= target:
            best = (value, count, good / count)
    return best
