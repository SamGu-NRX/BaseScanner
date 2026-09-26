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
from evals.geometry import quat_wxyz_to_matrix
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


def heading(v: np.ndarray) -> np.ndarray:
    """Heading of y-up vectors (N, 3): the angle of their (x, z) part."""
    return np.arctan2(v[:, 0], v[:, 2])


def turn(v: np.ndarray, delta: np.ndarray) -> np.ndarray:
    """Turn y-up vectors about y so each heading grows by delta (radians)."""
    c, s = np.cos(delta), np.sin(delta)
    return np.c_[v[:, 0] * c + v[:, 2] * s, v[:, 1], v[:, 2] * c - v[:, 0] * s]


def circular_std_deg(a: np.ndarray) -> float:
    return float(np.degrees(np.sqrt(-2 * np.log(abs(np.mean(np.exp(1j * a)))))))


def align_headings(
    ark_p: np.ndarray, ark_q: np.ndarray, truth_p: np.ndarray, truth_fwd: np.ndarray
) -> tuple[np.ndarray, np.ndarray, float]:
    """ARKit positions in a frame with the truth's handedness and vertical sign, the per-image
    heading offset (truth minus ARKit, radians) and how steady it is (circular std, degrees).

    ARKit's poses are in Unity's left-handed axes (camera looking along +z) and the truth's level
    frame has an arbitrary vertical sign, so the z flip that makes the heading offset steadiest is
    taken; a correct pairing holds it within a degree over a whole walk.
    """
    fwd = quat_wxyz_to_matrix(ark_q)[:, :, 2]
    best = None
    for flip in (1.0, -1.0):
        f = fwd * np.array([1.0, 1.0, flip])
        delta = heading(truth_fwd) - heading(f)
        spread = circular_std_deg(delta)
        if best is None or spread < best[2]:
            best = (flip, delta, spread)
    flip, delta, spread = best
    p = ark_p * np.array([1.0, 1.0, flip])
    if (p[:, 1] - p[:, 1].mean()) @ (truth_p[:, 1] - truth_p[:, 1].mean()) < 0:
        p = p * np.array([1.0, -1.0, 1.0])
    return p, delta, spread


def walk_errors(ark: np.ndarray, truth: np.ndarray, delta: np.ndarray) -> dict:
    """Per distance, windows from every image: ARKit's and the truth's straight-line displacement
    (m), and the two displacements with ARKit's turned by the heading offset at the window's
    start, for position error."""
    out = {}
    for ft in DISTANCES_FT:
        i, j = window_pairs(truth, ft * FEET, 1)
        da = at(ark, j) - ark[i]
        dt = at(truth, j) - truth[i]
        out[ft] = {
            "ark": np.linalg.norm(da, axis=1),
            "truth": np.linalg.norm(dt, axis=1),
            "ark_turned": turn(da, delta[i]),
            "truth_vec": dt,
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
            # y up, as `horizontal_path_length` expects.
            t = np.array([truth[f"{name}/{k}"][:3] for k in keys]) @ frame.T
            t = t[:, [0, 2, 1]]
            # The truth's camera looks along +z of its world-to-camera rotation (COLMAP).
            fwd = (
                np.array([quat_wxyz_to_matrix(truth[f"{name}/{k}"][3:])[2] for k in keys]) @ frame.T
            )
            ark, delta, spread = align_headings(
                np.array([ark_rows[k][:3] for k in keys]),
                np.array([ark_rows[k][3:] for k in keys]),
                t,
                fwd[:, [0, 2, 1]],
            )
            errs = walk_errors(ark, t, delta)
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
                    "heading_offset_spread_deg": round(spread, 2),
                    "gps_over_truth": gps,
                    "errors": errs,
                }
            )
        scenes[scene] = walks
    return scenes


def site_spread(
    scales: np.ndarray, draws: int = 10_000, seed: int = 0
) -> tuple[float, float, float]:
    """Walk-to-walk standard deviation of ARKit's scale within one site, and its 95% bootstrap
    interval over walks. Walks off by more than `OUTLIER` are left out: their reference is in doubt.
    """
    s = scales[np.abs(scales - 1) <= OUTLIER]
    if len(s) < 3:
        raise ValueError(f"{len(s)} trusted walks; need at least 3 for a spread")
    rng = np.random.default_rng(seed)
    boot = s[rng.integers(0, len(s), (draws, len(s)))].std(axis=1, ddof=1)
    lo, hi = np.percentile(boot, [2.5, 97.5])
    return float(s.std(ddof=1)), float(lo), float(hi)


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
        "## Walk-to-walk spread of ARKit's scale within a site",
        "",
        f"Standard deviation over each site's walks within {OUTLIER:.0%} of the reference, with a "
        "95% bootstrap interval over walks. A reference scaled to ARKit would carry one scale per "
        "site, which shifts every walk of that site alike, so this spread survives it: a single "
        "walk's scale error is at least this large, unless the reference's own scale varies walk "
        "to walk in step with ARKit's.",
        "",
        "| Site | Walks used | Spread (1 SD) | 95% interval |",
        "| --- | --- | --- | --- |",
    ]
    for scene, walks in scenes.items():
        s = np.array([w["scale"] for w in walks])
        sd, lo, hi = site_spread(s)
        used = int(np.sum(np.abs(s - 1) <= OUTLIER))
        lines.append(f"| {scene} | {used} | {100 * sd:.2f}% | {100 * lo:.2f}% to {100 * hi:.2f}% |")
    lines += [
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
    position = {}
    for ft in DISTANCES_FT:
        raw, beyond, kept = [], [], []
        pos, pos_beyond, pos_kept = [], [], []
        for w in all_walks:
            e = w["errors"][ft]
            raw.append(e["ark"] - e["truth"])
            beyond.append(e["ark"] / w["scale"] - e["truth"])
            pe = np.linalg.norm(e["ark_turned"] - e["truth_vec"], axis=1)
            pos.append(pe)
            pos_beyond.append(np.linalg.norm(e["ark_turned"] / w["scale"] - e["truth_vec"], axis=1))
            if abs(w["scale"] - 1) <= OUTLIER:
                kept.append(e["ark"] - e["truth"])
                pos_kept.append(pe)
        lines.append(
            f"| {ft} ft | {_abs(np.concatenate(raw))} | {_abs(np.concatenate(beyond))} | "
            f"{_abs(np.concatenate(kept))} |"
        )
        position[ft] = (pos, pos_beyond, pos_kept)
    spreads = np.array([w["heading_offset_spread_deg"] for w in all_walks])
    lines += [
        "",
        "## Position error after walking, pooled over all walks",
        "",
        "|ARKit - truth| of the whole displacement, inches, median / p90, ARKit's displacement "
        "turned by the heading offset at the window's start (so sideways drift counts), as in "
        "section 1. The heading offset between ARKit and the truth holds steady to "
        f"{np.median(spreads):.1f} degrees (median walk; worst {spreads.max():.1f}). 'Scale "
        "removed' divides each walk's own scale out first. Columns as above.",
        "",
        "| Walked | As tracked | Scale removed | As tracked, without those walks | 0.16 ft/ft allowance |",
        "| --- | --- | --- | --- | --- |",
    ]
    for ft, (pos, pos_beyond, pos_kept) in position.items():
        lines.append(
            f"| {ft} ft | {_abs(np.concatenate(pos))} | {_abs(np.concatenate(pos_beyond))} | "
            f"{_abs(np.concatenate(pos_kept))} | {0.16 * ft * 12:.1f} |"
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
