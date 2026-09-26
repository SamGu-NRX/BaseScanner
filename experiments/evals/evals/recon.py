"""Score reconstructions of ETH3D's facade and electro scenes against their laser scans.

    uv run python -m evals.recon prepare            # images at eval size, visibility, view subsets
    uv run python -m evals.recon score              # every method with predictions on disk

`prepare` writes, under ~/house-scanning-data/evals/eth3d/<scene>/:
- `images_1024/<view>.jpg`: the undistorted images at 1024 px wide, the input to every model;
- `model_inputs/images.txt` and `intrinsics.json`: the list and the matching [fx, fy, cx, cy]
  (OpenCV, pixels of the 1024-wide image), the arguments the model runners take;
- `visibility_1024/<view>.npz`: which evaluation points each view sees (`evals.eth3d`);
- `subsets.json`: the multi-view groups: 8 seed views spread through the capture, each with its
  1, 3 and 7 nearest cameras that look the same way (centre distance, viewing directions within
  60 degrees), giving groups of 1, 2, 4 and 8 views.

Methods scored (each reads model outputs from ~/house-scanning-data/evals/predictions/):
- `single/<model>`: each image alone; its points in its own camera frame. Every view is used.
- `fused/<model>`: per-frame depth placed with the ground-truth camera poses (standing in for AR
  poses), each scan point averaged over the views of the group that see it. By group size.
- `mapanything`: one MapAnything run per group, its points in its own shared frame, averaged the
  same way. By group size.
- `oracle`: depth rendered from the scan points themselves, fused like `fused`. Its error is the
  evaluation's own floor (visibility test, interpolation), not a result.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np

from evals.eth3d import (
    SCENES,
    View,
    excluded_pixels,
    occluder_points,
    read_views,
    resized_image,
    scan_points,
    visible_scan_points,
)
from evals.pairs import Points, evaluate_raw, pool
from evals.paths import ETH3D_DIR, EVALS_DIR

WIDTH = 1024
EVAL_POINTS = 1_500_000
GROUP_SIZES = (1, 2, 4, 8)
SEEDS_PER_SCENE = 8
PREDICTIONS = EVALS_DIR / "predictions"


def _height(view: View) -> int:
    return round(view.height * WIDTH / view.width)


def eval_candidates(scene: str) -> np.ndarray:
    """A fixed random subset of the scan points used for scoring (all points still block views)."""
    pts = scan_points(scene)
    rng = np.random.default_rng(12345)
    n = min(EVAL_POINTS, len(pts))
    return pts[np.sort(rng.choice(len(pts), size=n, replace=False))]


def view_groups(views: list[View]) -> dict[str, list[list[str]]]:
    """Seed views evenly spaced through the capture; each group is the seed plus its nearest
    cameras whose viewing direction is within 60 degrees of the seed's."""
    seeds = [views[i] for i in np.linspace(0, len(views) - 1, SEEDS_PER_SCENE).round().astype(int)]
    groups: dict[str, list[list[str]]] = {}
    for n in GROUP_SIZES:
        groups[str(n)] = []
        for seed in seeds:
            similar = [v for v in views if v.name != seed.name and v.forward @ seed.forward > 0.5]
            similar.sort(key=lambda v: np.linalg.norm(v.center - seed.center))
            members = [seed.name] + [v.name for v in similar[: n - 1]]
            if len(members) == n:
                groups[str(n)].append(members)
    return groups


def prepare(scene: str) -> None:
    scene_dir = ETH3D_DIR / scene
    views = read_views(scene_dir)
    cands = eval_candidates(scene)
    blockers = np.concatenate([scan_points(scene), occluder_points(scene)])
    vis_dir = scene_dir / f"visibility_{WIDTH}"
    vis_dir.mkdir(exist_ok=True)
    inputs = scene_dir / "model_inputs"
    inputs.mkdir(exist_ok=True)
    listing, intr = [], {}
    for v in views:
        _, w, h = resized_image(v, WIDTH)
        path = scene_dir / f"images_{WIDTH}" / f"{v.name}.jpg"
        listing.append(str(path))
        K = v.scaled_K(w, h)
        intr[str(path)] = [K[0, 0], K[1, 1], K[0, 2], K[1, 2]]
        out = vis_dir / f"{v.name}.npz"
        if not out.exists():
            vis = visible_scan_points(blockers, cands, v, w, h, excluded_pixels(v, w, h))
            np.savez_compressed(out, index=vis.index, uv=vis.uv.astype(np.float32))
    (inputs / "images.txt").write_text("\n".join(listing) + "\n")
    (inputs / "intrinsics.json").write_text(json.dumps(intr, indent=1))
    (scene_dir / "subsets.json").write_text(json.dumps(view_groups(views), indent=1))
    print(f"{scene}: {len(views)} views prepared, {len(cands)} evaluation points")


def _sample_depth(depth: np.ndarray, uv: np.ndarray) -> np.ndarray:
    """Bilinear depth at float pixel positions (OpenCV integer-centred); NaN where any of the four
    neighbours is invalid or outside the image."""
    d = np.where(np.isfinite(depth) & (depth > 0), depth, np.nan).astype(np.float64)
    h, w = d.shape
    x, y = uv[:, 0], uv[:, 1]
    x0, y0 = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    fx, fy = x - x0, y - y0
    out = np.full(len(uv), np.nan)
    ok = (x0 >= 0) & (y0 >= 0) & (x0 + 1 < w) & (y0 + 1 < h)
    x0, y0, fx, fy = x0[ok], y0[ok], fx[ok], fy[ok]
    out[ok] = (
        d[y0, x0] * (1 - fx) * (1 - fy)
        + d[y0, x0 + 1] * fx * (1 - fy)
        + d[y0 + 1, x0] * (1 - fx) * fy
        + d[y0 + 1, x0 + 1] * fx * fy
    )
    return out


def _camera_points(depth: np.ndarray, K: np.ndarray, uv: np.ndarray) -> np.ndarray:
    z = _sample_depth(depth, uv)
    x = (uv[:, 0] - K[0, 2]) / K[0, 0] * z
    y = (uv[:, 1] - K[1, 2]) / K[1, 1] * z
    return np.c_[x, y, z]


def _K(intr) -> np.ndarray:
    fx, fy, cx, cy = map(float, intr)
    return np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1.0]])


class Scene:
    def __init__(self, name: str):
        self.name = name
        self.dir = ETH3D_DIR / name
        self.views = {v.name: v for v in read_views(self.dir)}
        self.cands = eval_candidates(name)
        self.groups = json.loads((self.dir / "subsets.json").read_text())
        self._vis: dict[str, tuple[np.ndarray, np.ndarray]] = {}
        self._oracle: dict[str, tuple[np.ndarray, np.ndarray]] = {}

    def visible(self, view: str) -> tuple[np.ndarray, np.ndarray]:
        if view not in self._vis:
            z = np.load(self.dir / f"visibility_{WIDTH}" / f"{view}.npz")
            self._vis[view] = (z["index"], z["uv"].astype(np.float64))
        return self._vis[view]

    def oracle_depth(self, view: str) -> tuple[np.ndarray, np.ndarray]:
        """Depth map splatted from every scan point with the same z-buffer as the visibility test,
        holes closed by a 5x5 minimum filter."""
        if view in self._oracle:
            return self._oracle[view]
        v = self.views[view]
        h = _height(v)
        K = v.scaled_K(WIDTH, h)
        pts = scan_points(self.name)
        Xc = pts @ v.R_wc.T + v.t_wc
        z = Xc[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = np.round(K[0, 0] * Xc[:, 0] / z + K[0, 2]).astype(np.int64)
            w = np.round(K[1, 1] * Xc[:, 1] / z + K[1, 2]).astype(np.int64)
        ok = (z > 0.1) & (u >= 0) & (u < WIDTH) & (w >= 0) & (w < h)
        buf = np.full((h, WIDTH), 1e6, np.float32)
        np.minimum.at(buf, (w[ok], u[ok]), z[ok].astype(np.float32))
        buf = cv2.erode(buf, np.ones((5, 5), np.uint8))
        buf[buf >= 1e6] = np.nan
        self._oracle[view] = (buf, K)
        return buf, K


def _fused_points(
    scene: Scene, members: list[str], per_view, max_range: float | None = None
) -> Points | None:
    """Average each evaluation point over the views of a group that see it.

    per_view(view) -> (depth map, K used for back-projection, 4x4 cam-to-world or None). With None
    the ground-truth pose places the points and `c` is the camera centre; with a model's own pose
    the points stay in the model's frame and `c` is zero. With `max_range`, only points within
    that distance (meters) of the nearest camera of the group are kept.
    """
    idx_all, c_all, r_all = [], [], []
    for name in members:
        index, uv = scene.visible(name)
        if len(index) == 0:
            continue
        depth, K, T = per_view(name)
        pc = _camera_points(depth, K, uv)
        good = np.isfinite(pc).all(axis=1)
        if T is None:
            v = scene.views[name]
            r = pc[good] @ v.R_wc  # camera to world rotation is R_wc^T: row-vector form
            c = np.broadcast_to(v.center, r.shape)
        else:
            r = pc[good] @ T[:3, :3].T + T[:3, 3]
            c = np.zeros_like(r)
        idx_all.append(index[good])
        c_all.append(c)
        r_all.append(r)
    if not idx_all:
        return None
    idx = np.concatenate(idx_all)
    c = np.concatenate(c_all)
    r = np.concatenate(r_all)
    uniq, inv, counts = np.unique(idx, return_inverse=True, return_counts=True)
    cs = np.zeros((len(uniq), 3))
    rs = np.zeros((len(uniq), 3))
    np.add.at(cs, inv, c)
    np.add.at(rs, inv, r)
    pts = Points(
        gt=scene.cands[uniq].astype(np.float64), c=cs / counts[:, None], r=rs / counts[:, None]
    )
    if max_range is None:
        return pts
    centres = np.array([scene.views[m].center for m in members])
    near = np.min(np.linalg.norm(pts.gt[:, None, :] - centres[None], axis=2), axis=1) <= max_range
    if near.sum() < 2:
        return None
    return Points(gt=pts.gt[near], c=pts.c[near], r=pts.r[near])


def _load_pred(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray | None]:
    z = np.load(path)
    depth = np.where(z["valid"], z["depth"], np.nan) if "valid" in z else z["depth"]
    T = z.get("cam_to_world", None)
    return depth, _K(z["intrinsics"]), T


RANGES = {"all points": None, "within 6 m of a camera": 6.0}
MIN_PAIRS = 300  # fewer pairs than this in a cell are reported as n/a


def score_scene(scene: Scene, rng: np.random.Generator) -> dict:
    """{range: {method: {views: pooled summary}}} for every method with predictions on disk."""
    pred_root = PREDICTIONS / scene.name
    per_frame_models = (
        sorted(p.name for p in pred_root.glob("*") if p.is_dir() and p.name != "mapanything")
        if pred_root.exists()
        else []
    )

    def oracle(name):
        d, K = scene.oracle_depth(name)
        return d, K, None

    methods = {"oracle": oracle}
    for model in per_frame_models:

        def per_frame(name, model=model):
            d, K, _ = _load_pred(pred_root / model / f"{name}.npz")
            return d, K, None

        methods[f"fused/{model}"] = per_frame

    ma_root = pred_root / "mapanything"
    out: dict = {}
    for range_name, max_range in RANGES.items():
        results: dict = {}
        for method, fn in methods.items():
            results[method] = {}
            for n, groups in scene.groups.items():
                raws = []
                for members in groups:
                    pts = _fused_points(scene, members, fn, max_range)
                    if pts is not None:
                        raws.append(evaluate_raw(pts, rng))
                results[method][n] = pool(raws)
            if method.startswith("fused/"):
                raws = []
                for name in scene.views:
                    pts = _fused_points(scene, [name], fn, max_range)
                    if pts is not None:
                        raws.append(evaluate_raw(pts, rng, pairs_per_bin=1500))
                results["single/" + method.split("/", 1)[1]] = {"1": pool(raws)}
        if ma_root.exists():
            results["mapanything"] = {}
            for n, groups in scene.groups.items():
                raws = []
                for members in groups:
                    run = ma_root / f"n{n}-{members[0]}"
                    if not (run / "run.json").exists():
                        continue

                    def ma(name, run=run):
                        return _load_pred(run / f"{name}.npz")

                    pts = _fused_points(scene, members, ma, max_range)
                    if pts is not None:
                        raws.append(evaluate_raw(pts, rng))
                if raws:
                    results["mapanything"][n] = pool(raws)
        out[range_name] = results
    return out


LABELS = {
    "oracle": "scan rendered as depth (evaluation floor)",
    "single/moge2": "MoGe-2, one image",
    "single/da3metric": "Depth Anything 3 metric, one image",
    "fused/moge2": "MoGe-2 per frame + true poses",
    "fused/da3metric": "Depth Anything 3 metric per frame + true poses",
    "mapanything": "MapAnything, images + intrinsics",
}


def _cell(x: dict) -> str:
    if x.get("pairs", 0) < MIN_PAIRS:
        return "n/a"
    return f"{x['median_in']:.1f} / {x['p90_in']:.1f}"


def markdown(results: dict) -> str:
    lines = [
        "# ETH3D reconstruction accuracy (generated by `uv run python -m evals.recon score`)",
        "",
    ]
    lines.append(
        "|error in the distance between two wall points|, inches, median / p90, against the laser "
        "scan. Scale error is the median of predicted / true length, minus 1."
    )
    for scene, ranges in results.items():
        for range_name, methods in ranges.items():
            lines += ["", f"## {scene}, {range_name}", ""]
            for source, title in (
                ("none", "Scale from the model (nothing measured by hand)"),
                ("one_known_distance", "Scale from one taped distance (1 to 3 m)"),
            ):
                lines += [f"### {title}", ""]
                lines.append("| Method | Views | 1-3 m | 3-10 m | Scale error, 3-10 m pairs |")
                lines.append("| --- | --- | --- | --- | --- |")
                order = [m for m in LABELS if m in methods]
                order += [m for m in methods if m not in LABELS]
                for m in order:
                    for n, res in methods[m].items():
                        b1, b2 = res[source]["1-3m"], res[source]["3-10m"]
                        scale = (
                            b2.get("scale_error_pct") if b2.get("pairs", 0) >= MIN_PAIRS else None
                        )
                        scale_txt = "n/a" if scale is None else f"{scale:+.1f}%"
                        lines.append(
                            f"| {LABELS.get(m, m)} | {n} | {_cell(b1)} | {_cell(b2)} | {scale_txt} |"
                        )
                lines.append("")
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("step", choices=["prepare", "score"])
    ap.add_argument("--scenes", nargs="+", default=list(SCENES))
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "results")
    args = ap.parse_args()
    if args.step == "prepare":
        for s in args.scenes:
            prepare(s)
        return
    rng = np.random.default_rng(7)
    results = {s: score_scene(Scene(s), rng) for s in args.scenes}
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "eth3d_recon.json").write_text(json.dumps(results, indent=1))
    md = markdown(results)
    (args.out / "eth3d_recon.md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
