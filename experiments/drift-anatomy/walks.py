"""Walks with ARKit's track, a reference track and the heading offset between them, loaded through
the evals harness (branch t3/evals) so the alignment is the one the evals' tables used.

The harness is imported read-only from EVALS_HARNESS (default: the house-scanning-evals checkout).
Nothing here writes into it: bytecode caching is off before the import. Data comes from
HOUSE_SCANNING_DATA (default ~/house-scanning-data), as in the evals.
"""

from __future__ import annotations

import os
import subprocess
import sys
import types
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from metrics import yaw_offset

EVALS_HARNESS = Path(
    os.environ.get(
        "EVALS_HARNESS",
        Path.home() / "Programming Projects/house-scanning-evals/experiments/evals",
    )
)
EXPECTED_COMMIT = "190ed33"
MARVIN_SITES = ("bar", "church")  # atrium left out: its reference jitters by up to 0.4 m
ADVIO_WALKS = (20, 21, 22)  # 23 lost tracking 5.5 s in
SCALE_OUTLIER = (
    0.10  # walks further than this from the reference's scale are dropped, as in the evals
)


@dataclass
class Walk:
    dataset: str  # "marvin" or "advio"
    name: str  # "bar/seq3", "advio-21"
    times: np.ndarray  # (N,) seconds
    ark: np.ndarray  # (N, 3) ARKit positions, y up, in a frame with the reference's handedness
    ref: np.ndarray  # (N, 3) reference positions, y up, meters
    delta: np.ndarray  # (N,) heading offset, reference minus ARKit, radians
    start_step: int  # samples between window starts in the evals' 3 to 30 ft windows
    scale: float  # ARKit / reference, the evals' median over windows of 10 ft or more
    accel_t: np.ndarray = field(default_factory=lambda: np.empty(0))
    accel_norm: np.ndarray = field(default_factory=lambda: np.empty(0))  # |a|, m/s^2


def harness_modules():
    if not (EVALS_HARNESS / "evals" / "drift.py").exists():
        raise FileNotFoundError(
            f"evals harness not found at {EVALS_HARNESS}; set EVALS_HARNESS to the "
            "experiments/evals folder of a house-scanning checkout on branch t3/evals"
        )
    sys.dont_write_bytecode = True
    # evals.modern_arkit imports gdown for its fetch(), which this experiment never calls: the data
    # is already on disk and this run makes no downloads. Any use of the stand-in fails loudly.
    if "gdown" not in sys.modules:
        stub = types.ModuleType("gdown")

        def _refuse(name: str):
            raise RuntimeError(f"gdown.{name}: drift-anatomy never downloads")

        stub.__getattr__ = _refuse  # type: ignore[method-assign]
        sys.modules["gdown"] = stub
    if str(EVALS_HARNESS) not in sys.path:
        sys.path.insert(0, str(EVALS_HARNESS))
    import evals.advio as advio
    import evals.drift as drift
    import evals.modern_arkit as modern_arkit

    return advio, drift, modern_arkit


def harness_commit() -> str:
    out = subprocess.run(
        ["git", "-C", str(EVALS_HARNESS), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.strip()


def marvin_walks() -> tuple[list[Walk], list[tuple[str, float]]]:
    """Bar and church walks, and the (name, scale) of walks dropped for being off the reference's
    scale by more than SCALE_OUTLIER. MARViN has one image a second (evals README, section 6), so
    an image's number is its time in seconds."""
    _, drift, ma = harness_modules()
    walks, dropped = [], []
    for site in MARVIN_SITES:
        root = ma.MARVIN_DIR / site
        truth = {**ma.read_table(root / "train.txt", 8), **ma.read_table(root / "test.txt", 8)}
        frame = ma.level_frame(np.array([v[:3] for v in truth.values()]))
        for seq in sorted(root.glob("seq*/ARkitPose.txt"), key=lambda p: int(p.parent.name[3:])):
            name = seq.parent.name
            ark_rows = ma.read_table(seq, 8)
            keys = sorted(k for k in ark_rows if f"{name}/{k}" in truth)
            if len(keys) < 30:  # the evals' own cut: walks without a reference
                continue
            # Mirrors evals.modern_arkit.evaluate: level the reference, y up, pair the handedness.
            t = np.array([truth[f"{name}/{k}"][:3] for k in keys]) @ frame.T
            t = t[:, [0, 2, 1]]
            fwd = (
                np.array([ma.quat_wxyz_to_matrix(truth[f"{name}/{k}"][3:])[2] for k in keys])
                @ frame.T
            )
            ark, delta, _ = ma.align_headings(
                np.array([ark_rows[k][:3] for k in keys]),
                np.array([ark_rows[k][3:] for k in keys]),
                t,
                fwd[:, [0, 2, 1]],
            )
            errs = ma.walk_errors(ark, t, delta)
            ratios = np.concatenate(
                [errs[ft]["ark"] / errs[ft]["truth"] for ft in drift.DISTANCES_FT if ft >= 10]
            )
            scale = float(np.median(ratios))
            label = f"{site}/{name}"
            if abs(scale - 1) > SCALE_OUTLIER:
                dropped.append((label, scale))
                continue
            times = np.array([float(k.split("_")[1].split(".")[0]) for k in keys])
            walks.append(Walk("marvin", label, times, ark, t, delta, 1, scale))
    return walks, dropped


def advio_walks() -> list[Walk]:
    """ADVIO 20 to 22 at 10 Hz against the ground truth rescaled to GPS, exactly as
    evals.drift.evaluate_sequence builds them."""
    advio, drift, _ = harness_modules()
    walks = []
    for number in ADVIO_WALKS:
        root = drift.ADVIO_DIR / f"advio-{number:02d}"
        seq = advio.load_sequence(root)
        ark, truth = seq.arkit, seq.ground_truth
        arcore = advio._read_pose_csv(root / "pixel" / "arcore.csv")
        started = ark.t[np.linalg.norm(ark.p, axis=1) > 0][0]
        t0 = max(started, truth.t[0], arcore.t[0])
        t1 = min(ark.t[-1], truth.t[-1], arcore.t[-1])
        times = np.arange(t0, t1, 1.0 / drift.SAMPLE_HZ)
        A = ark.interpolate_positions(times)
        failed = drift.tracking_failure_time(A, times)
        if failed is not None:
            raise RuntimeError(f"advio-{number}: ARKit lost tracking at {failed:.1f} s")
        check = drift.reference_scale_check(root, truth, ark, arcore, times)
        ref = truth.interpolate_positions(times) * check.gps_over_truth
        ark_R = ark.R[[ark.nearest(x) for x in times]]
        truth_R = truth.R[[truth.nearest(x) for x in times]]
        delta = yaw_offset(ark_R, truth_R)
        step = int(drift.START_EVERY_S * drift.SAMPLE_HZ)
        ratios = []
        for ft in drift.DISTANCES_FT:
            if ft >= 10:
                i, j = drift.window_pairs(ref, ft * drift.FEET, step)
                ratios.append(
                    np.linalg.norm(drift.at(A, j) - A[i], axis=1)
                    / np.linalg.norm(drift.at(ref, j) - ref[i], axis=1)
                )
        acc = np.loadtxt(root / "iphone" / "accelerometer.csv", delimiter=",", ndmin=2)
        walks.append(
            Walk(
                "advio",
                f"advio-{number}",
                times,
                A,
                ref,
                delta,
                step,
                float(np.median(np.concatenate(ratios))),
                accel_t=acc[:, 0],
                accel_norm=np.linalg.norm(acc[:, 1:4], axis=1),
            )
        )
    return walks
