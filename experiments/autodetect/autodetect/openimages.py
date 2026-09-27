"""Select and download the Open Images V7 sets: eval and tune (validation + test) and train.

An image qualifies when its human-verified image-level labels include House or Building as
positive and Window or Door as positive. Boxes and verification status are kept only for
Window and Door, the two scored classes; neither has subclasses in the OI hierarchy.

Metadata CSVs are streamed and filtered on the fly, so only the selected rows reach disk. The
train CSVs are large, so each HTTP read is capped at 450 MB. The train box file is sorted by image
id, so its first 450 MB holds every box of the images whose ids come first (about 20% of train).
The train image list (638 MB) is not sorted, so it is read whole in two ranges.

Usage: python -m autodetect.openimages select      # metadata -> DATA/oi/meta/*.json
       python -m autodetect.openimages download    # images + manifests/oi_*.csv + DATA/oi/gt_*.json
"""

from __future__ import annotations

import csv
import io
import json
import random
import sys
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image

from .paths import MANIFESTS, OI

MID = {"/m/0d4v4": "window", "/m/02dgv": "door", "/m/03jm5": "house", "/m/0cgh4": "building"}
SCORED = ("window", "door")

GCS = "https://storage.googleapis.com/openimages"
LABELS = {
    "validation": f"{GCS}/v5/validation-annotations-human-imagelabels-boxable.csv",
    "test": f"{GCS}/v5/test-annotations-human-imagelabels-boxable.csv",
    "train": f"{GCS}/v5/train-annotations-human-imagelabels-boxable.csv",
}
BOXES = {
    "validation": f"{GCS}/v5/validation-annotations-bbox.csv",
    "test": f"{GCS}/v5/test-annotations-bbox.csv",
    "train": f"{GCS}/v6/oidv6-train-annotations-bbox.csv",
}
IMAGES = {
    "validation": f"{GCS}/2018_04/validation/validation-images-with-rotation.csv",
    "test": f"{GCS}/2018_04/test/test-images-with-rotation.csv",
    "train": f"{GCS}/2018_04/train/train-images-boxable-with-rotation.csv",
}
S3 = "https://open-images-dataset.s3.amazonaws.com/{split}/{id}.jpg"
TRAIN_RANGE_BYTES = 450_000_000  # keeps each train metadata read under the 500 MB download cap

SEED = 20260926
N_EVAL, N_TUNE, N_TRAIN = 300, 150, 1500
EVAL_LONG_SIDE, TRAIN_LONG_SIDE = 1024, 640


def _header(url: str) -> list[str]:
    req = urllib.request.Request(url, headers={"Range": "bytes=0-4095"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return next(csv.reader([resp.read().decode().splitlines()[0]]))


def stream_rows(url: str, max_bytes: int | None = None, start: int = 0):
    """Yield CSV rows as dicts from bytes [start, start + max_bytes), or to the end without
    max_bytes. A line cut by either end of the range is dropped, and so is the first line after
    `start`, so consecutive ranges never yield a row twice or half a row (the row at a boundary
    can be lost)."""
    req = urllib.request.Request(url)
    if max_bytes or start:
        end = "" if max_bytes is None else str(start + max_bytes - 1)
        req.add_header("Range", f"bytes={start}-{end}")
    header = _header(url) if start else None
    with urllib.request.urlopen(req, timeout=120) as resp:
        text = io.TextIOWrapper(resp, encoding="utf-8", newline="")
        first = text.readline()
        if header is None:
            header = next(csv.reader([first]))
        pending = None
        for line in text:
            if pending is not None:
                yield dict(zip(header, next(csv.reader([pending]))))
            pending = line
        # With a byte range the final line is usually truncated; without one it is complete.
        if pending is not None and (max_bytes is None or pending.endswith("\n")):
            yield dict(zip(header, next(csv.reader([pending]))))


def verified_labels(split: str) -> dict[str, dict[str, int]]:
    """image id -> {class: 1 positive | 0 negative} for the four classes, human-verified only."""
    out: dict[str, dict[str, int]] = {}
    for row in stream_rows(LABELS[split]):
        name = MID.get(row["LabelName"])
        if name:
            out.setdefault(row["ImageID"], {})[name] = int(row["Confidence"])
    return out


def qualifies(v: dict[str, int]) -> bool:
    return (v.get("house") == 1 or v.get("building") == 1) and (v.get("window") == 1 or v.get("door") == 1)


def select() -> None:
    meta = OI / "meta"
    meta.mkdir(parents=True, exist_ok=True)
    for split in ("validation", "test", "train"):
        cap = TRAIN_RANGE_BYTES if split == "train" else None
        labels = verified_labels(split)
        pool = {i: {"verified": {k: v[k] for k in SCORED if k in v}} for i, v in labels.items() if qualifies(v)}
        print(f"{split}: {len(pool)} images pass the label filter", file=sys.stderr)

        last_id = None
        for row in stream_rows(BOXES[split], cap):
            last_id = row["ImageID"]
            name = MID.get(row["LabelName"])
            if name in SCORED and last_id in pool:
                box = [float(row[k]) for k in ("XMin", "YMin", "XMax", "YMax")]
                pool[last_id].setdefault("boxes", []).append(
                    {"label": name, "box": box, "group": row["IsGroupOf"] == "1"}
                )
        if cap:
            # Box file is sorted by id: keep ids strictly before the last one read, which may be cut off.
            pool = {i: p for i, p in pool.items() if i < last_id}
            print(f"{split}: {len(pool)} with ids below {last_id} (box-file prefix)", file=sys.stderr)

        # The image list is not sorted, so for train read all of it, in two ranges under the cap.
        parts = [(TRAIN_RANGE_BYTES, 0), (None, TRAIN_RANGE_BYTES)] if cap else [(None, 0)]
        rows = (row for size, start in parts for row in stream_rows(IMAGES[split], size, start))
        for row in rows:
            p = pool.get(row["ImageID"])
            if p is not None:
                p["src"] = {
                    "landing_url": row["OriginalLandingURL"],
                    "license": row["License"],
                    "author": row["Author"],
                    "rotation": row["Rotation"],
                }
        kept = {i: p for i, p in pool.items() if "src" in p and p["src"]["rotation"] in ("0", "0.0")}
        print(f"{split}: {len(kept)} with image metadata and no rotation", file=sys.stderr)
        (meta / f"pool_{split}.json").write_text(json.dumps(kept))


def _fetch(split: str, image_id: str, dest: Path, long_side: int) -> tuple[int, int] | str:
    """Download one original, downscale it, delete the original. Returns (w, h) or a skip reason."""
    if dest.exists():
        with Image.open(dest) as im:
            return im.size
    url = S3.format(split=split, id=image_id)
    with tempfile.NamedTemporaryFile(suffix=".jpg", dir=dest.parent) as tmp:
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                tmp.write(resp.read())
            tmp.flush()
            with Image.open(tmp.name) as im:
                # Boxes are normalized to the image as stored. An EXIF rotation would move them.
                if im.getexif().get(274, 1) != 1:
                    return "exif-rotated"
                im = im.convert("RGB")
                im.thumbnail((long_side, long_side), Image.Resampling.LANCZOS)
                im.save(dest, quality=90)
                return im.size
        except Exception as e:  # noqa: BLE001 - a missing or corrupt original just skips the image
            return f"error: {e}"


def _eval_ok(p: dict) -> bool:
    return bool(p.get("boxes"))


def _train_ok(p: dict) -> bool:
    # Both classes verified, so both are exhaustively boxed; no group-of boxes, which would teach
    # the student to box a whole row of windows as one.
    v = p["verified"]
    boxes = p.get("boxes", [])
    return "window" in v and "door" in v and bool(boxes) and not any(b["group"] for b in boxes)


def download() -> None:
    meta = OI / "meta"
    evalpool = {}
    for split in ("validation", "test"):
        for i, p in json.loads((meta / f"pool_{split}.json").read_text()).items():
            if _eval_ok(p):
                evalpool[i] = dict(p, split=split)
    trainpool = {
        i: dict(p, split="train")
        for i, p in json.loads((meta / "pool_train.json").read_text()).items()
        if _train_ok(p)
    }
    rng = random.Random(SEED)
    eval_ids = sorted(evalpool)
    rng.shuffle(eval_ids)
    train_ids = sorted(trainpool)
    rng.shuffle(train_ids)
    print(f"eval pool {len(eval_ids)}, train pool {len(train_ids)}", file=sys.stderr)

    # Tune and eval draw from one shuffled order: tune takes the first N_TUNE that download,
    # eval the next N_EVAL. They never share an image.
    plan = [("tune", N_TUNE, eval_ids, evalpool, EVAL_LONG_SIDE), ("train", N_TRAIN, train_ids, trainpool, TRAIN_LONG_SIDE)]
    taken: dict[str, list[tuple[str, dict, tuple[int, int]]]] = {"tune": [], "eval": [], "train": []}
    for role, n, ids, pool, side in plan:
        roles = ["tune", "eval"] if role == "tune" else ["train"]
        targets = {"tune": N_TUNE, "eval": N_EVAL, "train": N_TRAIN}
        skips: dict[str, int] = {}
        cursor = 0
        with ThreadPoolExecutor(8) as ex:
            for r in roles:
                folder = OI / r
                folder.mkdir(parents=True, exist_ok=True)
                while len(taken[r]) < targets[r] and cursor < len(ids):
                    batch = ids[cursor : cursor + (targets[r] - len(taken[r]))]
                    cursor += len(batch)
                    for i, res in zip(batch, ex.map(lambda i: _fetch(pool[i]["split"], i, folder / f"{i}.jpg", side), batch)):
                        if isinstance(res, str):
                            skips[res.split(":")[0]] = skips.get(res.split(":")[0], 0) + 1
                        else:
                            taken[r].append((i, pool[i], res))
                print(f"{r}: {len(taken[r])} images, skipped {skips}", file=sys.stderr)

    MANIFESTS.mkdir(exist_ok=True)
    for r, rows in taken.items():
        rows.sort(key=lambda t: t[0])
        with open(MANIFESTS / f"oi_{r}.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["image_id", "split", "source_url", "landing_url", "license", "author"])
            for i, p, _ in rows:
                s = p["src"]
                w.writerow([i, p["split"], S3.format(split=p["split"], id=i), s["landing_url"], s["license"], s["author"]])
        gt = {
            i: {"w": wh[0], "h": wh[1], "verified": p["verified"], "boxes": p.get("boxes", [])}
            for i, p, wh in rows
        }
        (OI / f"gt_{r}.json").write_text(json.dumps(gt))


if __name__ == "__main__":
    {"select": select, "download": download}[sys.argv[1]]()
