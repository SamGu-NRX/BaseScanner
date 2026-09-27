"""Grounding DINO tiny (IDEA-Research/grounding-dino-tiny, Apache-2.0) zero-shot detection through
the ONNX export in onnx-community/grounding-dino-tiny-ONNX, on onnxruntime's CPU provider with the
fp16 graph upcast to fp32 in memory (owl.upcast_fp16).

The export takes a fixed 800 x 800 image. Each image is resized so its long side is 800, padded
bottom and right, and pixel_mask marks the real pixels; predicted boxes are (cx, cy, w, h)
relative to the real pixels, as in DETR-style models. The caption joins the phrases in config,
each ending in " ."; a box's score for a phrase is the highest token probability within that
phrase's tokens, and the box takes its best phrase.

Usage: python -m autodetect.gdino [set ...]    # default: every set, then electro
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

from . import config
from .nms import postprocess
from .owl import upcast_fp16
from .paths import WEIGHTS
from .sets import SETS, ground_truth, image_path, save_preds

DIR = WEIGHTS / "gdino"
MODEL = DIR / "model_fp16.onnx"
URL = "https://huggingface.co/onnx-community/grounding-dino-tiny-ONNX/resolve/main/onnx/model_fp16.onnx"
SIZE = 800
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


class GDino:
    def __init__(self) -> None:
        import onnxruntime as ort
        from tokenizers import Tokenizer

        if not MODEL.exists():
            raise FileNotFoundError(f"{MODEL} missing; download it from {URL}")
        self.session = ort.InferenceSession(upcast_fp16(MODEL), providers=["CPUExecutionProvider"])
        tok = Tokenizer.from_file(str(DIR / "tokenizer.json"))
        self.labels = list(config.GDINO_PHRASES)
        caption = " ".join(f"{p} ." for p in config.GDINO_PHRASES.values())
        enc = tok.encode(caption)
        self.ids = np.array([enc.ids], dtype=np.int64)
        self.mask = np.ones_like(self.ids)
        self.types = np.zeros_like(self.ids)
        # token positions of each phrase, from character offsets in the caption
        spans, pos = [], 0
        for p in config.GDINO_PHRASES.values():
            start = caption.index(p, pos)
            spans.append((start, start + len(p)))
            pos = start + len(p)
        self.token_sets = []
        for a, b in spans:
            toks = [k for k, (s, e) in enumerate(enc.offsets) if e > s and s >= a and e <= b]
            if not toks:
                raise ValueError(f"phrase at {a}:{b} has no tokens")
            self.token_sets.append(toks)

    @staticmethod
    def preprocess(im: Image.Image) -> tuple[np.ndarray, np.ndarray]:
        w, h = im.size
        scale = SIZE / max(w, h)
        nw, nh = round(w * scale), round(h * scale)
        x = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
        x[:nh, :nw] = (np.asarray(im.resize((nw, nh), Image.Resampling.BILINEAR), dtype=np.float32) / 255.0 - MEAN) / STD
        mask = np.zeros((1, SIZE, SIZE), dtype=np.int64)
        mask[0, :nh, :nw] = 1
        return x.transpose(2, 0, 1)[None], mask

    def detect(self, path: Path) -> tuple[list[dict], float, float]:
        im = Image.open(path).convert("RGB")
        t0 = time.perf_counter()
        pixels, pmask = self.preprocess(im)
        t1 = time.perf_counter()
        logits, boxes = self.session.run(
            ["logits", "pred_boxes"],
            {"pixel_values": pixels, "input_ids": self.ids, "token_type_ids": self.types, "attention_mask": self.mask, "pixel_mask": pmask},
        )
        t2 = time.perf_counter()
        prob = 1 / (1 + np.exp(-logits[0]))  # (900, 256)
        per_phrase = np.stack([prob[:, toks].max(1) for toks in self.token_sets], 1)
        label = per_phrase.argmax(1)
        score = per_phrase.max(1)
        cx, cy, bw, bh = boxes[0].T
        xyxy = np.clip(np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], 1), 0, 1)
        return postprocess(xyxy, score, [self.labels[i] for i in label]), 1000 * (t1 - t0), 1000 * (t2 - t1)


def meta() -> dict:
    return {
        "model": "Grounding DINO tiny, ONNX fp16 upcast to fp32",
        "phrases": config.GDINO_PHRASES,
        "license": "Apache-2.0",
        "size": f"{MODEL.stat().st_size / 1e6:.0f} MB (fp16 ONNX)",
        "runtime": "onnxruntime CPU, Mac, fp32",
        "input": "800 x 800 (long side 800, padded)",
        "command": "uv run python -m autodetect.gdino",
    }


def run(model: GDino, name: str) -> None:
    images = {}
    for k, i in enumerate(sorted(ground_truth(name))):
        dets, pre_ms, ms = model.detect(image_path(name, i))
        images[i] = {"elapsed_ms": ms, "preprocess_ms": pre_ms, "dets": dets}
        if k % 50 == 0:
            print(f"{name}: {k} images, last {ms:.0f} ms", file=sys.stderr)
    save_preds("gdino", name, meta(), images)


if __name__ == "__main__":
    g = GDino()
    for s in sys.argv[1:] or (*SETS, "electro"):
        run(g, s)
