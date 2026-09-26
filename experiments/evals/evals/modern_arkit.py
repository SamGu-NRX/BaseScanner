"""A current iPhone's ARKit scale, measured on MARViN (iPhone 14 Pro Max, ARKit 6, outdoor walks).

    uv run python -m evals.modern_arkit        # fetch the pose files, write results/modern_arkit.md

MARViN (Liu et al., IEEE VRW 2024, github.com/XRIM-Lab/MarViN) records ARKit's pose for every image
(`<scene>/<seq>/ARkitPose.txt`, Unity axes) and a COLMAP reconstruction of each scene as ground
truth (`<scene>/train.txt` and `test.txt`: image, camera centre x y z, then a quaternion). Distances
between positions do not depend on axis conventions, so the comparison uses displacements only.

From every image, the walk continues until the ground truth has covered 3, 10, 20 or 30 ft (paths
are measured in the ground truth's horizontal plane, its least-variance axis being vertical). Per
window: ARKit's straight-line displacement minus the truth's, and their ratio. A walk's scale is the
median ratio over windows of 10 ft or more; "beyond scale" is the distance error after dividing it
out.

The limit: COLMAP from one moving camera has no scale of its own, and the dataset does not say how
its reconstructions were put into meters. The phone's GPS, the one independent reference shipped,
cannot pin that scale better than several percent over these 25 to 160 m walks (checked here). So
ARKit's scale is measured against the ground truth's scale, not against the tape.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import gdown
import numpy as np

from evals.drift import (
    DISTANCES_FT,
    FEET,
    INCH,
    at,
    gps_local_meters,
    horizontal_path_length,
    similarity_scale_2d,
    window_pairs,
)
from evals.paths import EVALS_DIR

MARVIN_DIR = EVALS_DIR / "marvin"
FOLDER = "https://drive.google.com/drive/folders/18vPfKB4jlDwtFzytMijYOpmeqU1A9-Ie"
# The outdoor scenes whose iPhone walks have ground truth (the paper's three outdoor scenes).
SCENES = ("atrium", "bar", "church")
SCALE_MIN_FT = 10.0
OUTLIER = (
    0.10  # a walk this far off the reference's scale is reported, but its reference is in doubt
)
RESULTS = Path(__file__).resolve().parents[1] / "results"


def fetch() -> dict[str, str]:
    """Download only the pose, GPS and ground-truth text files; return {path: sha256}."""
    files = gdown.download_folder(FOLDER, skip_download=True, quiet=True, remaining_ok=True)
    wanted = [
        f
        for f in files
        if f.path.split("/")[0] in SCENES
        and f.path.endswith(("ARkitPose.txt", "GPSData.txt", "train.txt", "test.txt"))
    ]
    hashes = {}
    for f in wanted:
        out = MARVIN_DIR / f.path
        if not out.exists():
            out.parent.mkdir(parents=True, exist_ok=True)
            if gdown.download(id=f.id, output=str(out), quiet=True) is None:
                raise RuntimeError(f"Google Drive refused {f.path} ({f.id}); retry later")
        hashes[f.path] = hashlib.sha256(out.read_bytes()).hexdigest()
    return hashes


def read_table(path: Path, columns: int) -> dict[str, np.ndarray]:
    rows = {}
    for line in path.read_text().splitlines():
        t = line.split()
        if len(t) == columns:
            rows[t[0]] = np.array(t[1:], dtype=np.float64)
    return rows


def level_frame(points: np.ndarray) -> np.ndarray:
    """Rows: two horizontal axes and the vertical (least-variance) axis of a walked trajectory."""
    _, _, Vt = np.linalg.svd(points - points.mean(axis=0), full_matrices=False)
    return Vt


def walk_errors(ark: np.ndarray, truth: np.ndarray) -> dict:
    """Per distance: ARKit's and the truth's straight-line displacement (m), windows from every
    image."""
    out = {}
    for ft in DISTANCES_FT:
        i, j = window_pairs(truth, ft * FEET, 1)
        out[ft] = {
            "ark": np.linalg.norm(at(ark, j) - ark[i], axis=1),
            "truth": np.linalg.norm(at(truth, j) - truth[i], axis=1),
        }
    return out


def gps_scale(gps: dict, truth_by_image: dict, frame: np.ndarray) -> tuple[float, float] | None:
    """GPS over truth scale for one walk and GPS's median fit residual (m)."""
    keys = [k for k in gps if k in truth_by_image and gps[k][0] != 0]
    if len(keys) < 30:
        return None
    en = gps_local_meters(np.array([gps[k][0] for k in keys]), np.array([gps[k][1] for k in keys]))
    level = np.array([truth_by_image[k] for k in keys]) @ frame[:2].T
    s, res = similarity_scale_2d(level, en)
    return s, float(np.median(res))


def evaluate() -> dict:
    scenes = {}
    for scene in SCENES:
        root = MARVIN_DIR / scene
        truth = {**read_table(root / "train.txt", 8), **read_table(root / "test.txt", 8)}
        frame = level_frame(np.array([v[:3] for v in truth.values()]))
        walks = []
        for seq in sorted(root.glob("seq*/ARkitPose.txt"), key=lambda p: int(p.parent.name[3:])):
            name = seq.parent.name
            ark_rows = read_table(seq, 8)
            keys = sorted(k for k in ark_rows if f"{name}/{k}" in truth)
            if len(keys) < 30:
                continue
            ark = np.array([ark_rows[k][:3] for k in keys])
            # y up, as `horizontal_path_length` expects.
            t = np.array([truth[f"{name}/{k}"][:3] for k in keys]) @ frame.T
            t = t[:, [0, 2, 1]]
            errs = walk_errors(ark, t)
            long = np.concatenate(
                [errs[ft]["ark"] / errs[ft]["truth"] for ft in DISTANCES_FT if ft >= SCALE_MIN_FT]
            )
            scale = float(np.median(long)) if len(long) else float("nan")
            gps_path = root / name / "GPSData.txt"
            gps = None
            if gps_path.exists():
                by_image = {k: truth[f"{name}/{k}"][:3] for k in keys}
                gps = gps_scale(read_table(gps_path, 4), by_image, frame)
            walks.append(
                {
                    "walk": name,
                    "images": len(keys),
                    "walked_m": float(horizontal_path_length(t)[-1]),
                    "scale": scale,
                    "gps_over_truth": gps,
                    "errors": errs,
                }
            )
        scenes[scene] = walks
    return scenes


def _abs(x_m: np.ndarray) -> str:
    a = np.abs(x_m) / INCH
    return f"{np.median(a):.1f} / {np.percentile(a, 90):.1f}"


def markdown(scenes: dict, hashes: dict[str, str]) -> str:
    lines = [
        "# A current iPhone's ARKit scale (generated by `uv run python -m evals.modern_arkit`)",
        "",
        "MARViN, iPhone 14 Pro Max, ARKit 6, outdoor walks, against the dataset's COLMAP ground "
        "truth. Scale: ARKit / truth over windows of 10 ft or more, per walk.",
        "",
        "| Scene | Walks | Walked per walk (m) | ARKit scale error, median walk | Walks' range |",
        "| --- | --- | --- | --- | --- |",
    ]
    for scene, walks in scenes.items():
        s = np.array([w["scale"] for w in walks])
        m = np.array([w["walked_m"] for w in walks])
        lines.append(
            f"| {scene} | {len(walks)} | {np.median(m):.0f} | {100 * (np.median(s) - 1):+.1f}% | "
            f"{100 * (s.min() - 1):+.1f}% to {100 * (s.max() - 1):+.1f}% |"
        )
    all_walks = [w for walks in scenes.values() for w in walks]
    s_all = np.array([w["scale"] for w in all_walks])
    lines += [
        f"| all | {len(all_walks)} | | {100 * (np.median(s_all) - 1):+.1f}% | "
        f"{100 * (s_all.min() - 1):+.1f}% to {100 * (s_all.max() - 1):+.1f}% |",
        "",
        f"Walks within 2% of the ground truth's scale: {int(np.sum(np.abs(s_all - 1) <= 0.02))} of "
        f"{len(all_walks)}.",
        "",
        "## Distance error after walking, pooled over all walks",
        "",
        "|ARKit - truth| of the straight-line displacement, inches, median / p90. 'Beyond scale' "
        "divides each walk's own scale out first. The last column leaves out walks whose scale is "
        f"off by more than {OUTLIER:.0%}: there ARKit and the reference disagree about whether the "
        "phone moved at all between images, so the reference itself is in doubt. The 3 ft row is "
        "below what this reference resolves: images are 0.2 to 1.4 m apart, and the reference "
        "jitters by up to 0.4 m on those walks.",
        "",
        "| Walked | As tracked | Beyond scale | As tracked, without those walks |",
        "| --- | --- | --- | --- |",
    ]
    for ft in DISTANCES_FT:
        raw, beyond, kept = [], [], []
        for w in all_walks:
            e = w["errors"][ft]
            raw.append(e["ark"] - e["truth"])
            beyond.append(e["ark"] / w["scale"] - e["truth"])
            if abs(w["scale"] - 1) <= OUTLIER:
                kept.append(e["ark"] - e["truth"])
        lines.append(
            f"| {ft} ft | {_abs(np.concatenate(raw))} | {_abs(np.concatenate(beyond))} | "
            f"{_abs(np.concatenate(kept))} |"
        )
    gps = [
        (w["gps_over_truth"][0], w["gps_over_truth"][1]) for w in all_walks if w["gps_over_truth"]
    ]
    g = np.array([x[0] for x in gps])
    tight = np.array([x[0] for x in gps if x[1] <= 1.5])
    lines += [
        "",
        "## Can GPS check the ground truth's scale?",
        "",
        f"GPS / truth over each walk: median {np.median(g):.3f}, range {g.min():.3f} to "
        f"{g.max():.3f} ({len(g)} walks). On the {len(tight)} walks where GPS fits within 1.5 m, "
        f"median {np.median(tight):.3f}, range {tight.min():.3f} to {tight.max():.3f}. GPS noise of "
        "1 to 9 m over 25 to 160 m walks cannot pin the scale to 2%.",
        "",
        "## Files (Google Drive folder " + FOLDER + ")",
        "",
        "| File | sha256 |",
        "| --- | --- |",
    ]
    lines += [f"| {p} | {h} |" for p, h in sorted(hashes.items())]
    return "\n".join(lines) + "\n"


def main() -> None:
    hashes = fetch()
    scenes = evaluate()
    summary = {
        scene: [{k: v for k, v in w.items() if k != "errors"} for w in walks]
        for scene, walks in scenes.items()
    }
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "modern_arkit.json").write_text(json.dumps(summary, indent=1))
    md = markdown(scenes, hashes)
    (RESULTS / "modern_arkit.md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
