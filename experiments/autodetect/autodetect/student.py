"""The on-device student: a Create ML object detector trained on the Open Images train subset
(1,340 images, window and door, both classes verified in every image, no group-of boxes).

    prepare   hard-link the train images into DATA/student/train with Create ML's annotations.json
    train     run the Swift trainer (transfer learning on Apple's object feature print)
    predict   run the model through Vision on every set and the electro photos with compute units
              .all, and time OI eval again CPU-only
    crop      compare Vision's crop-and-scale options on the tune set only (the one setting chosen
              after training, and never on a scored set)

Usage: python -m autodetect.student prepare
       python -m autodetect.student train <transfer|yolo> <iterations>
       python -m autodetect.student crop <algorithm>
       python -m autodetect.student predict <algorithm> <crop option>
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from . import config
from .oieval import MERGED, average_precision, class_entries
from .paths import DATA
from .sets import SETS, ground_truth, image_path, save_preds

DIR = DATA / "student"
TRAIN = DIR / "train"
BIN = DATA / "bin"


def model_path(algo: str) -> "os.PathLike":
    return DIR / f"window_door_{algo}.mlmodel"


def prepare() -> None:
    TRAIN.mkdir(parents=True, exist_ok=True)
    gt = ground_truth("oi_train")
    ann = []
    for i, g in sorted(gt.items()):
        dest = TRAIN / f"{i}.jpg"
        if not dest.exists():
            os.link(image_path("oi_train", i), dest)
        w, h = g["w"], g["h"]
        boxes = []
        for b in g["boxes"]:
            x0, y0, x1, y1 = b["box"]
            boxes.append({
                "label": b["label"],
                "coordinates": {"x": (x0 + x1) / 2 * w, "y": (y0 + y1) / 2 * h, "width": (x1 - x0) * w, "height": (y1 - y0) * h},
            })
        ann.append({"image": dest.name, "annotations": boxes})
    (TRAIN / "annotations.json").write_text(json.dumps(ann))
    n = sum(len(a["annotations"]) for a in ann)
    print(f"{len(ann)} images, {n} boxes", file=sys.stderr)


def train(algo: str, iterations: int) -> None:
    """Progress goes to DATA/student/train_<algo>.log; rerunning resumes from the session folder."""
    log = DIR / f"train_{algo}.log"
    cmd = [str(BIN / "trainod"), str(TRAIN), str(model_path(algo)), algo, str(iterations), str(DIR / f"session_{algo}")]
    with open(log, "a") as err:
        out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=err, text=True)
    if out.returncode:
        raise RuntimeError(f"trainod failed; see {log}")
    report = out.stdout[out.stdout.index("{") :]
    (DIR / f"train_{algo}.json").write_text(report)
    print(report)


def _run(algo: str, name: str, units: str, crop: str) -> dict:
    ids = sorted(ground_truth(name))
    cmd = [str(BIN / "coremldet"), str(model_path(algo)), units, crop, str(config.STUDENT_CONFIDENCE_FLOOR), str(config.STUDENT_NMS_IOU)]
    paths = "".join(f"{image_path(name, i)}\n" for i in ids)
    out = subprocess.run(cmd, input=paths, capture_output=True, text=True, check=True).stdout.splitlines()
    if len(out) != len(ids):
        raise RuntimeError(f"{name}: sent {len(ids)} images, got {len(out)} results")
    images = {}
    for i, line in zip(ids, out):
        r = json.loads(line)
        if r.get("error"):
            raise RuntimeError(f"{name}/{i}: {r['error']}")
        dets = sorted(r["detections"], key=lambda d: -d["score"])[: config.MAX_DETS]
        images[i] = {"elapsed_ms": r["elapsed_ms"], "dets": [{k: d[k] for k in ("label", "score", "box")} for d in dets]}
    return images


def crop(algo: str) -> None:
    gt = ground_truth("oi_tune")
    for option in ("scaleFill", "scaleFit", "centerCrop"):
        preds = {i: v["dets"] for i, v in _run(algo, "oi_tune", "all", option).items()}
        aps = {c: average_precision(class_entries(gt, preds, c)) for c in ("window", "door", MERGED)}
        print(option, {c: round(v, 3) for c, v in aps.items()})


def predict(algo: str, crop_option: str) -> None:
    size = sum(f.stat().st_size for f in [model_path(algo)])
    meta = {
        "model": f"Create ML MLObjectDetector ({algo}), window and door",
        "license": "ours; trained on Open Images V7 train (CC BY 2.0 images, CC BY 4.0 boxes)",
        "size": f"{size / 1e6:.1f} MB (.mlmodel)",
        "runtime": "Core ML via Vision, compute units .all, Mac",
        "input": f"Vision {crop_option} to the model's input",
        "crop": crop_option,
        "command": f"uv run python -m autodetect.student predict {algo}",
    }
    for s in (*SETS, "electro"):
        save_preds(f"student_{algo}", s, meta, _run(algo, s, "all", crop_option))
    cpu = _run(algo, "oi_eval", "cpu", crop_option)
    save_preds(f"student_{algo}_cpu", "oi_eval", dict(meta, runtime="Core ML via Vision, CPU only, Mac"), cpu)


if __name__ == "__main__":
    step = sys.argv[1]
    algo = sys.argv[2] if len(sys.argv) > 2 else "transfer"
    if step == "prepare":
        prepare()
    elif step == "train":
        train(algo, int(sys.argv[3]))
    elif step == "crop":
        crop(algo)
    elif step == "predict":
        predict(algo, sys.argv[3] if len(sys.argv) > 3 else "scaleFill")
    else:
        raise SystemExit(f"unknown step {step!r}")
