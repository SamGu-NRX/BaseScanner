"""Merge the two readers' labels into the committed manifest.csv.

Both readers are AI models that read each photo by eye (reader 1 is the experiment author,
reader 2 an independent pass that never saw reader 1's labels). A meter number counts as
agreed when one of reader 2's numbers equals reader 1's number after normalization, or one
contains the other and the shorter has at least 6 characters (a barcode line such as
ACG012345678 printing the plate number 12 345 678), and neither reader doubted a character.
Plaintext labels stay in the data directory; the manifest keeps only digests (see match.py).
"""

import csv
import re

from meter_eval.commons import MANIFEST
from meter_eval.match import digest, lenient_digest, normalize, normalize_class
from meter_eval.paths import DATA_DIR

READER1 = DATA_DIR / "labels_reader1.csv"
READER2 = [DATA_DIR / "labels_reader2a.csv", DATA_DIR / "labels_reader2b.csv"]
SOURCES = DATA_DIR / "shortlist.csv"
# Reader 2 marked these "unsure" for a reason other than the characters of reader 1's number,
# per its notes: which of two printed numbers is the meter's ID (m25, m30, m33, m38), or a
# second number cut off by the frame (m63). It transcribed reader 1's number identically.
DOUBT_NOT_ABOUT_CHARACTERS = {"m25", "m30", "m33", "m38", "m63"}

FIELDS = [
    "id",
    "title",
    "page_url",
    "image_url",
    "license",
    "license_url",
    "author",
    "usable",
    "number_sha256",
    "number_sha256_lenient",
    "number_len",
    "number_agreed",
    "class_label",
    "class_kind",
    "class_agreed",
    "notes",
]


def read_csv(path) -> dict[str, dict]:
    with path.open() as handle:
        return {row["id"]: row for row in csv.DictReader(handle)}


def numbers_of(row: dict) -> set[str]:
    values = [row["meter_number"], *row.get("other_numbers", "").split(";")]
    # Reader 2 annotated some numbers in parentheses, e.g. "12345678 (FlexNet)".
    values = [re.sub(r"\(.*?\)", "", v) for v in values]
    return {normalize(v) for v in values if v.strip() and v not in ("NONE", "EXCLUDE")}


def same_number(a: str, b: str) -> bool:
    short, long = sorted((a, b), key=len)
    return a == b or (len(short) >= 6 and short in long)


def class_kind(label: str) -> str:
    if not label or label == "NONE":
        return ""
    return "ansi_class" if "CL" in label.upper() else "current_rating"


def scrub(note: str) -> str:
    """Drop digit runs from free-text notes so no meter number reaches the repository."""
    return re.sub(r"\d[\d ]{3,}\d", "#", note)


def build() -> list[dict]:
    first, sources = read_csv(READER1), read_csv(SOURCES)
    second = {k: v for path in READER2 for k, v in read_csv(path).items()}
    rows = []
    for image_id, r1 in first.items():
        r2 = second[image_id]
        source = sources[image_id]
        number = r1["meter_number"]
        usable = "no: " + r1["notes"] if number == "EXCLUDE" else "yes"
        row = {key: source[key] for key in ("title", "page_url", "image_url", "license")}
        row |= {
            "id": image_id,
            "license_url": source["license_url"],
            "author": " ".join(source["author"].split())[:120],
            "usable": usable,
            "notes": scrub(r1["notes"]),
        }
        if number not in ("EXCLUDE", "NONE"):
            r2_sure = r2["number_sure"] == "sure" or image_id in DOUBT_NOT_ABOUT_CHARACTERS
            agreed = (
                any(same_number(normalize(number), other) for other in numbers_of(r2))
                and r1["number_sure"] == "sure"
                and r2_sure
            )
            row |= {
                "number_sha256": digest(normalize(number)),
                "number_sha256_lenient": lenient_digest(number),
                "number_len": len(normalize(number)),
                "number_agreed": "yes" if agreed else "no",
            }
        label = r1["class_label"]
        if usable == "yes" and label and label != "NONE":
            agreed = (
                normalize_class(label) == normalize_class(r2["class_label"])
                and r1["class_sure"] == "sure"
                and r2["class_sure"] == "sure"
            )
            row |= {
                "class_label": label,
                "class_kind": class_kind(label),
                "class_agreed": "yes" if agreed else "no",
            }
        rows.append(row)
    return rows


def main() -> None:
    rows = build()
    with MANIFEST.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, restval="")
        writer.writeheader()
        writer.writerows(rows)
    usable = [r for r in rows if r["usable"] == "yes"]
    agreed = [r for r in usable if r.get("number_agreed") == "yes"]
    print(f"{len(rows)} images, {len(usable)} usable, {len(agreed)} with an agreed meter number")


if __name__ == "__main__":
    main()
