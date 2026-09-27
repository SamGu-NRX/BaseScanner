"""Shared post-processing for the open-vocabulary detectors: per-class NMS, a score floor and a
per-image cap, all from config."""

from __future__ import annotations

import numpy as np

from . import config


def nms(boxes: np.ndarray, scores: np.ndarray, iou: float) -> list[int]:
    """Indices kept by greedy NMS, highest score first."""
    order = np.argsort(-scores, kind="stable")
    keep: list[int] = []
    area = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    while len(order):
        i = order[0]
        keep.append(int(i))
        rest = order[1:]
        ix = np.clip(np.minimum(boxes[i, 2], boxes[rest, 2]) - np.maximum(boxes[i, 0], boxes[rest, 0]), 0, None)
        iy = np.clip(np.minimum(boxes[i, 3], boxes[rest, 3]) - np.maximum(boxes[i, 1], boxes[rest, 1]), 0, None)
        inter = ix * iy
        overlap = inter / np.maximum(area[i] + area[rest] - inter, 1e-12)
        order = rest[overlap <= iou]
    return keep


def postprocess(boxes: np.ndarray, scores: np.ndarray, labels: list[str]) -> list[dict]:
    keep_floor = scores >= config.MIN_SCORE
    out: list[dict] = []
    labels_arr = np.array(labels)
    for cls in sorted(set(labels_arr[keep_floor])):
        idx = np.where(keep_floor & (labels_arr == cls))[0]
        for j in nms(boxes[idx], scores[idx], config.NMS_IOU):
            k = idx[j]
            out.append({"label": cls, "score": float(scores[k]), "box": [float(v) for v in boxes[k]]})
    out.sort(key=lambda d: -d["score"])
    return out[: config.MAX_DETS]
