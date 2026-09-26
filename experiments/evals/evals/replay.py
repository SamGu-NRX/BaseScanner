"""Convert a stretch of one ADVIO walk into a Measure Lab session (format v2) that the app can replay.

    uv run python -m evals.replay --sequence 20 --start 40 --end 75

What goes in:
- keyframes chosen by Measure Lab's own rule (0.5 m moved or 15 degrees turned since the last saved
  one, `KeyframeSelector.swift`), applied to the ARKit poses;
- each keyframe's video frame, undistorted with ADVIO's calibration so the pinhole intrinsics are
  exact, saved as the unrotated landscape JPEG;
- the ARKit pose converted to Measure Lab's camera convention (`evals.camera`);
- `ground_truth.json` beside session.json: ADVIO's ground-truth pose for every keyframe, so a
  verification run can compare anything the app computes with the truth. The app ignores it.

ADVIO records no ARKit tracking state, taps, points, walls or measurements. Tracking is written as
"normal" from the first frame whose ARKit position is non-zero (ARKit reports exactly zero until it
initialises); the other arrays are empty.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

import cv2
import numpy as np

from evals.advio import Sequence, load_sequence
from evals.camera import column_major, landscape_intrinsics_from_portrait, landscape_pose
from evals.geometry import rotation_angle_deg
from evals.paths import ADVIO_DIR, REPLAYS_DIR

SPACING_METERS = 0.5
SPACING_DEGREES = 15.0
JPEG_QUALITY = 90

# Measure Lab's gates, copied from its sources (LabSession.swift, Wall.swift, Triangulation.swift)
# so a replay applies the same thresholds as a phone session.
MEASURE_LAB_GATES = {
    "trackingStableSeconds": 1.0,
    "minimumGroundLookDown": 30.0,
    "minimumContactSeparation": 2.0,
    "maximumAngleFromWallNormal": 60.0,
    "wallValidationTolerance": 2 * 0.0254,
    "minimumCameraOffsetFromWall": 0.1,
    "minimumRayAngle": 15.0,
    "maximumRayGap": 2 * 0.0254,
    "keyframeSpacingMeters": SPACING_METERS,
    "keyframeSpacingDegrees": SPACING_DEGREES,
}


def select_keyframes(
    positions: np.ndarray, rotations: np.ndarray, meters: float, degrees: float
) -> list[int]:
    """Indices where the camera has moved `meters` or turned `degrees` since the last selected one.
    The first index is always selected. Same rule as Measure Lab's KeyframeSelector."""
    if len(positions) == 0:
        return []
    chosen = [0]
    for i in range(1, len(positions)):
        last = chosen[-1]
        moved = float(np.linalg.norm(positions[i] - positions[last]))
        if moved >= meters or rotation_angle_deg(rotations[last], rotations[i]) >= degrees:
            chosen.append(i)
    return chosen


def _undistort_landscape(frame: np.ndarray, seq: Sequence) -> np.ndarray:
    """Undistort in the portrait frame the calibration was made in, keeping the same pinhole matrix,
    then rotate back to the landscape sensor image."""
    cal = seq.calibration
    portrait = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
    if portrait.shape[:2] != (cal.height, cal.width):
        raise ValueError(
            f"portrait frame is {portrait.shape[:2]}, calibration is {cal.height}x{cal.width}"
        )
    K = cal.camera_matrix()
    fixed = cv2.undistort(portrait, K, cal.distortion(), None, K)
    return cv2.rotate(fixed, cv2.ROTATE_90_COUNTERCLOCKWISE)


def read_frames(video: Path, wanted: list[int]) -> dict[int, np.ndarray]:
    """Decode the coded (unrotated) frames with these 0-based indices, reading sequentially so the
    index is exact (seeking by time in this file is off by several frames)."""
    cap = cv2.VideoCapture(str(video))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 0)
    todo = sorted(set(wanted))
    out: dict[int, np.ndarray] = {}
    n = 0
    k = 0
    while k < len(todo):
        ok = cap.grab()
        if not ok:
            raise ValueError(f"{video}: ended at frame {n}, still need {todo[k:]}")
        if n == todo[k]:
            ok, img = cap.retrieve()
            if not ok:
                raise ValueError(f"{video}: could not decode frame {n}")
            out[n] = img
            k += 1
        n += 1
    cap.release()
    return out


def build_session(seq: Sequence, start: float, end: float, out_dir: Path) -> dict:
    t = seq.frame_times
    ark = seq.arkit
    initialised = np.linalg.norm(ark.p, axis=1) > 0
    idx = np.flatnonzero((t >= start) & (t <= end) & initialised)
    if len(idx) == 0:
        raise ValueError(f"no initialised ARKit frames between {start} and {end} s")
    picks = [
        int(idx[i])
        for i in select_keyframes(ark.p[idx], ark.R[idx], SPACING_METERS, SPACING_DEGREES)
    ]

    cal = seq.calibration
    fx, fy, cx, cy = landscape_intrinsics_from_portrait(cal.fx, cal.fy, cal.cx, cal.cy, cal.width)
    session_id = f"advio-{seq.number:02d}-{int(start):04d}-{int(end):04d}"
    folder = out_dir / session_id
    if folder.exists():
        shutil.rmtree(folder)
    (folder / "keyframes").mkdir(parents=True)

    frames = read_frames(seq.video, picks)
    keyframes, truth = [], []
    gt = seq.ground_truth
    for n, i in enumerate(picks, start=1):
        kid = f"k{n:05d}"
        img = _undistort_landscape(frames[i], seq)
        h, w = img.shape[:2]
        path = f"keyframes/{kid}.jpg"
        if not cv2.imwrite(str(folder / path), img, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY]):
            raise OSError(f"could not write {folder / path}")
        keyframes.append(
            {
                "id": kid,
                "img": path,
                "w": w,
                "h": h,
                "intrinsics": [fx, fy, cx, cy],
                "pose": column_major(landscape_pose(ark.p[i], ark.R[i])),
                "timestamp": float(t[i]),
                "tracking": "normal",
                "reason": "motion",
                "depth": None,
            }
        )
        g = gt.nearest(float(t[i]))
        truth.append(
            {
                "keyframe": kid,
                "timestamp": float(t[i]),
                "groundTruthTimestamp": float(gt.t[g]),
                "pose": column_major(landscape_pose(gt.p[g], gt.R[g])),
            }
        )

    first = float(t[idx[0]])
    manifest = {
        "format": "measure-lab-session",
        "formatVersion": 2,
        "units": {
            "length": "meters",
            "angle": "degrees",
            "time": "seconds of device uptime, the clock of ARFrame.timestamp",
            "image": "pixels of the saved JPEG",
        },
        "conventions": {
            "world": "ARKit world frame with worldAlignment .gravity: right-handed, y up (away from gravity), origin and heading fixed where the session started",
            "camera": "ARKit camera frame: +x right and +y up in the unrotated sensor image, the camera looks along -z",
            "pose": "camera-to-world 4x4 matrix, 16 numbers column by column (simd_float4x4 layout)",
            "intrinsics": "[fx, fy, cx, cy] in pixels of the saved, unrotated landscape JPEG",
            "pixel": "[u, v] continuous image coordinates: (0, 0) is the top-left corner of the JPEG, v grows down",
            "ray": "origin is the camera position; direction is a unit vector through the tapped pixel",
        },
        "session": {
            "id": session_id,
            # ADVIO publishes no wall-clock capture time; this is the Zenodo record's publication date.
            "startedAt": "2018-11-02T00:00:00Z",
            "startedAtUptime": first,
            "appVersion": "advio-replay (experiments/evals/evals/replay.py)",
            "deviceModel": "iPhone8,1",
            "systemVersion": "iOS 11 (ARKit 1.0), exact build not published",
            "lidarAvailable": False,
            "meshReconstructionSupported": False,
            "sceneDepthEnabled": False,
        },
        "gates": MEASURE_LAB_GATES,
        "keyframes": keyframes,
        "taps": [],
        "points": [],
        "walls": [],
        "measurements": [],
        "refusals": [],
        "tracking": [{"time": first, "state": "normal"}],
        # Not part of Measure Lab's format; Swift's JSONDecoder ignores unknown keys.
        "provenance": {
            "dataset": "ADVIO (Cortes, Solin, Rahtu, Kannala; ECCV 2018), CC BY-NC 4.0: accuracy testing only, do not redistribute",
            "sequence": seq.number,
            "venue": "outdoor, Espoo campus" if seq.number in (20, 21) else "outdoor",
            "secondsInSequence": [start, end],
            "phone": "iPhone 6s, no LiDAR",
            "images": "coded frames of iphone/frames.mov (unrotated landscape), undistorted with the batch calibration",
            "calibration": cal.source,
            "keyframeRule": f"{SPACING_METERS} m or {SPACING_DEGREES} deg since the last keyframe, on ARKit poses",
            "groundTruth": "ground_truth.json: ADVIO ground-truth pose nearest in time to each keyframe, same conventions but its own world frame (not aligned to ARKit's)",
            "converter": "experiments/evals/evals/replay.py",
        },
    }
    (folder / "session.json").write_text(json.dumps(manifest, indent=2))
    (folder / "ground_truth.json").write_text(json.dumps({"keyframes": truth}, indent=2))
    return {"folder": folder, "keyframes": len(keyframes), "id": session_id}


def zip_folder(folder: Path) -> Path:
    archive = folder.with_suffix(".zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(folder.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(folder.parent))
    return archive


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--sequence", type=int, default=20)
    ap.add_argument("--start", type=float, default=40.0, help="seconds into the sequence")
    ap.add_argument("--end", type=float, default=75.0)
    ap.add_argument("--out", type=Path, default=REPLAYS_DIR)
    args = ap.parse_args()
    seq = load_sequence(ADVIO_DIR / f"advio-{args.sequence:02d}")
    args.out.mkdir(parents=True, exist_ok=True)
    info = build_session(seq, args.start, args.end, args.out)
    archive = zip_folder(info["folder"])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(
        f"{info['id']}: {info['keyframes']} keyframes -> {archive} ({archive.stat().st_size / 1e6:.1f} MB)"
    )
    print(f"sha256 {digest}")


if __name__ == "__main__":
    main()
