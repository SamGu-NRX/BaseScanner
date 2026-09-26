"""Run MapAnything once per view group of an ETH3D scene, loading the model once.

    cd experiments/evals
    uv run --project models python -m models.run_groups --scene-dir ~/house-scanning-data/evals/eth3d/facade \\
        --out ~/house-scanning-data/evals/predictions/facade/mapanything

Groups come from the scene's `subsets.json` (written by `python -m evals.recon prepare`). Each group
of n views seeded by view S is written to `<out>/n<n>-<S>/<stem>.npz`, the layout `evals.recon`
reads, plus a `run.json` with timing and the model's metric scale factor. Known intrinsics are
passed (a phone knows its own); camera poses are not, so every group's frame and scale are the
model's own.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from models.common import RunInputs, read_intrinsics, set_cache_dirs, write_npz
from models.map_anything import load, run
from models.run import pick_device


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--scene-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"])
    args = ap.parse_args()
    set_cache_dirs()
    import torch

    groups = json.loads((args.scene_dir / "subsets.json").read_text())
    images_dir = args.scene_dir / "images_1024"
    intr_file = args.scene_dir / "model_inputs" / "intrinsics.json"
    device = pick_device(args.device)
    t0 = time.perf_counter()
    model = load(device)
    print(f"loaded in {time.perf_counter() - t0:.1f} s on {device}", file=sys.stderr)
    for n, members_list in groups.items():
        for members in members_list:
            out = args.out / f"n{n}-{members[0]}"
            if (out / "run.json").exists():
                continue
            images = [images_dir / f"{m}.jpg" for m in members]
            inputs = RunInputs(
                images=images,
                intrinsics=read_intrinsics(intr_file, images),
                intrinsics_mode="known",
                poses=None,
                max_side=None,
                device=device,
                fp32=False,
            )
            results = run(model, inputs)
            out.mkdir(parents=True, exist_ok=True)
            for res in results:
                write_npz(
                    out,
                    res.path.stem,
                    res.depth,
                    res.valid,
                    res.intrinsics,
                    res.cam_to_world,
                    res.arrays,
                )
            summary = {
                "members": members,
                "seconds_per_view": round(results[0].seconds, 3),
                "network_wh": list(results[0].network_wh),
                "metric_scaling_factor": [r.extra["metric_scaling_factor"] for r in results],
            }
            (out / "run.json").write_text(json.dumps(summary, indent=1) + "\n")
            print(f"n={n} {members[0]}: {results[0].seconds:.2f} s/view", file=sys.stderr)
            if device == "mps":
                torch.mps.empty_cache()


if __name__ == "__main__":
    main()
