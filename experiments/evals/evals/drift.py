"""How far ARKit's tracked position is off after walking 3, 10, 20 and 30 ft outdoors (ADVIO 20 to 23).

    uv run python -m evals.drift        # writes results/advio_drift.json and results/advio_drift.md

Method. Tracks are resampled at 10 Hz on their common interval, after ARKit initialises. From every
start time (every 0.5 s) the walk continues until the reference has covered d feet of horizontal
path. The main error is the distance error: ARKit's straight-line displacement minus the
reference's. It needs no heading alignment, so no orientation error can leak in, and it is what a
span measured by walking it (a 30 ft wall, a gap to a fence) would be off by. For the ground-truth
reference the full position error is also kept, with ARKit's displacement turned into the truth's
frame by the heading difference of the two orientations at the start.

References. The same rig carried the iPhone (ARKit, GPS), a Pixel running ARCore, and produced a
ground truth: an inertial track pinned to fix points marked on a map, so its scale is the map's.
Three references are scored:

- `truth`: the ground truth as published;
- `truth_gps`: the ground truth rescaled by the factor that best fits the phone's GPS track
  (`reference_scale_check`), because GPS and ARCore both say the map was mis-scaled in 20 and 21;
- `arcore`: the Pixel's ARCore track, an independent tracker with its own camera and IMU.

`three_cornered_hat` splits the spread of the pairwise differences into each tracker's own spread,
assuming their random errors are independent. That is how the report tells ARKit's error apart
from the reference's.

A sequence whose ARKit track moves faster than a person walks (over 4 m/s between 10 Hz samples)
is reported as a tracking failure, with the time it failed, instead of producing drift numbers.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

from evals.advio import PoseTrack, _read_pose_csv, load_sequence
from evals.paths import ADVIO_DIR

FEET = 0.3048
INCH = 0.0254
DISTANCES_FT = (3, 10, 20, 30)
SAMPLE_HZ = 10.0
START_EVERY_S = 0.5
MAX_WALK_SPEED = 4.0  # m/s; a walker never covers 0.4 m in 0.1 s
SEQUENCES = (20, 21, 22, 23)


def horizontal_path_length(p: np.ndarray) -> np.ndarray:
    """Cumulative distance travelled in the x-z plane (y is up), starting at 0."""
    steps = np.linalg.norm(np.diff(p[:, [0, 2]], axis=0), axis=1)
    return np.concatenate([[0.0], np.cumsum(steps)])


def yaw_between(R_from: np.ndarray, R_to: np.ndarray) -> np.ndarray:
    """Rotation about +y closest to turning orientation R_from into R_to (the heading difference)."""
    M = R_to @ R_from.T
    ang = np.arctan2(M[0, 2] - M[2, 0], M[0, 0] + M[2, 2])
    c, s = np.cos(ang), np.sin(ang)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def window_pairs(
    ref_p: np.ndarray, distance_m: float, start_step: int
) -> tuple[np.ndarray, np.ndarray]:
    """Start and end sample indices: each start, and the first sample at which the reference has
    walked `distance_m` of horizontal path since it. Windows that run off the end are dropped."""
    walked = horizontal_path_length(ref_p)
    i = np.arange(0, len(ref_p), start_step)
    j = np.searchsorted(walked, walked[i] + distance_m)
    keep = j < len(ref_p)
    return i[keep], j[keep]


def distance_errors(
    est_p: np.ndarray, ref_p: np.ndarray, i: np.ndarray, j: np.ndarray
) -> np.ndarray:
    """|est[j] - est[i]| - |ref[j] - ref[i]| for each window, meters (signed)."""
    return np.linalg.norm(est_p[j] - est_p[i], axis=1) - np.linalg.norm(ref_p[j] - ref_p[i], axis=1)


def position_errors(
    est_p: np.ndarray,
    ref_p: np.ndarray,
    est_R: np.ndarray,
    ref_R: np.ndarray,
    i: np.ndarray,
    j: np.ndarray,
) -> np.ndarray:
    """|Y (est[j] - est[i]) - (ref[j] - ref[i])|, with Y the heading difference at the start."""
    out = np.empty(len(i))
    for k, (a, b) in enumerate(zip(i, j, strict=True)):
        Y = yaw_between(est_R[a], ref_R[a])
        out[k] = np.linalg.norm(Y @ (est_p[b] - est_p[a]) - (ref_p[b] - ref_p[a]))
    return out


def robust_variance(x: np.ndarray) -> float:
    """Variance about the median from the median absolute deviation (1.4826 MAD, squared)."""
    x = np.asarray(x, dtype=float)
    return float((1.4826 * np.median(np.abs(x - np.median(x)))) ** 2)


def three_cornered_hat(var_ab: float, var_ac: float, var_bc: float) -> tuple[float, float, float]:
    """Each tracker's own variance from the variances of three pairwise differences, assuming
    independent errors: var_ab = a + b, var_ac = a + c, var_bc = b + c. A negative result means that
    tracker's error is below what the other two can resolve."""
    a = (var_ab + var_ac - var_bc) / 2
    b = var_ab - a
    c = var_ac - a
    return a, b, c


def similarity_scale_2d(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray]:
    """Scale of the best 2-D similarity (rotation, optional reflection, scale, shift) from src to dst.

    Reflection is allowed because a y-up world's x-z plane and (east, north) differ in handedness.
    Returns (scale, residuals in dst units).
    """
    mu_s, mu_d = src.mean(0), dst.mean(0)
    a, b = src - mu_s, dst - mu_d
    best: tuple[float, np.ndarray] | None = None
    for flip in (1.0, -1.0):
        af = a * np.array([1.0, flip])
        U, D, Vt = np.linalg.svd(b.T @ af)
        S = np.diag([1.0, np.sign(np.linalg.det(U @ Vt))])
        R = U @ S @ Vt
        s = float(np.trace(np.diag(D) @ S) / (af**2).sum())
        res = np.linalg.norm(b - s * af @ R.T, axis=1)
        if best is None or res.mean() < best[1].mean():
            best = (s, res)
    assert best is not None
    return best


def gps_local_meters(lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
    """(east, north) meters from the first sample, equirectangular (exact enough over 1 km)."""
    r = 6_371_000.0
    east = np.radians(lon - lon[0]) * r * np.cos(np.radians(lat[0]))
    north = np.radians(lat - lat[0]) * r
    return np.c_[east, north]


@dataclass
class ScaleCheck:
    gps_over_truth: float
    gps_interval_95: tuple[float, float]
    gps_fixes: int
    gps_median_accuracy_m: float
    arcore_over_truth: float
    arkit_over_truth: float


def _window_ratio(
    track: PoseTrack, truth: PoseTrack, times: np.ndarray, window_s: float = 5.0
) -> float:
    """Median |track displacement| / |truth displacement| over `window_s` windows in which the
    truth moved at least 3 m horizontally."""
    w = round(window_s * SAMPLE_HZ)
    pa, pg = track.interpolate_positions(times), truth.interpolate_positions(times)
    da = np.linalg.norm((pa[w:] - pa[:-w])[:, [0, 2]], axis=1)
    dg = np.linalg.norm((pg[w:] - pg[:-w])[:, [0, 2]], axis=1)
    moving = dg > 3.0
    return float(np.median(da[moving] / dg[moving]))


def reference_scale_check(
    root: Path,
    truth: PoseTrack,
    arkit: PoseTrack,
    arcore: PoseTrack,
    times: np.ndarray,
    seed: int = 0,
) -> ScaleCheck:
    """How long the ground truth's distances are compared with GPS and with ARCore."""
    loc = np.loadtxt(root / "iphone" / "platform-locations.csv", delimiter=",", ndmin=2)
    t, lat, lon, acc = loc[:, 0], loc[:, 1], loc[:, 2], loc[:, 3]
    use = (acc <= 10.0) & (t >= truth.t[0]) & (t <= truth.t[-1])
    if use.sum() < 60:
        raise ValueError(f"{root}: only {use.sum()} GPS fixes with accuracy <= 10 m")
    gps = gps_local_meters(lat[use], lon[use])
    ref = truth.interpolate_positions(t[use])[:, [0, 2]]
    scale, _ = similarity_scale_2d(ref, gps)
    # Block bootstrap: GPS errors are correlated over tens of seconds, so resample 30 s blocks.
    rng = np.random.default_rng(seed)
    blocks = np.floor((t[use] - t[use][0]) / 30.0).astype(int)
    ids = np.unique(blocks)
    boots = []
    for _ in range(300):
        idx = np.concatenate([np.flatnonzero(blocks == b) for b in rng.choice(ids, size=len(ids))])
        boots.append(similarity_scale_2d(ref[idx], gps[idx])[0])
    lo, hi = np.percentile(boots, [2.5, 97.5])
    return ScaleCheck(
        gps_over_truth=scale,
        gps_interval_95=(float(lo), float(hi)),
        gps_fixes=int(use.sum()),
        gps_median_accuracy_m=float(np.median(acc[use])),
        arcore_over_truth=_window_ratio(arcore, truth, times),
        arkit_over_truth=_window_ratio(arkit, truth, times),
    )


def tracking_failure_time(p: np.ndarray, times: np.ndarray) -> float | None:
    """First time the track moves faster than a person walks, or None."""
    speed = np.linalg.norm(np.diff(p, axis=0), axis=1) * SAMPLE_HZ
    bad = np.flatnonzero(speed > MAX_WALK_SPEED)
    return float(times[bad[0]]) if len(bad) else None


def _abs_stats_in(x: np.ndarray) -> dict[str, float]:
    a = np.abs(x) / INCH
    return {
        "n": len(a),
        "median_in": round(float(np.median(a)), 2),
        "p90_in": round(float(np.percentile(a, 90)), 2),
        "signed_median_in": round(float(np.median(x) / INCH), 2),
    }


def evaluate_sequence(number: int) -> dict:
    root = ADVIO_DIR / f"advio-{number:02d}"
    seq = load_sequence(root)
    ark, truth = seq.arkit, seq.ground_truth
    arcore = _read_pose_csv(root / "pixel" / "arcore.csv")
    started = ark.t[np.linalg.norm(ark.p, axis=1) > 0][0]
    t0 = max(started, truth.t[0], arcore.t[0])
    t1 = min(ark.t[-1], truth.t[-1], arcore.t[-1])
    times = np.arange(t0, t1, 1.0 / SAMPLE_HZ)
    A = ark.interpolate_positions(times)
    result: dict = {"sequence": number, "seconds": round(float(times[-1] - times[0]), 1)}
    failed_at = tracking_failure_time(A, times)
    if failed_at is not None:
        result["arkit_tracking_failed_at_s"] = round(failed_at, 2)
        result["arkit_max_speed_m_s"] = round(
            float(np.max(np.linalg.norm(np.diff(A, axis=0), axis=1)) * SAMPLE_HZ), 1
        )
        return result
    check = reference_scale_check(root, truth, ark, arcore, times)
    result["scale_check"] = asdict(check)
    refs = {
        "truth": truth.interpolate_positions(times),
        "truth_gps": truth.interpolate_positions(times) * check.gps_over_truth,
        "arcore": arcore.interpolate_positions(times),
    }
    ark_R = ark.R[[ark.nearest(x) for x in times]]
    truth_R = truth.R[[truth.nearest(x) for x in times]]
    step = int(START_EVERY_S * SAMPLE_HZ)
    result["walked_m_truth_gps"] = round(float(horizontal_path_length(refs["truth_gps"])[-1]), 1)
    result["distance_error"] = {}
    result["position_error_truth_gps"] = {}
    result["noise_split_in"] = {}
    result["errors_in"] = {}
    for ft in DISTANCES_FT:
        d = ft * FEET
        # Windows are defined on the GPS-scaled truth so every reference is scored on the same spans.
        i, j = window_pairs(refs["truth_gps"], d, step)
        errs = {name: distance_errors(A, P, i, j) for name, P in refs.items()}
        result["distance_error"][str(ft)] = {name: _abs_stats_in(e) for name, e in errs.items()}
        pe = position_errors(A, refs["truth_gps"], ark_R, truth_R, i, j)
        result["position_error_truth_gps"][str(ft)] = _abs_stats_in(pe)
        arcore_vs_truth = distance_errors(refs["arcore"], refs["truth_gps"], i, j)
        va, vt, vc = three_cornered_hat(
            robust_variance(errs["truth_gps"]),
            robust_variance(errs["arcore"]),
            robust_variance(arcore_vs_truth),
        )
        sig = lambda v: round(float(np.sign(v) * np.sqrt(abs(v)) / INCH), 2)  # noqa: E731
        result["noise_split_in"][str(ft)] = {
            "arkit": sig(va),
            "truth_gps": sig(vt),
            "arcore": sig(vc),
        }
        result["errors_in"][str(ft)] = {k: (v / INCH).round(2).tolist() for k, v in errs.items()}
    return result


def _pooled(results: list[dict]) -> dict:
    ok = [r for r in results if "errors_in" in r]
    out: dict = {"sequences": [r["sequence"] for r in ok]}
    for ft in DISTANCES_FT:
        out[str(ft)] = {}
        for ref in ("truth", "truth_gps", "arcore"):
            e = np.concatenate([np.asarray(r["errors_in"][str(ft)][ref]) for r in ok])
            out[str(ft)][ref] = _abs_stats_in(e * INCH)
    return out


def _markdown(results: list[dict], pooled: dict) -> str:
    lines = ["# ADVIO outdoor drift (generated by `uv run python -m evals.drift`)", ""]
    lines.append("## Reference scale check")
    lines.append("")
    lines.append(
        "| Seq | GPS / truth (95% interval) | ARCore / truth | ARKit / truth | ARKit tracking |"
    )
    lines.append("| --- | --- | --- | --- | --- |")
    for r in results:
        if "scale_check" in r:
            c = r["scale_check"]
            lo, hi = c["gps_interval_95"]
            lines.append(
                f"| {r['sequence']} | {c['gps_over_truth']:.3f} ({lo:.3f} to {hi:.3f}) | "
                f"{c['arcore_over_truth']:.3f} | {c['arkit_over_truth']:.3f} | ok, {r['seconds']:.0f} s |"
            )
        else:
            lines.append(
                f"| {r['sequence']} | | | | failed at {r['arkit_tracking_failed_at_s']} s "
                f"(jumped at {r['arkit_max_speed_m_s']} m/s) |"
            )
    lines += ["", "## Distance error, pooled over the sequences where ARKit kept tracking", ""]
    lines.append(
        f"Sequences {', '.join(map(str, pooled['sequences']))}. |ARKit - reference| in inches."
    )
    lines.append("")
    lines.append(
        "| Walked | vs truth as published: median / p90 | vs truth rescaled to GPS | vs ARCore | signed median vs ARCore |"
    )
    lines.append("| --- | --- | --- | --- | --- |")
    for ft in DISTANCES_FT:
        p = pooled[str(ft)]
        lines.append(
            f"| {ft} ft | {p['truth']['median_in']:.1f} / {p['truth']['p90_in']:.1f} | "
            f"{p['truth_gps']['median_in']:.1f} / {p['truth_gps']['p90_in']:.1f} | "
            f"{p['arcore']['median_in']:.1f} / {p['arcore']['p90_in']:.1f} | {p['arcore']['signed_median_in']:+.1f} |"
        )
    lines += ["", "## Per sequence", ""]
    lines.append(
        "| Seq | Walked | vs truth rescaled to GPS: median / p90 (signed) | vs ARCore: median / p90 (signed) | own spread (1 sigma, in): ARKit / truth / ARCore |"
    )
    lines.append("| --- | --- | --- | --- | --- |")
    for r in results:
        if "distance_error" not in r:
            continue
        for ft in DISTANCES_FT:
            de = r["distance_error"][str(ft)]
            ns = r["noise_split_in"][str(ft)]
            g, a = de["truth_gps"], de["arcore"]
            lines.append(
                f"| {r['sequence']} | {ft} ft | {g['median_in']:.1f} / {g['p90_in']:.1f} ({g['signed_median_in']:+.1f}) | "
                f"{a['median_in']:.1f} / {a['p90_in']:.1f} ({a['signed_median_in']:+.1f}) | "
                f"{ns['arkit']:.1f} / {ns['truth_gps']:.1f} / {ns['arcore']:.1f} |"
            )
    lines.append("")
    lines.append(
        "A negative spread means that tracker's random error is smaller than the other two can resolve."
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--sequences", type=int, nargs="+", default=list(SEQUENCES))
    ap.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "results")
    args = ap.parse_args()
    results = [evaluate_sequence(n) for n in args.sequences]
    pooled = _pooled(results)
    args.out.mkdir(parents=True, exist_ok=True)
    slim = [{k: v for k, v in r.items() if k != "errors_in"} for r in results]
    (args.out / "advio_drift.json").write_text(
        json.dumps({"sequences": slim, "pooled": pooled}, indent=1)
    )
    md = _markdown(results, pooled)
    (args.out / "advio_drift.md").write_text(md)
    print(md)


if __name__ == "__main__":
    main()
