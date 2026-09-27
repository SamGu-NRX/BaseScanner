"""Score every cached candidate and write results/proposals.md.

For each model and class: the operating threshold from the OI tune set, then precision, recall
and AP50 on OI eval and CMP, the pass verdict per set, a near-sized diagnostic, and Mac latency.

Usage: python -m autodetect.score [model ...]    # default: every model with cached predictions
"""

from __future__ import annotations

import datetime
import math
import sys

import numpy as np

from . import config
from .oieval import MERGED, at_threshold, average_precision, choose_threshold, class_entries
from .paths import PREDS, RESULTS
from .sets import ground_truth, load_preds

CLASSES = ("window", "door", MERGED)
HELD_OUT = ("oi_eval", "cmp")
SET_NAMES = {"oi_eval": "Open Images eval", "cmp": "CMP base", "oi_tune": "Open Images tune"}


def _fmt(x: float, pct: bool = True) -> str:
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "n/a"
    return f"{100 * x:.1f}%" if pct else f"{x:.3f}"


def speed_class(ms: float) -> str:
    if ms <= config.LIVE_MS:
        return "live"
    if ms <= config.KEYFRAME_MS:
        return "keyframe"
    return "offline"


def latency(preds: dict) -> tuple[float, float, int]:
    """Median and p90 per-image ms, skipping the first image (model load and warm-up)."""
    ms = [v["elapsed_ms"] for _, v in sorted(preds["images"].items())][1:]
    return float(np.median(ms)), float(np.percentile(ms, 90)), len(ms)


def model_classes(preds: dict) -> list[str]:
    labels = {d["label"] for v in preds["images"].values() for d in v["dets"]}
    return [c for c in CLASSES if c in labels or (c == MERGED and labels & {"window", "door"})]


def as_images(preds: dict) -> dict[str, list[dict]]:
    return {i: v["dets"] for i, v in preds["images"].items()}


def score_model(model: str) -> dict:
    tune = load_preds(model, "oi_tune")
    out = {"model": model, "meta": tune["meta"], "classes": {}}
    gts = {s: ground_truth(s) for s in ("oi_tune", *HELD_OUT)}
    preds = {s: as_images(load_preds(model, s)) for s in ("oi_tune", *HELD_OUT)}
    for cls in model_classes(tune):
        e_tune = class_entries(gts["oi_tune"], preds["oi_tune"], cls)
        t, rule = choose_threshold(e_tune, config.MIN_PRECISION)
        row = {"threshold": t, "rule": rule, "tune": at_threshold(e_tune, t), "sets": {}}
        for s in HELD_OUT:
            e = class_entries(gts[s], preds[s], cls)
            near = class_entries(gts[s], preds[s], cls, near_min_side=config.NEAR_MIN_SIDE)
            r = at_threshold(e, t)
            r["ap50"] = average_precision(e)
            r["images"] = e.num_images
            r["passes"] = bool(r["recall"] >= config.MIN_RECALL and r["precision"] >= config.MIN_PRECISION)
            rn = at_threshold(near, t)
            rn["ap50"] = average_precision(near)
            t_oracle, oracle_rule = choose_threshold(e, config.MIN_PRECISION)
            ro = at_threshold(e, t_oracle)
            ro["reaches_bar"] = oracle_rule.startswith("lowest")
            row["sets"][s] = {"all": r, "near": rn, "oracle": ro}
        out["classes"][cls] = row
    out["latency"] = {s: latency(load_preds(model, s)) for s in HELD_OUT}
    return out


def write(results: list[dict]) -> None:
    L = [
        "# Proposals: window and door detection",
        "",
        f"Generated {datetime.date.today()} by `uv run python -m autodetect.score` from cached predictions",
        "(see each model's run command below). Criteria are in `../README.md`, settings in",
        "`../autodetect/config.py`. IoU 0.5; Open Images rules for unverified classes and group-of boxes.",
        "The threshold is chosen on the 150-image OI tune set and applied unchanged to both held-out sets.",
        "",
        "## Operating point",
        "",
        "Pass needs recall >= 80% and precision >= 60% at the operating threshold, judged per set.",
        "",
        "| Model | Class | Threshold | Set | Images | GT | TP | FP | Precision | Recall | AP50 | Pass |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in results:
        for cls, row in r["classes"].items():
            for s in HELD_OUT:
                a = row["sets"][s]["all"]
                L.append(
                    f"| {r['model']} | {cls} | {row['threshold']:.3f} | {SET_NAMES[s]} | {a['images']} | {a['num_gt']} | "
                    f"{a['tp']} | {a['fp']} | {_fmt(a['precision'])} | {_fmt(a['recall'])} | {_fmt(a['ap50'])} | "
                    f"{'yes' if a['passes'] else 'no'} |"
                )
    L += [
        "",
        "## Tune-set operating point (where each threshold came from)",
        "",
        "| Model | Class | Threshold | Rule | Tune precision | Tune recall |",
        "|---|---|---|---|---|---|",
    ]
    for r in results:
        for cls, row in r["classes"].items():
            tu = row["tune"]
            L.append(f"| {r['model']} | {cls} | {row['threshold']:.3f} | {row['rule']} | {_fmt(tu['precision'])} | {_fmt(tu['recall'])} |")
    L += [
        "",
        "## Diagnostic: best recall at 60% precision on the scored set itself",
        "",
        "Not a pass criterion: the threshold here is chosen on the set it is scored on. It shows whether",
        "a failure comes from the tune-set threshold not transferring or from the model, since no",
        "threshold passes when even this recall is under 80%.",
        "",
        "| Model | Class | Set | Threshold | Precision | Recall |",
        "|---|---|---|---|---|---|",
    ]
    for r in results:
        for cls, row in r["classes"].items():
            for s in HELD_OUT:
                o = row["sets"][s]["oracle"]
                note = "" if o["reaches_bar"] else " (never reaches 60%; best F1)"
                L.append(f"| {r['model']} | {cls} | {SET_NAMES[s]} | {o['threshold']:.3f}{note} | {_fmt(o['precision'])} | {_fmt(o['recall'])} |")
    L += [
        "",
        "## Diagnostic: near-sized objects only",
        "",
        f"Not a pass criterion. Ground-truth boxes narrower or shorter than {config.NEAR_MIN_SIDE:.0%} of the image",
        "are treated as difficult (a detection on one is ignored, a miss is not counted), and detections",
        "that small are dropped, to approximate the large objects in a 1 to 3 m phone frame. Same",
        "thresholds. Dropping small detections was added after the first scored run showed that",
        "without it the small false positives alone kept precision under 25%.",
        "",
        "| Model | Class | Set | GT | Precision | Recall | AP50 |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in results:
        for cls, row in r["classes"].items():
            for s in HELD_OUT:
                n = row["sets"][s]["near"]
                L.append(f"| {r['model']} | {cls} | {SET_NAMES[s]} | {n['num_gt']} | {_fmt(n['precision'])} | {_fmt(n['recall'])} | {_fmt(n['ap50'])} |")
    L += [
        "",
        "## Model, license and Mac latency",
        "",
        "Latency is per image on this Mac (Apple M4 Pro, 24 GB), inference call only, excluding JPEG",
        "decode, preprocessing and the first (warm-up) image. It is not an iPhone number; a phone is",
        "slower. Other agents shared the Mac throughout: the load average column is the 1, 5 and 15",
        "minute load when the OI eval predictions were saved (12 cores), and loads of 100 to 490 were",
        "seen during the OWLv2 run, so every timing here is likely slower than on an idle Mac.",
        "",
        "| Model | License | Size | Runtime | Input | OI eval median ms | OI eval p90 ms | CMP median ms | CPU-only median / p90 ms | Load average | Speed class (Mac, p90) | Command |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in results:
        m = r["meta"]
        oi_med, oi_p90, _ = r["latency"]["oi_eval"]
        cmp_med, _, _ = r["latency"]["cmp"]
        cpu = "n/a"
        if (PREDS / f"{r['model']}_cpu" / "oi_eval.json").exists():
            c_med, c_p90, _ = latency(load_preds(f"{r['model']}_cpu", "oi_eval"))
            cpu = f"{c_med:.1f} / {c_p90:.1f} ({speed_class(c_p90)})"
        load = load_preds(r["model"], "oi_eval")["meta"].get("load_avg_at_save", "not recorded")
        L.append(
            f"| {r['model']} | {m.get('license', '?')} | {m.get('size', '?')} | {m.get('runtime', '?')} | {m.get('input', '?')} | "
            f"{oi_med:.1f} | {oi_p90:.1f} | {cmp_med:.1f} | {cpu} | {load} | {speed_class(oi_p90)} | `{m.get('command', '?')}` |"
        )
    (RESULTS / "proposals.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    models = sys.argv[1:] or sorted(p.name for p in PREDS.iterdir() if (p / "oi_tune.json").exists())
    results = [score_model(m) for m in models]
    write(results)
    for r in results:
        for cls, row in r["classes"].items():
            for s in HELD_OUT:
                a = row["sets"][s]["all"]
                print(f"{r['model']:14s} {cls:15s} {s:8s} P {_fmt(a['precision']):>6s} R {_fmt(a['recall']):>6s} AP {_fmt(a['ap50']):>6s}", file=sys.stderr)
