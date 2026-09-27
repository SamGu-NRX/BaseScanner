"""Draw ground truth (green window, blue door, dashed = group-of) and a model's detections at or
above a threshold (red) on one image, for checking coordinates by eye. Writes to DATA/preview.

Usage: python -m autodetect.show <set> <image_id> [model] [threshold]
"""

from __future__ import annotations

import sys

from PIL import Image, ImageDraw

from .paths import DATA
from .sets import ground_truth, image_path, load_preds


def draw(name: str, image_id: str, model: str | None = None, threshold: float = 0.0) -> str:
    im = Image.open(image_path(name, image_id)).convert("RGB")
    w, h = im.size
    d = ImageDraw.Draw(im)
    px = lambda b: [b[0] * w, b[1] * h, b[2] * w, b[3] * h]  # noqa: E731
    for b in ground_truth(name)[image_id]["boxes"]:
        d.rectangle(px(b["box"]), outline=(0, 200, 0) if b["label"] == "window" else (0, 80, 255), width=1 if b["group"] else 3)
    if model:
        for det in load_preds(model, name)["images"][image_id]["dets"]:
            if det["score"] >= threshold:
                d.rectangle(px(det["box"]), outline=(255, 0, 0), width=2)
                d.text((det["box"][0] * w + 2, det["box"][1] * h + 2), f"{det['label'][:1]}{det['score']:.2f}", fill=(255, 0, 0))
    out = DATA / "preview" / f"{name}_{image_id}_{model or 'gt'}.jpg"
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out)
    return str(out)


if __name__ == "__main__":
    a = sys.argv[1:]
    print(draw(a[0], a[1], a[2] if len(a) > 2 else None, float(a[3]) if len(a) > 3 else 0.0))
