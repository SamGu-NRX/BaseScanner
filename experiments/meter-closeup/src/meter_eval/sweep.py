"""Q2 and Q3: degrade each photo whose number read correctly, and find where reading breaks.

Only photos with an agreed number that the primary configuration read undegraded are swept,
so every failure here is caused by the controlled degradation. The number's box comes from
that clean read. When a degraded read fails, two second passes run (Q3): Vision on a crop
around the tallest detected digit line, and on that crop upscaled 2x.

Rows go to DATA_DIR/sweep/rows-<shard>.jsonl; `python -m meter_eval.analyze` merges them.
Raw recognizer output, which contains meter numbers, is not kept.
"""

import argparse
import csv
import json
import os
import time

from PIL import Image

from meter_eval.degrade import LEVELS, apply
from meter_eval.match import number_read
from meter_eval.ocr import Reader
from meter_eval.paths import DATA_DIR, MANIFEST, RESULTS_DIR
from meter_eval.quality import device_checks, gray, region_checks, tallest_digit_line

SWEEP_DIR = DATA_DIR / "sweep"


def edge_margin(box: list[float], width: int, height: int) -> float:
    """Distance from the box to the nearest frame edge, in line heights (negative if cut)."""
    line_px = box[3] * height
    gaps = [
        box[0] * width,
        box[1] * height,
        (1 - box[0] - box[2]) * width,
        (1 - box[1] - box[3]) * height,
    ]
    return min(gaps) / line_px if line_px > 0 else 0.0


def crop_around(box: list[float], width: int, height: int) -> list[float]:
    """The box padded by one line height on every side, clipped to the frame."""
    pad_x = box[3] * height / width
    x0, y0 = max(0.0, box[0] - pad_x), max(0.0, box[1] - box[3])
    x1, y1 = min(1.0, box[0] + box[2] + pad_x), min(1.0, box[1] + 2 * box[3])
    return [x0, y0, x1 - x0, y1 - y0]


def second_pass(
    reader: Reader, path, image: Image.Image, lines: list[dict], digest: str, length: int
) -> dict:
    tallest = tallest_digit_line(lines)
    if tallest is None:
        return {"crop": 0, "crop_x2": 0}
    crop = crop_around(tallest["box"], image.width, image.height)
    cropped = reader.read(path, crop=crop)
    x0, y0 = crop[0] * image.width, crop[1] * image.height
    region = image.crop(
        (
            round(x0),
            round(y0),
            round(x0 + crop[2] * image.width),
            round(y0 + crop[3] * image.height),
        )
    )
    upscaled_path = SWEEP_DIR / f"upscaled-{os.getpid()}.jpg"
    region.resize((region.width * 2, region.height * 2), Image.LANCZOS).save(
        upscaled_path, quality=95
    )
    upscaled = reader.read(upscaled_path)
    return {
        "crop": int(number_read(cropped["lines"], digest, length, lenient=False)),
        "crop_x2": int(number_read(upscaled["lines"], digest, length, lenient=False)),
    }


def sweep_image(reader: Reader, row: dict, box: list[float]) -> list[dict]:
    records = []
    digest, length = row["number_sha256"], int(row["number_len"])
    work_path = SWEEP_DIR / f"work-{os.getpid()}.jpg"
    with Image.open(DATA_DIR / "images" / f"{row['id']}.jpg") as original:
        original.load()
    for family, levels in LEVELS.items():
        for level in levels:
            applied = apply(family, original, box, level)
            if applied is None:
                continue
            image, label_box = applied
            image.save(work_path, quality=95)
            result = reader.read(work_path)
            ok = number_read(result["lines"], digest, length, lenient=False)
            g = gray(image)
            record = {
                "id": row["id"],
                "family": family,
                "level": level,
                "ok": int(ok),
                "width": image.width,
                "height": image.height,
                "label_edge_margin": edge_margin(label_box, image.width, image.height),
            }
            record |= {f"label_{k}": v for k, v in region_checks(g, label_box).items()}
            record |= device_checks(g, result["lines"])
            tallest = tallest_digit_line(result["lines"])
            if tallest is not None:
                record["edge_margin"] = edge_margin(tallest["box"], image.width, image.height)
            if not ok:
                record |= second_pass(reader, work_path, image, result["lines"], digest, length)
            records.append(
                {k: round(v, 4) if isinstance(v, float) else v for k, v in record.items()}
            )
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", type=int, default=0)
    parser.add_argument("--shards", type=int, default=1)
    args = parser.parse_args()

    with MANIFEST.open() as handle:
        manifest = {row["id"]: row for row in csv.DictReader(handle)}
    with (RESULTS_DIR / "clean_per_image.csv").open() as handle:
        clean = [r for r in csv.DictReader(handle) if r["number_accurate"] == "1"]
    targets = [r for r in clean if manifest[r["id"]]["number_agreed"] == "yes"]
    mine = targets[args.shard :: args.shards]

    SWEEP_DIR.mkdir(parents=True, exist_ok=True)
    out_path = SWEEP_DIR / f"rows-{args.shard}.jsonl"
    done = set()
    if out_path.exists():
        done = {json.loads(line)["id"] for line in out_path.open()}
    with Reader() as reader, out_path.open("a") as out:
        for clean_row in mine:
            if clean_row["id"] in done:
                continue
            started = time.time()
            box = json.loads(clean_row["number_box"])
            # Written per image, so a rerun after an interruption never keeps half an image.
            for record in sweep_image(reader, manifest[clean_row["id"]], box):
                out.write(json.dumps(record) + "\n")
            out.flush()
            print(f"{clean_row['id']} swept in {time.time() - started:.0f}s", flush=True)


if __name__ == "__main__":
    main()
