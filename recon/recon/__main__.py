"""python -m recon BUNDLE --out OUT [--depth auto|lidar|moge] [--server URL | --no-server]"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from recon.pipeline import run
from recon.server import DEFAULT_URL

DATA = Path(os.environ.get("HOUSE_SCANNING_DATA", Path.home() / "house-scanning-data"))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "bundle",
        type=Path,
        help="app scan bundle (zip or folder with scene.json) or Measure Lab session",
    )
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument(
        "--work", type=Path, default=DATA / "recon" / "work", help="unpacked bundles and depth maps"
    )
    ap.add_argument("--depth", choices=["auto", "lidar", "moge"], default="auto")
    ap.add_argument("--server", default=os.environ.get("HOUSESCAN_SERVER", DEFAULT_URL))
    ap.add_argument("--no-server", action="store_true")
    ap.add_argument(
        "--move-meter",
        action="store_true",
        help="when the phone's wall or meter has no reconstructed wall behind it, move the meter "
        "onto the most-seen wall instead of refusing (drops the phone's marks)",
    )
    args = ap.parse_args()
    server = None if args.no_server else args.server
    done = run(args.bundle, args.out, args.work, args.depth, server, args.move_meter)
    print(done["report"])


if __name__ == "__main__":
    main()
