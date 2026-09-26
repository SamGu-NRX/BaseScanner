"""Check a Measure Lab session the way a consumer reads it: from session.json and the JPEGs only.

    uv run python -m evals.check_replay ~/house-scanning-data/replays/advio-20-0040-0075

For pairs of nearby keyframes it matches ORB features and measures how far each match lies from
the epipolar line predicted by the two poses and intrinsics under the documented conventions. If
the pose, intrinsics or pixel convention were wrong (a swapped axis, a transposed rotation, a
portrait intrinsic on a landscape image), the median distance would be tens of pixels.
Also reports the sign conventions directly: world up in each camera should point up in the image
for a phone held upright in landscape, or left for one held in portrait (as ADVIO's was).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import cv2
import numpy as np

from evals.camera import FLIP_YZ


def _pose(kf: dict) -> np.ndarray:
    return np.array(kf["pose"], dtype=np.float64).reshape(4, 4).T


def _K_opencv(kf: dict) -> np.ndarray:
    fx, fy, cx, cy = kf["intrinsics"]
    # Continuous pixel coordinates to OpenCV's integer-centred ones.
    return np.array([[fx, 0, cx - 0.5], [0, fy, cy - 0.5], [0, 0, 1]])


def fundamental(kf_a: dict, kf_b: dict) -> np.ndarray:
    Ta, Tb = _pose(kf_a), _pose(kf_b)
    # OpenCV camera b from OpenCV camera a.
    R = FLIP_YZ @ Tb[:3, :3].T @ Ta[:3, :3] @ FLIP_YZ
    t = FLIP_YZ @ Tb[:3, :3].T @ (Ta[:3, 3] - Tb[:3, 3])
    tx = np.array([[0, -t[2], t[1]], [t[2], 0, -t[0]], [-t[1], t[0], 0]])
    E = tx @ R
    return np.linalg.inv(_K_opencv(kf_b)).T @ E @ np.linalg.inv(_K_opencv(kf_a))


def epipolar_distances(F: np.ndarray, pa: np.ndarray, pb: np.ndarray) -> np.ndarray:
    """Symmetric point-to-epipolar-line distance, pixels."""
    ha = np.c_[pa, np.ones(len(pa))]
    hb = np.c_[pb, np.ones(len(pb))]
    lb = ha @ F.T
    la = hb @ F
    db = np.abs((hb * lb).sum(1)) / np.linalg.norm(lb[:, :2], axis=1)
    da = np.abs((ha * la).sum(1)) / np.linalg.norm(la[:, :2], axis=1)
    return (da + db) / 2


def check(folder: Path, gap: int = 2) -> dict:
    manifest = json.loads((folder / "session.json").read_text())
    kfs = manifest["keyframes"]
    orb = cv2.ORB_create(3000)
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    medians, ups = [], []
    for a, b in zip(kfs[:-gap], kfs[gap:], strict=True):
        ia = cv2.imread(str(folder / a["img"]), cv2.IMREAD_GRAYSCALE)
        ib = cv2.imread(str(folder / b["img"]), cv2.IMREAD_GRAYSCALE)
        if ia.shape != (a["h"], a["w"]):
            raise ValueError(f"{a['img']} is {ia.shape}, manifest says {a['h']}x{a['w']}")
        ka, da = orb.detectAndCompute(ia, None)
        kb, db = orb.detectAndCompute(ib, None)
        if da is None or db is None:
            continue
        m = matcher.match(da, db)
        if len(m) < 30:
            continue
        pa = np.float32([ka[x.queryIdx].pt for x in m])
        pb = np.float32([kb[x.trainIdx].pt for x in m])
        # Keep geometrically consistent matches by an image-only fit, then score them against the
        # pose-predicted geometry, so bad matches don't inflate the number.
        _, inl = cv2.findFundamentalMat(pa, pb, cv2.FM_RANSAC, 1.5, 0.999)
        if inl is None or inl.sum() < 20:
            continue
        keep = inl.ravel().astype(bool)
        d = epipolar_distances(fundamental(a, b), pa[keep], pb[keep])
        medians.append(float(np.median(d)))
        up_cam = _pose(a)[:3, :3].T @ np.array([0.0, 1.0, 0.0])
        ups.append(up_cam)
    if not medians:
        raise ValueError(
            f"{folder}: no keyframe pair had enough matches and inliers to check the poses"
        )
    up = np.mean(ups, axis=0)
    return {
        "pairs": len(medians),
        "median_epipolar_px": float(np.median(medians)),
        "p90_epipolar_px": float(np.percentile(medians, 90)),
        "world_up_in_camera": [round(float(v), 2) for v in up],
    }


def main() -> None:
    folder = Path(sys.argv[1]).expanduser()
    print(json.dumps(check(folder), indent=2))


if __name__ == "__main__":
    main()
