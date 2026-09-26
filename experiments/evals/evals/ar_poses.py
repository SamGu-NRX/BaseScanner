"""ETH3D's true camera poses degraded to what a phone's AR tracking would report.

Each setting is an assumption, stated with where its numbers come from:

- `exact`: the true poses, the best any pose prior can do.
- `advio_2018`: the errors measured in `evals.drift` on ADVIO's 2018 iPhone 6s. Scale: each
  group of photos takes one walk's measured scale against ARCore (signed median over 30 ft, walks
  20 to 22 in results/advio_drift.md: -42.2, -23.1 and -15.3 in, so 0.883, 0.936 and 0.958), in
  turn. Position noise: ARKit's own spread over 3 ft is about 3 in (three-cornered hat, walks 20 to
  22), which is two independent position errors, so 5 cm per axis per camera. Rotation noise: 0.2
  degrees per axis, the median disagreement between ARKit and image-derived rotations measured
  while building the replay session (an upper bound: it includes the image estimate's own error).
- `modern_assumed`: a guess for a current iPhone, with no measurement behind it: 2% short, 1 cm
  and 0.1 degrees.

Scale error stretches every camera's offset from the group's first camera; noise is then added
independently per camera. Rotation noise turns each camera about its own centre.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class PoseError:
    scales: tuple[float, ...]  # one per group, taken in turn
    position_sigma_m: float
    rotation_sigma_deg: float
    # How far a correct match may reproject with these poses: 2 px of feature noise plus what the
    # pose noise moves a point 5 m away at the 1024 px focal length (about 560 px): 0.2 degrees is
    # 2 px, 5 cm is 6 px. A tighter threshold discards consistent matches and the photo's scale.
    reprojection_px: float


SETTINGS = {
    "exact": PoseError((1.0,), 0.0, 0.0, 2.0),
    "advio_2018": PoseError((1 - 42.2 / 360, 1 - 23.1 / 360, 1 - 15.3 / 360), 0.05, 0.2, 8.0),
    "modern_assumed": PoseError((0.98,), 0.01, 0.1, 3.0),
}


def small_rotation(axis_angle_rad: np.ndarray) -> np.ndarray:
    """Rotation matrix for a rotation vector (Rodrigues)."""
    theta = float(np.linalg.norm(axis_angle_rad))
    if theta == 0:
        return np.eye(3)
    k = axis_angle_rad / theta
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(theta) * K + (1 - np.cos(theta)) * K @ K


def degrade(
    cam_to_world: list[np.ndarray], scale: float, error: PoseError, rng: np.random.Generator
) -> list[np.ndarray]:
    """AR-like poses for one group: offsets from the first camera scaled, then noise added."""
    origin = cam_to_world[0][:3, 3]
    out = []
    for T in cam_to_world:
        D = np.eye(4)
        D[:3, 3] = origin + scale * (T[:3, 3] - origin)
        D[:3, 3] += rng.normal(0.0, error.position_sigma_m, 3)
        noise = small_rotation(np.radians(rng.normal(0.0, error.rotation_sigma_deg, 3)))
        D[:3, :3] = T[:3, :3] @ noise
        out.append(D)
    return out


def group_poses(views: dict, groups: dict[str, list[list[str]]], setting: str) -> dict[str, dict]:
    """{group id: {view name: 4x4 cam-to-world}} for every group, deterministic per setting."""
    error = SETTINGS[setting]
    rng = np.random.default_rng(_seed(setting))
    out: dict[str, dict] = {}
    k = 0
    for n, members_list in groups.items():
        for members in members_list:
            scale = error.scales[k % len(error.scales)]
            k += 1
            poses = degrade([views[m].cam_to_world for m in members], scale, error, rng)
            out[f"n{n}-{members[0]}"] = {
                "scale": scale,
                "poses": {m: T.tolist() for m, T in zip(members, poses, strict=True)},
            }
    return out


def _seed(setting: str) -> int:
    """A fixed seed per setting (Python's hash() is salted per process, so it is not used)."""
    return sum(ord(c) * 31**i for i, c in enumerate(setting)) % 2**32
