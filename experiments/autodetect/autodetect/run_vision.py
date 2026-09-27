"""Apple Vision rectangles as class-agnostic proposals. Every rectangle is labelled "window", so
it is scored as window, and as window-or-door through the merged class in oieval.

Usage: python -m autodetect.run_vision [set ...]    # default: every set
"""

from __future__ import annotations

import json
import subprocess
import sys

from .config import VISION_RECTS
from .paths import DATA
from .sets import SETS, ground_truth, image_path, save_preds

BIN = DATA / "bin" / "rects"


def run(name: str) -> None:
    ids = sorted(ground_truth(name))
    lines = "".join(json.dumps({"path": str(image_path(name, i)), **VISION_RECTS}) + "\n" for i in ids)
    out = subprocess.run([str(BIN)], input=lines, capture_output=True, text=True, check=True).stdout.splitlines()
    if len(out) != len(ids):
        raise RuntimeError(f"{name}: sent {len(ids)} images, got {len(out)} results")
    images = {}
    for i, line in zip(ids, out):
        r = json.loads(line)
        if r.get("error"):
            raise RuntimeError(f"{name}/{i}: {r['error']}")
        dets = [{"label": "window", "score": x["score"], "box": x["box"]} for x in r["rects"]]
        images[i] = {"elapsed_ms": r["elapsed_ms"], "dets": dets}
    meta = {
        "model": "Apple Vision VNDetectRectanglesRequest",
        "params": VISION_RECTS,
        "license": "OS API (no weights shipped)",
        "size": "0 (in the OS)",
        "runtime": "Vision, Mac",
        "input": "image as stored (OI 1024 px, CMP about 1024 px)",
        "command": "uv run python -m autodetect.run_vision",
    }
    save_preds("vision_rects", name, meta, images)
    print(f"{name}: {len(images)} images, {sum(len(v['dets']) for v in images.values())} rectangles", file=sys.stderr)


if __name__ == "__main__":
    for s in sys.argv[1:] or SETS:
        run(s)
