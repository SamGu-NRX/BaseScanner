"""Find and download openly licensed photos of residential electrical panels.

`find` runs a fixed list of searches on Wikimedia Commons and on Openverse (an index of
openly licensed images from Flickr, Commons and other sources) and writes every result under
CC0, public domain, CC BY or CC BY-SA to candidates.csv in the data directory, for screening
by eye. `fetch` downloads the photos listed in the committed manifest.csv.
"""

import argparse
import csv
import io
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageOps

from panel_eval.paths import DATA_DIR, MANIFEST

USER_AGENT = "house-scanning-panel-eval/0.1 (https://github.com/SamGu-NRX/house-scanning)"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
OPENVERSE_API = "https://api.openverse.org/v1/images/"
SEARCHES = [
    "breaker panel",
    "electrical panel",
    "circuit breaker panel",
    "circuit breaker box",
    "breaker box",
    "load center",
    "service panel",
    "electrical service panel",
    "main breaker",
    "panelboard",
    "Square D panel",
    "Federal Pacific",
    "Stab-Lok",
    "Zinsco",
    "Cutler-Hammer panel",
    "Siemens breaker panel",
    "General Electric breaker panel",
    "Murray breaker panel",
    "Challenger breaker panel",
    "Westinghouse breaker panel",
]
# Stored photos are capped at this width, a standard Commons thumbnail step.
MAX_WIDTH = 3840
REUSABLE_COMMONS = re.compile(r"^(CC0|Public domain|PD|CC BY(-SA)? [0-9.]+)", re.IGNORECASE)
REUSABLE_OPENVERSE = {"by", "by-sa", "cc0", "pdm"}


def get_json(url: str, params: dict, post: bool = False) -> dict:
    encoded = urllib.parse.urlencode(params)
    request = (
        urllib.request.Request(url, data=encoded.encode(), headers={"User-Agent": USER_AGENT})
        if post
        else urllib.request.Request(f"{url}?{encoded}", headers={"User-Agent": USER_AGENT})
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 3:
                raise
            time.sleep(30 * (attempt + 1))
    raise AssertionError("unreachable")


def commons(query: str) -> list[dict]:
    hits = get_json(
        COMMONS_API,
        {
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srnamespace": "6",
            "srlimit": "100",
            "format": "json",
            "formatversion": "2",
        },
    )["query"]["search"]
    titles = [hit["title"] for hit in hits]
    rows = []
    for start in range(0, len(titles), 50):
        data = get_json(
            COMMONS_API,
            {
                "action": "query",
                "titles": "|".join(titles[start : start + 50]),
                "prop": "imageinfo",
                "iiprop": "url|size|mime|extmetadata",
                "iiurlwidth": str(MAX_WIDTH),
                "format": "json",
                "formatversion": "2",
            },
            post=True,
        )
        for page in data["query"]["pages"]:
            info = (page.get("imageinfo") or [None])[0]
            if not info or info.get("mime") not in ("image/jpeg", "image/png"):
                continue
            meta = info.get("extmetadata", {})

            def field(name: str, meta=meta) -> str:
                value = str(meta.get(name, {}).get("value", ""))
                return " ".join(re.sub(r"<[^>]+>", "", value).split())

            if not REUSABLE_COMMONS.match(field("LicenseShortName")):
                continue
            wide = info["width"] > MAX_WIDTH and "thumburl" in info
            rows.append(
                {
                    "source": "wikimedia",
                    "title": page["title"],
                    "page_url": info["descriptionurl"],
                    "image_url": (info["thumburl"] if wide else info["url"]).split("?")[0],
                    "width": info["width"],
                    "height": info["height"],
                    "license": field("LicenseShortName"),
                    "license_url": field("LicenseUrl"),
                    "author": field("Artist")[:120],
                }
            )
    return rows


def openverse(query: str, pages: int = 5) -> list[dict]:
    rows = []
    for page in range(1, pages + 1):
        data = get_json(
            OPENVERSE_API,
            {
                "q": query,
                "license": ",".join(sorted(REUSABLE_OPENVERSE)),
                "page_size": "20",
                "page": str(page),
            },
        )
        for item in data["results"]:
            if item["license"] not in REUSABLE_OPENVERSE:
                continue
            license_name = f"CC {item['license'].upper()} {item.get('license_version') or ''}"
            rows.append(
                {
                    "source": item["source"],
                    "title": item["title"] or "",
                    "page_url": item["foreign_landing_url"],
                    "image_url": item["url"],
                    "width": item.get("width") or "",
                    "height": item.get("height") or "",
                    "license": license_name.strip(),
                    "license_url": item.get("license_url") or "",
                    "author": (item.get("creator") or "")[:120],
                }
            )
        if page >= data.get("page_count", 0):
            break
        time.sleep(2)
    return rows


def find(args: argparse.Namespace) -> None:
    found: dict[str, dict] = {}
    for query in SEARCHES:
        for row in commons(query) + openverse(query):
            found.setdefault(row["page_url"], row)
        print(f"{query}: {len(found)} unique so far", flush=True)
        time.sleep(2)
    rows = [
        r
        for r in found.values()
        if not r["width"] or min(int(r["width"]), int(r["height"])) >= args.min_side
    ]
    out = DATA_DIR / "candidates.csv"
    with out.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"{len(rows)} candidates -> {out}")


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
    """Apply EXIF rotation, cap the width, save plain RGB."""
    with Image.open(io.BytesIO(data)) as image:
        upright = ImageOps.exif_transpose(image).convert("RGB")
        if upright.width > MAX_WIDTH:
            upright.thumbnail((MAX_WIDTH, MAX_WIDTH * 4))
        upright.save(dest, quality=95)


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
    p_find = sub.add_parser("find", help="list reusable candidate photos")
    p_find.add_argument("--min-side", type=int, default=800)
    p_find.set_defaults(func=find)
    p_fetch = sub.add_parser("fetch", help="download the photos in manifest.csv")
    p_fetch.add_argument(
        "--source", help="CSV with id and image_url columns (default manifest.csv)"
    )
    p_fetch.set_defaults(func=fetch)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
