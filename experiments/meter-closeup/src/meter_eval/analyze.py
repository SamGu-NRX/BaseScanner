"""Turn the sweep rows into read-rate curves, retake thresholds and second-pass gains.

Writes results/sweep_rows.csv (merged rows, no recognized text) and results/sweep.md.

Thresholds: walk each degradation of a photo from mild to severe and find its break, the
first level from which it never reads again. The retake threshold is the check value at or
below which 95% (or 80%) of photos have broken, so a photo scoring above it reads for 95%
of photos.
Isolated failures before the break (a read fails, then succeeds at a harsher level) are
recognizer noise that no photo check can prevent; they are counted separately. AUC is over
every degraded read: the chance a random successful read scores better than a failed one.
"""

import csv
import json
from collections import defaultdict

import numpy as np

from meter_eval.degrade import LEVELS
from meter_eval.paths import RESULTS_DIR
from meter_eval.stats import auc
from meter_eval.sweep import expected_for, problems_with, rows_path, targets

FAMILY_NAMES = {
    "blur": "Gaussian blur, σ as a fraction of the number's line height",
    "motion": "Horizontal motion blur, streak length as a fraction of line height",
    "scale": "Downscaled so the number's line is this many pixels tall",
    "glare": "White glare patch on the number, peak opacity",
    "edge": "Right frame edge this many line heights past the number (negative cuts it)",
}

UNITS = {
    "blur": "σ / line height",
    "motion": "streak / line height",
    "scale": "line height px",
    "glare": "peak opacity",
    "edge": "line heights",
}

# (column, higher is better, description). "label" columns are measured on the number's true
# box from the undegraded read, which the phone does not have; they bound what a perfect
# locator would allow. For the edge family that box is clipped to the frame, so its gap is 0
# whenever the edge cuts the number, by construction. "top candidate" columns use the
# number-finding ranking's first pick on the degraded read, which the phone can compute.
# "whole photo" columns need no locator.
CHECKS = {
    "blur": [
        ("label_lap_var_32", True, "label sharpness, resized to a 32 px line"),
        ("lap_var_32", True, "top-candidate sharpness, 32 px line"),
        ("global_lap_var", True, "whole-photo sharpness at up to 1024 px"),
    ],
    "motion": [
        ("label_lap_var_32", True, "label sharpness, resized to a 32 px line"),
        ("lap_var_32", True, "top-candidate sharpness, 32 px line"),
        ("global_lap_var", True, "whole-photo sharpness at up to 1024 px"),
    ],
    "scale": [
        ("label_text_height_px", True, "label line height in pixels"),
        ("text_height_px", True, "top-candidate line height in pixels"),
    ],
    "glare": [
        ("label_saturated", False, "label share of pixels ≥ 250"),
        ("saturated", False, "top-candidate share of pixels ≥ 250"),
        ("label_contrast", True, "label RMS contrast"),
        ("global_saturated", False, "whole-photo share of pixels ≥ 250"),
    ],
    "edge": [
        ("label_edge_margin", True, "label gap to the frame edge (clipped box)"),
        ("edge_margin", True, "top-candidate gap to the frame edge, in line heights"),
    ],
}


def load_rows() -> list[dict]:
    """Every swept photo's rows, scored against its current label.

    Fails, naming the photos, if any photo's rows are missing, stale, or not exactly the levels
    the sweep runs on that photo, rather than analyzing a partial sweep.
    """
    rows, problems = [], []
    for row, box in targets():
        image_id = row["id"]
        found = problems_with(image_id, row["number_hmac"], expected_for(image_id, box))
        if found:
            problems += found
            continue
        rows += [json.loads(line) for line in rows_path(image_id).open()]
    if problems:
        raise SystemExit("run `make sweep` first:\n" + "\n".join(problems))
    return rows


def write_rows(rows: list[dict]) -> None:
    fields = sorted(
        {k for r in rows for k in r}, key=lambda k: (k not in ("id", "family", "level"), k)
    )
    with (RESULTS_DIR / "sweep_rows.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, restval="")
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda r: (r["id"], r["family"])))


def curve_table(rows: list[dict]) -> str:
    out = []
    for family, levels in LEVELS.items():
        by_level = defaultdict(list)
        for r in rows:
            if r["family"] == family:
                by_level[r["level"]].append(r["ok"])
        cells = [
            (f"{level:g}", f"{sum(v) / len(v):.0%} ({len(v)})")
            for level in levels
            if (v := by_level.get(level))
        ]
        out.append(f"**{FAMILY_NAMES[family]}**\n")
        out.append("| Level | " + " | ".join(c[0] for c in cells) + " |")
        out.append("|---|" + "---|" * len(cells))
        out.append("| Read correctly (photos) | " + " | ".join(c[1] for c in cells) + " |\n")
    return "\n".join(out)


def break_values(rows: list[dict], family: str, column: str, higher: bool):
    """Per photo, the check's value at its break (see module docstring).

    Photos that read at the harshest level have no break and contribute no value. Also
    returns the number of isolated failures before a break, and the reads they came from.
    """
    order = {level: i for i, level in enumerate(LEVELS[family])}
    worst = float("-inf") if higher else float("inf")
    by_photo = defaultdict(list)
    for r in rows:
        if r["family"] == family:
            by_photo[r["id"]].append(r)
    breaks, never, isolated, before = [], 0, 0, 0
    for photo_rows in by_photo.values():
        photo_rows.sort(key=lambda r: order[r["level"]])
        succeeded = [i for i, r in enumerate(photo_rows) if r["ok"]]
        start = succeeded[-1] + 1 if succeeded else 0
        isolated += sum(1 for r in photo_rows[:start] if not r["ok"])
        before += start
        if start == len(photo_rows):
            never += 1
            continue
        breaks.append(photo_rows[start].get(column, worst))
    return breaks, never, isolated, before


def thresholds(rows: list[dict]) -> list[dict]:
    """Every check's 95% and 80% retake thresholds, median break and AUC, per degradation."""
    found = []
    for family, checks in CHECKS.items():
        # The level itself: larger is harsher except for scale and edge.
        level_check = ("level", family in ("scale", "edge"), f"degradation level ({UNITS[family]})")
        for column, higher, description in [level_check, *checks]:
            worst = float("-inf") if higher else float("inf")
            breaks, never, _, _ = break_values(rows, family, column, higher)
            # Photos that never broke count as breaking below every observed value.
            padded = breaks + [worst] * never
            cuts = {
                share: float(
                    np.percentile(padded, share if higher else 100 - share, method="nearest")
                )
                for share in (95, 80)
            }
            subset = [r for r in rows if r["family"] == family]
            # No detected digit line means the phone found no number: the worst score.
            values = [r.get(column, worst) for r in subset]
            score = auc([v if higher else -v for v in values], [bool(r["ok"]) for r in subset])
            found.append(
                {
                    "family": family,
                    "column": column,
                    "higher": higher,
                    "description": description,
                    "cuts": cuts,
                    "median": float(np.median(breaks)),
                    "auc": None if column == "level" else score,
                }
            )
    return found


def fmt_cut(value: float, higher: bool) -> str:
    # A photo fails at its break value and reads only strictly beyond it, so the threshold
    # value itself calls for a retake.
    return f"{'≤' if higher else '≥'} {value:.3g}" if np.isfinite(value) else "never"


def break_table(rows: list[dict], found: list[dict]) -> str:
    out = [
        "| Degradation | Check | Retake when (95% of photos) | Retake when (80%) | Median break | AUC |",
        "|---|---|---|---|---|---|",
    ]
    for t in found:
        out.append(
            f"| {t['family']} | {t['description']} | {fmt_cut(t['cuts'][95], t['higher'])} | "
            f"{fmt_cut(t['cuts'][80], t['higher'])} | {t['median']:.3g} | "
            f"{'–' if t['auc'] is None else f'{t["auc"]:.2f}'} |"
        )
    notes = []
    for family in CHECKS:
        _, never, isolated, before = break_values(rows, family, "level", True)
        photos = len({r["id"] for r in rows if r["family"] == family})
        notes.append(
            f"- {family}: {photos} photos, {never} never broke; {isolated} of {before} reads "
            f"above the break failed anyway ({isolated / before:.1%})."
        )
    return "\n".join(out) + "\n\n" + "\n".join(notes) + "\n"


def false_retake_table(found: list[dict]) -> str:
    """How many real, undegraded photos that read correctly each threshold would reject."""
    with (RESULTS_DIR / "clean_per_image.csv").open() as handle:
        good = [r for r in csv.DictReader(handle) if r["number_accurate"] == "1"]
    out = [
        "| Check | Rejected at the 95% threshold | Rejected at the 80% threshold |",
        "|---|---|---|",
    ]
    for t in found:
        if t["column"] not in good[0] or t["column"] == "level":
            continue
        values = [float(r[t["column"]]) for r in good if r[t["column"]] != ""]
        cells = []
        for share in (95, 80):
            cut, higher = t["cuts"][share], t["higher"]
            rejected = sum(1 for v in values if (v <= cut if higher else v >= cut))
            cells.append(f"{rejected}/{len(values)}")
        out.append(f"| {t['description']} ({t['family']}) | {cells[0]} | {cells[1]} |")
    return "\n".join(out) + "\n"


def second_pass_table(rows: list[dict]) -> str:
    out = [
        "| Degradation | Failed reads | Crop re-read recovers | Crop 2x re-read recovers | Either |",
        "|---|---|---|---|---|",
    ]
    for family in LEVELS:
        failed = [r for r in rows if r["family"] == family and not r["ok"]]
        if not failed:
            continue
        crop = sum(r.get("crop", 0) for r in failed)
        crop2 = sum(r.get("crop_x2", 0) for r in failed)
        either = sum(max(r.get("crop", 0), r.get("crop_x2", 0)) for r in failed)
        n = len(failed)
        out.append(
            f"| {family} | {n} | {crop} ({crop / n:.0%}) | {crop2} ({crop2 / n:.0%}) | "
            f"{either} ({either / n:.0%}) |"
        )
    return "\n".join(out) + "\n"


def main() -> None:
    rows = load_rows()
    write_rows(rows)
    images = len({r["id"] for r in rows})
    found = thresholds(rows)
    text = "\n".join(
        [
            f"Swept photos: {images}; degraded reads: {len(rows)}.\n",
            "### Read rate by degradation level\n",
            curve_table(rows),
            "### Retake thresholds from each photo's break point\n",
            break_table(rows, found),
            "### Real photos that read correctly but a threshold would reject\n",
            false_retake_table(found),
            "### Second pass on failed reads\n",
            second_pass_table(rows),
        ]
    )
    header = "Generated by `make sweep` then `make q2` (`uv run python -m meter_eval.analyze`).\n\n"
    (RESULTS_DIR / "sweep.md").write_text(header + text)
    print(text)


if __name__ == "__main__":
    main()
