"""Camera conventions: ADVIO's portrait calibration and poses to Measure Lab's landscape sensor frame.

Measure Lab session format v2 (experiments/measure-lab/README.md on t3/measure-lab):
- camera frame: +x right and +y up in the unrotated landscape sensor image, looking along -z;
- intrinsics [fx, fy, cx, cy] in continuous pixel coordinates of that JPEG, (0, 0) its top-left corner.

ADVIO stores the video as landscape frames with a -90 degree display tag, so the coded frames are
the unrotated sensor images. Its calibration was made on the portrait (displayed) frames with
OpenCV's convention (pixel centers at integers, +y down, looking along +z), and its ARKit and
ground-truth orientations are in the portrait device frame (+x right, +y up on the portrait screen,
+z out of the screen). `check_relative_rotations` verifies that reading against the images.
"""

from __future__ import annotations

import numpy as np

# Columns are the Measure Lab camera axes written in the portrait device frame:
# landscape image right = portrait screen down (-y), landscape image up = portrait right (+x),
# and both look along -z.
DEVICE_TO_LANDSCAPE_CAMERA = np.array(
    [
        [0.0, 1.0, 0.0],
        [-1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0],
    ]
)

# Measure Lab camera (+y up, looks along -z) to OpenCV camera (+y down, looks along +z) and back.
FLIP_YZ = np.diag([1.0, -1.0, -1.0])


def landscape_intrinsics_from_portrait(
    fx: float, fy: float, cx: float, cy: float, portrait_width: int
) -> tuple[float, float, float, float]:
    """Portrait OpenCV intrinsics to landscape continuous-pixel intrinsics.

    The landscape sensor image is the portrait image rotated 90 degrees counter-clockwise, so in
    continuous coordinates u_l = v_p and v_l = W_p - u_p. OpenCV places pixel centers at integers,
    so continuous = OpenCV + 0.5.
    """
    cx_c, cy_c = cx + 0.5, cy + 0.5
    return fy, fx, cy_c, portrait_width - cx_c


def landscape_pose(position: np.ndarray, R_device: np.ndarray) -> np.ndarray:
    """4x4 camera-to-world pose in Measure Lab's camera convention from a portrait-device pose."""
    T = np.eye(4)
    T[:3, :3] = R_device @ DEVICE_TO_LANDSCAPE_CAMERA
    T[:3, 3] = position
    return T


def column_major(T: np.ndarray) -> list[float]:
    """16 numbers column by column (simd_float4x4 layout)."""
    return [float(v) for v in np.asarray(T).T.reshape(-1)]


def relative_rotation_cv(R_i: np.ndarray, R_j: np.ndarray) -> np.ndarray:
    """Rotation taking OpenCV camera-i coordinates to camera-j coordinates, from two Measure Lab
    camera-to-world rotations. X_j = R_ij X_i + t_ij."""
    return FLIP_YZ @ R_j.T @ R_i @ FLIP_YZ
