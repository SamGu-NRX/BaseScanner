"""Smoke-test inputs from the ADVIO replay session, and a summary of model outputs on them.

    uv run --project models python -m models.smoke_advio prepare --ids k00020 k00021 k00022 k00023 k00024
    uv run --project models python -m models.smoke_advio summarize DIR [DIR ...]

`prepare` writes upright copies of the keyframes with matching intrinsics and camera poses. The
replay JPEGs are unrotated sensor images of a phone held upright, so the sky is on the left; depth
models are trained on upright photos. Rotating the image 90 degrees clockwise gives the upright
portrait view: continuous pixel (u, v) in the landscape image lands at (H - v, u), so
fx' = fy, fy' = fx, cx' = H - cy, cy' = cx (continuous), and the camera turns about its optical
axis. Session intrinsics are continuous pixels; the outputs are OpenCV (continuous - 0.5).

`summarize` prints, per image, the median depth of the bottom quarter of the upright image (the
road just ahead) and, for runs with `cam_to_world`, camera-centre distances against ARKit's.
"""

from __future__ import annotations

import argparse
import json
from itertools import pairwise
from pathlib import Path

import cv2
import numpy as np

from models.common import DATA_ROOT

SESSION = DATA_ROOT / "replays" / "advio-20-0040-0075"
SMOKE_ROOT = DATA_ROOT / "evals" / "model-smoke"
FLIP_YZ = np.diag([1.0, -1.0, -1.0])  # ARKit camera (+y up, looks along -z) <-> OpenCV camera
# Columns: upright-portrait OpenCV camera axes in the landscape OpenCV camera. Portrait right is
# landscape up (-y), portrait down is landscape right (+x), the optical axis is shared.
LANDSCAPE_FROM_PORTRAIT = np.array([[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
GROUND_ROWS = 0.25


def prepare(ids: list[str], out: Path) -> None:
    session = json.loads((SESSION / "session.json").read_text())
    by_id = {k["id"]: k for k in session["keyframes"]}
    missing = [i for i in ids if i not in by_id]
    if missing:
        raise ValueError(f"keyframes {missing} are not in {SESSION / 'session.json'}")
    img_dir = out / "images"
    img_dir.mkdir(parents=True, exist_ok=True)
    intrinsics, poses, arkit = {}, {}, {}
    lines = []
    for kid in ids:
        kf = by_id[kid]
        img = cv2.imread(str(SESSION / kf["img"]), cv2.IMREAD_COLOR)
        if img is None or img.shape[:2] != (kf["h"], kf["w"]):
            raise ValueError(f"{kid}: image missing or not {kf['w']}x{kf['h']}")
        upright = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
        path = img_dir / f"{kid}.png"
        cv2.imwrite(str(path), upright)
        lines.append(str(path))
        fx, fy, cx, cy = kf["intrinsics"]
        intrinsics[kid] = [fy, fx, kf["h"] - cy - 0.5, cx - 0.5]
        T = np.asarray(kf["pose"], dtype=np.float64).reshape(4, 4).T  # column-major
        cv = T.copy()
        cv[:3, :3] = T[:3, :3] @ FLIP_YZ @ LANDSCAPE_FROM_PORTRAIT
        poses[kid] = cv.tolist()
        arkit[kid] = T[:3, 3].tolist()
    (out / "images.txt").write_text("\n".join(lines) + "\n")
    (out / "intrinsics.json").write_text(json.dumps(intrinsics, indent=2) + "\n")
    (out / "poses.json").write_text(json.dumps(poses, indent=2) + "\n")
    (out / "arkit_positions.json").write_text(json.dumps(arkit, indent=2) + "\n")
    print(f"wrote {len(ids)} upright images, intrinsics.json and poses.json to {out}")


def summarize(run_dir: Path, inputs: Path) -> dict:
    run = json.loads((run_dir / "run.json").read_text())
    arkit = json.loads((inputs / "arkit_positions.json").read_text())
    rows, centres = [], {}
    for entry in run["images"]:
        z = np.load(run_dir / f"{entry['stem']}.npz")
        depth, valid = z["depth"], z["valid"]
        h = depth.shape[0]
        ground = valid[int(h * (1 - GROUND_ROWS)) :]
        gd = depth[int(h * (1 - GROUND_ROWS)) :][ground]
        rows.append(
            {
                "stem": entry["stem"],
                "ground_median_m": round(float(np.median(gd)), 2) if gd.size else None,
                "ground_valid_fraction": round(float(ground.mean()), 3),
                "all_median_m": entry["depth"].get("median_m"),
                "all_p5_p95_m": [entry["depth"].get("p5_m"), entry["depth"].get("p95_m")],
                "valid_fraction": entry["depth"]["valid_fraction"],
                "seconds": entry["seconds"],
                "fx": round(float(z["intrinsics"][0]), 1),
            }
        )
        if "cam_to_world" in z:
            centres[entry["stem"]] = z["cam_to_world"][:3, 3]
    out = {
        "model": run["model"],
        "device": run["device"],
        "intrinsics_mode": run["intrinsics_mode"],
        "poses_used": run["poses_used"],
        "images": rows,
    }
    if centres:
        stems = [r["stem"] for r in rows]
        pred = np.array([centres[s] for s in stems])
        ref = np.array([arkit[s] for s in stems])
        consecutive = [
            {
                "pair": f"{a}-{b}",
                "predicted_m": round(float(np.linalg.norm(pred[j] - pred[i])), 3),
                "arkit_m": round(float(np.linalg.norm(ref[j] - ref[i])), 3),
            }
            for (i, a), (j, b) in pairwise(enumerate(stems))
        ]
        span_pred = float(np.linalg.norm(pred[-1] - pred[0]))
        span_ref = float(np.linalg.norm(ref[-1] - ref[0]))
        out["baseline"] = {
            "consecutive": consecutive,
            "first_to_last_predicted_m": round(span_pred, 3),
            "first_to_last_arkit_m": round(span_ref, 3),
            "ratio_predicted_over_arkit": round(span_pred / span_ref, 3),
        }
    if centres and run["poses_used"]:
        given = json.loads((inputs / "poses.json").read_text())
        agreement = []
        for entry in run["images"]:
            T = np.asarray(entry["cam_to_world"])
            P = np.asarray(given[entry["stem"]])
            cos = (np.trace(T[:3, :3].T @ P[:3, :3]) - 1) / 2
            agreement.append(
                {
                    "stem": entry["stem"],
                    "position_error_m": round(float(np.linalg.norm(T[:3, 3] - P[:3, 3])), 4),
                    "rotation_error_deg": round(
                        float(np.degrees(np.arccos(np.clip(cos, -1, 1)))), 3
                    ),
                }
            )
        out["output_vs_input_poses"] = agreement
    (run_dir / "smoke_summary.json").write_text(json.dumps(out, indent=2) + "\n")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--ids", nargs="+", required=True)
    p.add_argument("--out", type=Path, default=SMOKE_ROOT / "advio-input")
    s = sub.add_parser("summarize")
    s.add_argument("runs", nargs="+", type=Path)
    s.add_argument("--inputs", type=Path, default=SMOKE_ROOT / "advio-input")
    args = ap.parse_args()
    if args.cmd == "prepare":
        prepare(args.ids, args.out)
    else:
        for run_dir in args.runs:
            print(json.dumps(summarize(run_dir, args.inputs), indent=2))


if __name__ == "__main__":
    main()
