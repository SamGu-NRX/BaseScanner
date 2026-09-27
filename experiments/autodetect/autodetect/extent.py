"""3D extent: lift detected door boxes onto their wall through the laser depth and compare each
edge with the door's edge measured in the laser scan (extent_gt.py).

For every photo and every ground-truth door, the door's rectangle is projected into the photo.
A detection at the model's door operating threshold (chosen on the OI tune set) matches the
projected door at IoU >= 0.5, highest score first. Lifting uses only what the app would have, the
photo's pose, intrinsics and depth: a vertical plane is RANSAC-fitted to the depth inside the
detection's box grown by 30%, and rays through the box meet that plane. Two rules turn the box
into edges, both reported:

- mid-side: rays through the midpoints of the box's four sides.
- inner corner: rays through the box's four corners; each edge takes the inner of its two corners
  (the right-most of the left pair, the lowest of the top pair, and so on). A door seen at an angle
  projects to a quadrilateral whose axis-aligned box touches it at one corner per side, so the other
  corner of that side lies outside the door; the inner one is the door's own corner when the box
  is tight.

A door the photo cuts off is scored separately: the top of its visible part sits at the border
crossing, so an axis-aligned box cannot place its edges, and skipping border corners made the
control worse (p90 0.25 to 0.33 ft). The primary numbers use doors wholly inside the photo.

Lifted points are measured along the door's wall and as heights, in the ground-truth frame. Edges
that the photo cuts off are not scored.

A model's "any score" row matches its door detections down to the cached floor (0.01) instead of
the operating threshold. The homeowner confirms a proposal whatever its score, so this row isolates
how well a matched box places the door from whether the threshold keeps it.

The "projected ground truth" row lifts the projected door rectangle itself through the same steps.
Its error is what the lifting adds on its own: plane fit, and the box sides of a door seen at an
angle not being the door's edges.

Usage: python -m autodetect.extent [model ...]    # writes results/extent.md
"""

from __future__ import annotations

import datetime
import json
import sys

import numpy as np

from . import config
from .electro import FT, WallFrame, fit_vertical_plane, ground_y, photos
from .oieval import _iou, choose_threshold, class_entries
from .paths import DATA, RESULTS
from .sets import ground_truth, load_preds, pred_path

EDGES = ("left", "right", "bottom", "top")
BORDER = 0.005  # a projected edge this close to or past the photo border is cut off
REF = "projected ground truth"


def gt_doors() -> dict[str, dict]:
    doors = json.loads((DATA / "extent_gt.json").read_text())
    for d in doors.values():
        d["frame"] = WallFrame.from_normal(np.array(d["origin"]), np.array(d["normal"]))
    return doors


def rectangle(door: dict) -> np.ndarray:
    """The door's four corners in the meter frame: TL, TR, BR, BL."""
    f, e = door["frame"], door["edges_m"]

    def pt(a: float, h: float) -> np.ndarray:
        p = f.origin + a * f.along
        return np.array([p[0], ground_y() + h, p[2]])

    return np.array([pt(e["left"], e["top"]), pt(e["right"], e["top"]), pt(e["right"], e["bottom"]), pt(e["left"], e["bottom"])])


def projected_box(photo, door: dict) -> tuple[list[float], dict[str, bool]] | None:
    """Clipped normalized box of the door in a photo, and which edges are inside the photo."""
    corners = rectangle(door)
    cam = (corners - photo.pose[:3, 3]) @ photo.pose[:3, :3]
    if (cam[:, 2] > -0.3).any():  # behind or at the camera
        return None
    xy = photo.project(corners)
    x0, y0 = xy.min(0)
    x1, y1 = xy.max(0)
    inside = {"left": x0 > BORDER, "right": x1 < 1 - BORDER, "top": y0 > BORDER, "bottom": y1 < 1 - BORDER}
    poly = clip_to_frame(xy)
    if len(poly) < 3:
        return None
    box = [*poly.min(0), *poly.max(0)]  # what a detector sees: bounds of the visible part
    if box[2] - box[0] < 0.02 or box[3] - box[1] < 0.02:
        return None
    return box, inside


def clip_to_frame(poly: np.ndarray) -> np.ndarray:
    """Sutherland-Hodgman clip of a polygon (normalized coordinates) to the unit square."""
    pts = [tuple(p) for p in poly]
    for axis, bound, keep_low in ((0, 0.0, False), (0, 1.0, True), (1, 0.0, False), (1, 1.0, True)):
        inside = (lambda p: p[axis] <= bound) if keep_low else (lambda p: p[axis] >= bound)
        out = []
        for i, cur in enumerate(pts):
            prev = pts[i - 1]
            if inside(cur) != inside(prev):
                t = (bound - prev[axis]) / (cur[axis] - prev[axis])
                out.append(tuple(prev[k] + t * (cur[k] - prev[k]) for k in range(2)))
            if inside(cur):
                out.append(cur)
        pts = out
        if not pts:
            break
    return np.array(pts).reshape(-1, 2)


RULES = ("mid-side", "inner corner")


def lift(photo, box: list[float], door: dict, rule: str) -> dict[str, float]:
    """Edges of a normalized box lifted onto the wall, in the door's ground-truth frame (m)."""
    x0, y0, x1, y1 = box
    gw, gh = 0.3 * (x1 - x0), 0.3 * (y1 - y0)
    pts = photo.depth_points(x0 - gw, y0 - gh, x1 + gw, y1 + gh)
    plane, _ = fit_vertical_plane(pts, toward=photo.pose[:3, 3])
    if rule == "mid-side":
        xm, ym = (x0 + x1) / 2, (y0 + y1) / 2
        u = np.array([x0, x1, xm, xm]) * photo.W
        v = np.array([ym, ym, y1, y0]) * photo.H
        c = door["frame"].coords(plane.intersect(*photo.ray(u, v)))
        return {"left": c[0, 0], "right": c[1, 0], "bottom": c[2, 1], "top": c[3, 1]}
    if rule == "inner corner":
        u = np.array([x0, x1, x1, x0]) * photo.W  # TL, TR, BR, BL
        v = np.array([y0, y0, y1, y1]) * photo.H
        c = door["frame"].coords(plane.intersect(*photo.ray(u, v)))
        return {
            "left": max(c[0, 0], c[3, 0]),
            "right": min(c[1, 0], c[2, 0]),
            "top": min(c[0, 1], c[1, 1]),
            "bottom": max(c[2, 1], c[3, 1]),
        }
    raise ValueError(f"unknown lifting rule {rule!r}")


def door_threshold(model: str) -> float:
    cls = "window" if model == "vision_rects" else "door"
    preds = {i: v["dets"] for i, v in load_preds(model, "oi_tune")["images"].items()}
    t, _ = choose_threshold(class_entries(ground_truth("oi_tune"), preds, cls), config.MIN_PRECISION)
    return t


def evaluate(model: str | None, rule: str, any_score: bool = False) -> dict:
    """model None = the projected ground-truth control."""
    doors = gt_doors()
    rows = []
    visible = visible_whole = 0
    if model is not None:
        t = config.MIN_SCORE if any_score else door_threshold(model)
        preds = load_preds(model, "electro")["images"]
        label = "window" if model == "vision_rects" else "door"
    for pid, photo in photos().items():
        views = {k: projected_box(photo, d) for k, d in doors.items()}
        views = {k: v for k, v in views.items() if v is not None}
        visible += len(views)
        visible_whole += sum(all(v[1].values()) for v in views.values())
        if model is None:
            matches = [(k, views[k][0], 1.0) for k in views]
        else:
            dets = sorted((x for x in preds[pid]["dets"] if x["label"] == label and x["score"] >= t), key=lambda x: -x["score"])
            free = set(views)
            matches = []
            for det in dets:
                if not free:
                    break
                keys = sorted(free)
                ious = _iou(np.array([det["box"]]), np.array([views[k][0] for k in keys]))[0]
                j = int(ious.argmax())
                if ious[j] >= 0.5:
                    matches.append((keys[j], det["box"], det["score"]))
                    free.discard(keys[j])
        for k, box, score in matches:
            lifted = lift(photo, box, doors[k], rule)
            inside = views[k][1]
            for e in EDGES:
                if inside[e]:
                    rows.append({"photo": pid, "door": k, "edge": e, "error_ft": (lifted[e] - doors[k]["edges_m"][e]) * FT,
                                 "eye_only": not doors[k]["snapped"][e], "whole": all(inside.values())})
    name = REF if model is None else (f"{model} (any score)" if any_score else model)
    return {"model": name, "rule": rule, "rows": rows, "visible": visible,
            "visible_whole": visible_whole,
            "matched": len({(r["photo"], r["door"]) for r in rows if r["whole"]}),
            "matched_cut": len({(r["photo"], r["door"]) for r in rows if not r["whole"]}),
            "threshold": None if model is None else t}


def summarize(r: dict) -> dict:
    whole = [x for x in r["rows"] if x["whole"]]
    cut = np.array([abs(x["error_ft"]) for x in r["rows"] if not x["whole"]])
    err = np.array([abs(x["error_ft"]) for x in whole])
    by_edge = {e: np.array([abs(x["error_ft"]) for x in whole if x["edge"] == e]) for e in EDGES}
    spreads = []
    for door in {x["door"] for x in whole}:
        for e in EDGES:
            v = [x["error_ft"] for x in whole if x["door"] == door and x["edge"] == e]
            if len(v) >= 2:
                spreads.append(max(v) - min(v))
    pct = lambda a, q: float(np.percentile(a, q)) if len(a) else float("nan")  # noqa: E731
    return {
        "n": len(err),
        "p50": pct(err, 50),
        "p90": pct(err, 90),
        "max": float(err.max()) if len(err) else float("nan"),
        "edge_p90": {e: pct(a, 90) for e, a in by_edge.items()},
        "edge_n": {e: len(a) for e, a in by_edge.items()},
        "spread_n": len(spreads),
        "spread_median": pct(np.array(spreads), 50),
        "spread_max": float(max(spreads)) if spreads else float("nan"),
        "cut_n": len(cut),
        "cut_p90": pct(cut, 90),
    }


def f(x: float) -> str:
    return "n/a" if np.isnan(x) else f"{x:.2f}"


def write(results: list[dict]) -> None:
    doors = gt_doors()
    L = [
        "# 3D extent: detected door edges lifted onto the wall",
        "",
        f"Generated {datetime.date.today()} by `uv run python -m autodetect.extent` (ground truth first:",
        "`uv run python -m autodetect.extent_gt save`). Data: the ETH3D electro packet, 8 DSLR photos",
        "with depth rendered from the laser scan, standing in for LiDAR. Door centres are 3.3 to 12.7 m",
        "from the camera (median 7.6 m) and seen 5 to 43 degrees off the wall's normal (median 16).",
        "",
        "Ground truth is each door's edges measured once in the laser scan, independent of any photo or",
        "detector (method in `autodetect/extent_gt.py`). Four doors: two gray metal doors in recesses and",
        "two glass double doors. Heights are above the ground at the meter; the doors' thresholds sit",
        "0 to 0.12 m above it.",
        "",
        "| Door | Width (ft) | Height (ft) | Edges read by eye only |",
        "|---|---|---|---|",
    ]
    for k, d in doors.items():
        e = d["edges_m"]
        eye = [x for x in EDGES if not d["snapped"][x]] or ["none"]
        L.append(f"| {k} | {(e['right'] - e['left']) * FT:.2f} | {(e['top'] - e['bottom']) * FT:.2f} | {', '.join(eye)} |")
    L += [
        "",
        f"Pass: p90 absolute edge error at most {config.EXTENT_P90_FT} ft over all scored edges. Each detector",
        "uses its door operating threshold from the OI tune set (Vision rectangles: its only threshold).",
        "",
        "Primary: doors wholly inside the photo. The last two columns are the doors the photo cuts off,",
        "for their edges that are in view (not part of the pass).",
        "",
        "| Boxes from | Lifting | Threshold | Whole door views matched / in view | Edges scored | p50 ft | p90 ft | max ft | Pass | Cut-off views matched | Cut-off edges p90 ft |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in results:
        s = r["summary"]
        thr = "n/a" if r["threshold"] is None else f"{r['threshold']:.3f}"
        diagnostic = r["model"] == REF or r["model"].endswith("(any score)")
        passes = "n/a" if diagnostic else ("yes" if s["p90"] <= config.EXTENT_P90_FT else "no")
        L.append(
            f"| {r['model']} | {r['rule']} | {thr} | {r['matched']} / {r['visible_whole']} | {s['n']} | {f(s['p50'])} | "
            f"{f(s['p90'])} | {f(s['max'])} | {passes} | {r['matched_cut']} / {r['visible'] - r['visible_whole']} | "
            f"{f(s['cut_p90'])} ({s['cut_n']}) |"
        )
    L += [
        "",
        "## By edge (p90 absolute error, ft; count in brackets)",
        "",
        "| Boxes from | Lifting | Left | Right | Bottom | Top |",
        "|---|---|---|---|---|---|",
    ]
    for r in results:
        s = r["summary"]
        L.append("| " + r["model"] + " | " + r["rule"] + " | " + " | ".join(f"{f(s['edge_p90'][e])} ({s['edge_n'][e]})" for e in EDGES) + " |")
    L += [
        "",
        "## Cross-view spread",
        "",
        "For each door edge seen in two or more photos: the largest minus the smallest lifted position.",
        "",
        "| Boxes from | Lifting | Door edges with 2+ views | Median spread ft | Max spread ft |",
        "|---|---|---|---|---|",
    ]
    for r in results:
        s = r["summary"]
        L.append(f"| {r['model']} | {r['rule']} | {s['spread_n']} | {f(s['spread_median'])} | {f(s['spread_max'])} |")
    L += [
        "",
        "## Every scored edge",
        "",
        "| Boxes from | Lifting | Photo | Door | Door in view | Edge | Error ft (lifted minus truth) |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in results:
        for x in r["rows"]:
            L.append(f"| {r['model']} | {r['rule']} | {x['photo']} | {x['door']} | {'whole' if x['whole'] else 'cut off'} | {x['edge']}{' (eye-only truth)' if x['eye_only'] else ''} | {x['error_ft']:+.2f} |")
    L += [
        "",
        "Limits: four doors on one building, seen by a DSLR from two to four times the app's 1 to 3 m, with",
        "laser depth that is denser and cleaner than an iPhone's LiDAR and absent on phones without it.",
        "No windows: the electro windows are curtain-wall glazing, not house windows.",
    ]
    (RESULTS / "extent.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    models = sys.argv[1:] or sorted(p.parent.name for p in (DATA / "preds").glob("*/electro.json"))
    results = []
    for m in [None, *models]:
        if m is not None and not pred_path(m, "electro").exists():
            raise FileNotFoundError(f"no electro predictions for {m}")
        for any_score, rule in [(a, rule) for a in ((False,) if m is None else (False, True)) for rule in RULES]:
            r = evaluate(m, rule, any_score)
            r["summary"] = summarize(r)
            results.append(r)
            s = r["summary"]
            print(f"{r['model']:24s} {rule:13s} whole {r['matched']}/{r['visible_whole']} edges {s['n']} p50 {f(s['p50'])} p90 {f(s['p90'])} ft; cut p90 {f(s['cut_p90'])} ({s['cut_n']})", file=sys.stderr)
    write(results)
