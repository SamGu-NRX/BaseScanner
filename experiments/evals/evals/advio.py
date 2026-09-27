"""Read one ADVIO sequence (Cortés et al., ECCV 2018): iPhone video frames, ARKit poses, ground truth.

Layout of an extracted `advio-XX/` folder, as the dataset README and its own scripts read it:

- `iphone/frames.mov`: 60 fps, coded as 1280 x 720 landscape frames with a -90 degree display tag
  (so players show it portrait). `iphone/frames.csv`: `t, frame_number`, numbered from 1 (video
  frame `n - 1`), same timestamps as arkit.csv.
- `iphone/arkit.csv`: ARKit pose per video frame, `t, x, y, z, qw, qx, qy, qz`, orientation in the
  portrait device frame (verified against the images; see `evals/camera.py`).
- `ground-truth/pose.csv`: 100 Hz, same columns. `ground-truth/fixpoints.csv`: manual fixes.

All timestamps share one clock (seconds). The calibration is per recording batch and lives in the
dataset's GitHub repo, not in the zip; `_BATCHES` copies it with its source URL.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from evals.geometry import quat_wxyz_to_matrix


@dataclass(frozen=True)
class Calibration:
    """Pinhole + radial-tangential model of the portrait (720 x 1280) video, OpenCV convention:
    pixel centers at integer coordinates, +x right, +y down, camera looks along +z."""

    width: int
    height: int
    fx: float
    fy: float
    cx: float
    cy: float
    k1: float
    k2: float
    p1: float
    p2: float
    source: str

    def camera_matrix(self) -> np.ndarray:
        return np.array([[self.fx, 0, self.cx], [0, self.fy, self.cy], [0, 0, 1]], dtype=np.float64)

    def distortion(self) -> np.ndarray:
        return np.array([self.k1, self.k2, self.p1, self.p2], dtype=np.float64)


_CAL_URL = "https://raw.githubusercontent.com/AaltoVision/ADVIO/master/calibration/"

# The iPhone camera was calibrated once per recording batch (calibration/README.md in the ADVIO repo).
_BATCHES = [
    (
        range(1, 13),
        Calibration(
            720,
            1280,
            1077.2,
            1079.3,
            362.145,
            636.3873,
            0.0478,
            0.0339,
            -0.00033,
            -0.00091,
            _CAL_URL + "iphone-02.yaml",
        ),
    ),
    (
        range(13, 18),
        Calibration(
            720,
            1280,
            1082.4,
            1084.4,
            364.6778,
            643.3080,
            0.0366,
            0.0803,
            0.000783,
            -0.000215,
            _CAL_URL + "iphone-03.yaml",
        ),
    ),
    (
        range(18, 20),
        Calibration(
            720,
            1280,
            1076.9,
            1078.5,
            360.96,
            619.31,
            0.0510,
            -0.0354,
            -0.0054,
            0.0473,
            _CAL_URL + "iphone-01.yaml",
        ),
    ),
    (
        range(20, 24),
        Calibration(
            720,
            1280,
            1081.1,
            1082.1,
            359.59,
            640.79,
            0.0556,
            -0.0454,
            0.0009,
            -0.0018,
            _CAL_URL + "iphone-04.yaml",
        ),
    ),
]


def calibration_for(sequence: int) -> Calibration:
    for seqs, cal in _BATCHES:
        if sequence in seqs:
            return cal
    raise ValueError(f"ADVIO has sequences 1 to 23; got {sequence}")


@dataclass(frozen=True)
class PoseTrack:
    """Timestamps (N,), positions (N, 3) and rotation matrices (N, 3, 3), body-to-world."""

    t: np.ndarray
    p: np.ndarray
    R: np.ndarray

    def __len__(self) -> int:
        return len(self.t)

    def interpolate_positions(self, times: np.ndarray) -> np.ndarray:
        """Linear interpolation of position; raises if any time is outside the track."""
        if times.min() < self.t[0] or times.max() > self.t[-1]:
            raise ValueError(
                f"times {times.min():.3f}..{times.max():.3f} outside track "
                f"{self.t[0]:.3f}..{self.t[-1]:.3f}"
            )
        return np.stack([np.interp(times, self.t, self.p[:, k]) for k in range(3)], axis=1)

    def nearest(self, time: float) -> int:
        i = int(np.searchsorted(self.t, time))
        if i == 0:
            return 0
        if i >= len(self.t):
            return len(self.t) - 1
        return i if abs(self.t[i] - time) < abs(self.t[i - 1] - time) else i - 1


def _read_pose_csv(path: Path) -> PoseTrack:
    data = np.loadtxt(path, delimiter=",", ndmin=2)
    if data.shape[1] != 8:
        raise ValueError(
            f"{path}: expected 8 columns (t, x, y, z, qw, qx, qy, qz), got {data.shape[1]}"
        )
    order = np.argsort(data[:, 0], kind="stable")
    data = data[order]
    q = data[:, 4:8]
    norms = np.linalg.norm(q, axis=1)
    # Dropping bad rows would shift every later row against frames.csv, so refuse instead. No
    # ADVIO pose file used here has one.
    bad = np.flatnonzero(np.abs(norms - 1) >= 1e-2)
    if len(bad):
        raise ValueError(
            f"{path}: {len(bad)} quaternions are not unit length (first at row {bad[0]}, norm "
            f"{norms[bad[0]]:.4f})"
        )
    return PoseTrack(t=data[:, 0], p=data[:, 1:4], R=quat_wxyz_to_matrix(data[:, 4:8]))


@dataclass(frozen=True)
class Sequence:
    number: int
    root: Path
    frame_times: np.ndarray
    arkit: PoseTrack
    ground_truth: PoseTrack
    calibration: Calibration

    @property
    def video(self) -> Path:
        return self.root / "iphone" / "frames.mov"


def load_sequence(root: Path) -> Sequence:
    root = Path(root)
    number = int(root.name.split("-")[-1])
    frames = np.loadtxt(root / "iphone" / "frames.csv", delimiter=",", ndmin=2)
    frame_idx = frames[:, 1].astype(int)
    if not np.array_equal(frame_idx, np.arange(1, len(frames) + 1)):
        raise ValueError(f"{root}: frames.csv frame numbers are not 1..N in order")
    gt_path = root / "ground-truth" / "pose.csv"
    if not gt_path.exists():
        gt_path = root / "ground-truth" / "poses.csv"
    return Sequence(
        number=number,
        root=root,
        frame_times=frames[:, 0],
        arkit=_read_pose_csv(root / "iphone" / "arkit.csv"),
        ground_truth=_read_pose_csv(gt_path),
        calibration=calibration_for(number),
    )
