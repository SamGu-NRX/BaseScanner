"""Tally screened.csv: how many openly licensed panel photos have a legible label field.

screened.csv lists every photo examined at full resolution after screening thumbnails, with a
per-field call made by eye: manufacturer, model or series, and amperage. Duplicates (the same
file found twice, or one photo reposted) are counted once.
"""

import csv
from collections.abc import Iterable

from panel_eval.paths import EXPERIMENT_DIR

SCREENED = EXPERIMENT_DIR / "screened.csv"
# The pre-set bar: "fewer than about 40 usable photos" stops the experiment.
REQUIRED = 40


def tally(rows: Iterable[dict]) -> dict[str, int]:
    unique = [r for r in rows if not r["duplicate_of"]]

    def has(r: dict, field: str) -> bool:
        return r[field] == "1"

    return {
        "examined": len(unique),
        "any field legible": sum(
            1 for r in unique if has(r, "manufacturer") or has(r, "model") or has(r, "amperage")
        ),
        "manufacturer and (model or amperage)": sum(
            1 for r in unique if has(r, "manufacturer") and (has(r, "model") or has(r, "amperage"))
        ),
        "all three": sum(
            1 for r in unique if has(r, "manufacturer") and has(r, "model") and has(r, "amperage")
        ),
    }


def main() -> None:
    with SCREENED.open() as handle:
        counts = tally(csv.DictReader(handle))
    for name, count in counts.items():
        print(f"{name}: {count}")
    verdict = "meets" if counts["any field legible"] >= REQUIRED else "is short of"
    print(f"Even the most lenient count {verdict} the {REQUIRED}-photo bar.")


if __name__ == "__main__":
    main()
