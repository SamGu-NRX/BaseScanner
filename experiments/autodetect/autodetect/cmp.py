"""CMP Facade base set (Tylecek and Sara, GCPR 2013; CC BY-SA) as a second, frontal eval set.

Every facade element is annotated, so window and door count as verified in every image: an
image with no door rectangle is a verified negative for door. There are no group-of boxes.

In the XML, the two <x> values are the rectangle's vertical extent and the two <y> values its
horizontal extent, both normalized with a top-left origin. Read as labelled, window rectangles
cover 18% window pixels in the set's own label maps on average; swapped, they cover 87% (the
rest is blinds and railings drawn over windows), and they sit on the windows by eye.

The images are rectified frontal facades, often several storeys, shot from across a street.
The app sees one wall from 1 to 3 m at an angle, so this set tests recognition on a different
view from the product's.

Usage: python -m autodetect.cmp    # DATA/cmp/gt.json and manifests/cmp_base.csv
"""

from __future__ import annotations

import csv
import json
import re
from pathlib import Path

from PIL import Image

from .paths import CMP, MANIFESTS

URL = "https://cmp.felk.cvut.cz/~tylecr1/facade/CMP_facade_DB_base.zip"
OBJECT = re.compile(r"<object>(.*?)</object>", re.S)


def _field(block: str, tag: str) -> list[str]:
    return [v.strip() for v in re.findall(rf"<{tag}>(.*?)</{tag}>", block, re.S)]


def parse(xml_path: Path) -> list[dict]:
    boxes = []
    for block in OBJECT.findall(xml_path.read_text()):
        (name,) = _field(block, "labelname")
        if name not in ("window", "door"):
            continue
        rows = sorted(float(v) for v in _field(block, "x"))  # vertical, despite the tag
        cols = sorted(float(v) for v in _field(block, "y"))  # horizontal
        if len(rows) != 2 or len(cols) != 2:
            raise ValueError(f"{xml_path.name}: expected 2 <x> and 2 <y> values, got {rows} {cols}")
        boxes.append({"label": name, "box": [cols[0], rows[0], cols[1], rows[1]], "group": False})
    return boxes


def build() -> None:
    gt = {}
    for xml in sorted((CMP / "base").glob("cmp_b*.xml")):
        image_id = xml.stem
        boxes = parse(xml)
        with Image.open(xml.with_suffix(".jpg")) as im:
            w, h = im.size
        labels = {b["label"] for b in boxes}
        gt[image_id] = {
            "w": w,
            "h": h,
            "verified": {c: int(c in labels) for c in ("window", "door")},
            "boxes": boxes,
        }
    (CMP / "gt.json").write_text(json.dumps(gt))
    with open(MANIFESTS / "cmp_base.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["image_id", "source_url", "license", "author"])
        for image_id in gt:
            w.writerow([image_id, URL, "CC BY-SA 3.0", "R. Tylecek, R. Sara, CMP Prague (collected from various sources)"])
    n_w = sum(b["label"] == "window" for g in gt.values() for b in g["boxes"])
    n_d = sum(b["label"] == "door" for g in gt.values() for b in g["boxes"])
    print(f"{len(gt)} images, {n_w} windows, {n_d} doors, {sum(g['verified']['door'] for g in gt.values())} images with a door")


if __name__ == "__main__":
    build()
