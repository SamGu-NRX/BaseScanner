"""Find and download openly licensed meter photos from Wikimedia Commons.

`find` walks the meter category tree plus a few brand searches and writes every
reusable-license image to candidates.csv in the data directory, for screening by eye.
`fetch` downloads the images listed in the committed manifest.csv.
"""

import argparse
import csv
import io
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageOps

from meter_eval.paths import DATA_DIR, MANIFEST

API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "house-scanning-meter-eval/0.1 (https://github.com/SamGu-NRX/house-scanning)"
ROOT_CATEGORY = "Category:Electricity meters (kWh)"
SEARCHES = [
    "electric meter Itron",
    "electric meter Landis",
    "electric meter Sensus",
    "electric meter Elster",
    "electric meter Aclara",
    "electric meter General Electric",
    "smart meter house",
    "electric meter closeup",
    "watthour meter",
]
# Stored images are capped at this width, a standard Commons thumbnail step. iPhone close-ups
# are 4032 px wide; the shared disk cannot hold originals of 20+ MB each.
MAX_WIDTH = 3840

REUSABLE = re.compile(r"^(CC0|Public domain|PD|CC BY(-SA)? [0-9.]+)", re.IGNORECASE)


def api_get(**params) -> dict:
    params = {**params, "format": "json", "formatversion": "2"}
    # POST: 50 long file titles overflow the URL length limit of a GET.
    request = urllib.request.Request(
        API, data=urllib.parse.urlencode(params).encode(), headers={"User-Agent": USER_AGENT}
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except OSError:
            if attempt == 3:
                raise
            time.sleep(2 + 3 * attempt)
    raise AssertionError("unreachable")


def walk_category(root: str, max_depth: int) -> set[str]:
    files: set[str] = set()
    seen: set[str] = set()
    frontier = [(root, 0)]
    while frontier:
        category, depth = frontier.pop()
        if category in seen:
            continue
        seen.add(category)
        cont: dict = {}
        while True:
            data = api_get(
                action="query",
                list="categorymembers",
                cmtitle=category,
                cmlimit="500",
                cmtype="file|subcat",
                **cont,
            )
            for member in data["query"]["categorymembers"]:
                if member["ns"] == 6:
                    files.add(member["title"])
                elif member["ns"] == 14 and depth < max_depth:
                    frontier.append((member["title"], depth + 1))
            if "continue" not in data:
                break
            cont = data["continue"]
    print(f"{len(seen)} categories, {len(files)} files under {root}", file=sys.stderr)
    return files


def search_files(query: str, limit: int = 200) -> set[str]:
    data = api_get(action="query", list="search", srsearch=query, srnamespace="6", srlimit=limit)
    return {hit["title"] for hit in data["query"]["search"]}


def image_info(titles: list[str]) -> list[dict]:
    rows = []
    for start in range(0, len(titles), 50):
        batch = titles[start : start + 50]
        data = api_get(
            action="query",
            titles="|".join(batch),
            prop="imageinfo",
            iiprop="url|size|mime|extmetadata",
            iiurlwidth=str(MAX_WIDTH),
        )
        for page in data["query"]["pages"]:
            info = (page.get("imageinfo") or [None])[0]
            if not info or info.get("mime") not in ("image/jpeg", "image/png"):
                continue
            meta = info.get("extmetadata", {})

            def field(name: str, meta=meta) -> str:
                value = meta.get(name, {}).get("value", "")
                return re.sub(r"<[^>]+>", "", str(value)).strip()

            # Originals up to MAX_WIDTH; wider ones as a MAX_WIDTH thumbnail.
            wide = info["width"] > MAX_WIDTH and "thumburl" in info
            rows.append(
                {
                    "title": page["title"],
                    "page_url": info["descriptionurl"],
                    "image_url": (info["thumburl"] if wide else info["url"]).split("?")[0],
                    "width": info["width"],
                    "height": info["height"],
                    "license": field("LicenseShortName"),
                    "license_url": field("LicenseUrl"),
                    "author": field("Artist"),
                    "description": field("ImageDescription")[:200],
                }
            )
    return rows


def find(args: argparse.Namespace) -> None:
    titles = walk_category(ROOT_CATEGORY, args.depth)
    for query in SEARCHES:
        titles |= search_files(query)
    rows = [
        row
        for row in image_info(sorted(titles))
        if REUSABLE.match(row["license"]) and min(row["width"], row["height"]) >= args.min_side
    ]
    out = DATA_DIR / "candidates.csv"
    with out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"{len(rows)} reusable candidates of {len(titles)} files -> {out}")


def download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 3:
                raise
            time.sleep(30 * (attempt + 1))
    raise AssertionError("unreachable")


def save_upright(data: bytes, dest: Path) -> None:
    """Apply EXIF rotation and save plain RGB, so Vision and the checks see the same pixels."""
    with Image.open(io.BytesIO(data)) as image:
        ImageOps.exif_transpose(image).convert("RGB").save(dest, quality=95)


def fetch(args: argparse.Namespace) -> None:
    source = Path(args.source) if args.source else MANIFEST
    with source.open() as handle:
        rows = list(csv.DictReader(handle))
    images = DATA_DIR / "images"
    images.mkdir(parents=True, exist_ok=True)
    for row in rows:
        dest = images / f"{row['id']}.jpg"
        if dest.exists():
            continue
        save_upright(download(row["image_url"]), dest)
        print(f"fetched {row['id']}", flush=True)
        time.sleep(1.0)
    print(f"{len(rows)} images in {images}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)
    p_find = sub.add_parser("find", help="list reusable candidate images")
    p_find.add_argument("--depth", type=int, default=3)
    p_find.add_argument("--min-side", type=int, default=800)
    p_find.set_defaults(func=find)
    p_fetch = sub.add_parser("fetch", help="download the images in manifest.csv")
    p_fetch.add_argument(
        "--source", help="CSV with id and image_url columns (default manifest.csv)"
    )
    p_fetch.set_defaults(func=fetch)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
