"""Q2 and Q3: degrade each photo whose number read correctly, and find where reading breaks.

Only photos with an agreed number that the primary configuration read undegraded are swept,
so every failure here is caused by the controlled degradation. The number's box comes from
that clean read, and the "label_" checks use it; the phone does not know that box, so every
unprefixed check uses the number-finding ranking's top candidate on the degraded read. When a
degraded read fails, two second passes run (Q3): Vision on a crop around that top candidate,
and on that crop upscaled 2x.

Vision reads each degraded image from the JPEG it is saved as, so every check is computed on
that decoded JPEG too, never on the pixels before encoding.

Each photo's rows go to DATA_DIR/sweep/rows/<id>.jsonl, written to a temporary file and
renamed into place, so a photo's file exists only once all its degradations were read. Rows
carry the digest of the label they were scored against. A photo is swept again unless its file
holds exactly the levels `degrade.expected_levels` gives for that photo, all scored against its
current label. Raw recognizer output, which contains meter numbers, is not kept.
"""

import argparse
import csv
import json
import os
import time

from PIL import Image

from meter_eval.degrade import LEVELS, apply, expected_levels
from meter_eval.locate import top_candidate
from meter_eval.match import digest as match_digest
from meter_eval.match import number_read
from meter_eval.ocr import Reader
from meter_eval.paths import DATA_DIR, MANIFEST, RESULTS_DIR
from meter_eval.quality import device_checks, edge_gap, gray, region_checks

SWEEP_DIR = DATA_DIR / "sweep"
ROWS_DIR = SWEEP_DIR / "rows"


def targets() -> list[tuple[dict, list[float]]]:
    """(manifest row, number box) for every photo whose agreed number read undegraded."""
    with MANIFEST.open() as handle:
        manifest = {row["id"]: row for row in csv.DictReader(handle)}
    with (RESULTS_DIR / "clean_per_image.csv").open() as handle:
        clean = [r for r in csv.DictReader(handle) if r["number_accurate"] == "1"]
    return [
        (manifest[r["id"]], json.loads(r["number_box"]))
        for r in clean
        if manifest[r["id"]]["number_agreed"] == "yes"
    ]


def rows_path(image_id: str):
    return ROWS_DIR / f"{image_id}.jsonl"


def expected_for(image_id: str, box: list[float]) -> set[tuple[str, float]]:
    """The (family, level) set the sweep runs on this photo, from its size and number box."""
    with Image.open(DATA_DIR / "images" / f"{image_id}.jpg") as image:
        return expected_levels(box, image.width, image.height)


def check_rows(
    image_id: str, rows: list[dict], label_hmac: str, expected: set[tuple[str, float]]
) -> list[str]:
    """What is wrong with one photo's rows; empty when they are exactly the expected set."""
    keys = [(r["family"], r["level"]) for r in rows]
    problems = []
    if any(r.get("label_hmac") != label_hmac for r in rows):
        problems.append(f"{image_id}: scored against another label")
    if len(keys) != len(set(keys)):
        problems.append(f"{image_id}: duplicate rows")
    if missing := expected - set(keys):
        problems.append(f"{image_id}: missing {sorted(missing)}")
    if unexpected := set(keys) - expected:
        problems.append(f"{image_id}: unexpected {sorted(unexpected)}")
    return problems


def problems_with(image_id: str, label_hmac: str, expected: set[tuple[str, float]]) -> list[str]:
    """Why this photo must be swept again; empty when its rows file is complete and current."""
    path = rows_path(image_id)
    if not path.exists():
        return [f"{image_id}: not swept"]
    rows = [json.loads(line) for line in path.open()]
    return check_rows(image_id, rows, label_hmac, expected)


def write_rows(image_id: str, records: list[dict]) -> None:
    """Write all of a photo's rows at once: a temporary file, then an atomic rename."""
    ROWS_DIR.mkdir(parents=True, exist_ok=True)
    temporary = rows_path(image_id).with_suffix(f".tmp-{os.getpid()}")
    temporary.write_text("".join(json.dumps(r) + "\n" for r in records))
    os.replace(temporary, rows_path(image_id))


def crop_around(box: list[float], width: int, height: int) -> list[float]:
    """The box padded by one line height on every side, clipped to the frame."""
    pad_x = box[3] * height / width
    x0, y0 = max(0.0, box[0] - pad_x), max(0.0, box[1] - box[3])
    x1, y1 = min(1.0, box[0] + box[2] + pad_x), min(1.0, box[1] + 2 * box[3])
    return [x0, y0, x1 - x0, y1 - y0]


def second_pass(
    reader: Reader, path, image: Image.Image, guess: dict | None, digest: str, length: int
) -> dict:
    if guess is None:
        return {"crop": 0, "crop_x2": 0}
    crop = crop_around(guess["box"], image.width, image.height)
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
    digest, length = row["number_hmac"], int(row["number_len"])
    SWEEP_DIR.mkdir(parents=True, exist_ok=True)
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
            with Image.open(work_path) as saved:
                image = saved.convert("RGB")
            result = reader.read(work_path, barcodes=True)
            ok = number_read(result["lines"], digest, length, lenient=False)
            g = gray(image)
            guess = top_candidate(result)
            record = {
                "id": row["id"],
                "label_hmac": digest,
                "family": family,
                "level": level,
                "ok": int(ok),
                "width": image.width,
                "height": image.height,
                "label_edge_margin": edge_gap(label_box, image.width, image.height),
            }
            record |= {f"label_{k}": v for k, v in region_checks(g, label_box).items()}
            record |= device_checks(g, guess and guess["box"])
            if guess is not None:
                record["guess_is_number"] = int(
                    match_digest(guess["core"]) == row["number_core_hmac"]
                )
            if not ok:
                record |= second_pass(reader, work_path, image, guess, digest, length)
            records.append(
                {k: round(v, 4) if isinstance(v, float) else v for k, v in record.items()}
            )
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", type=int, default=0)
    parser.add_argument("--shards", type=int, default=1)
    args = parser.parse_args()

    mine = targets()[args.shard :: args.shards]
    with Reader() as reader:
        for row, box in mine:
            if not problems_with(row["id"], row["number_hmac"], expected_for(row["id"], box)):
                continue
            started = time.time()
            write_rows(row["id"], sweep_image(reader, row, box))
            print(f"{row['id']} swept in {time.time() - started:.0f}s", flush=True)


if __name__ == "__main__":
    main()
