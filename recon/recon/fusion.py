"""Depth maps fused into one volume (a truncated signed distance field, TSDF), the mesh inside it,
and the questions coverage asks of it: is this space occupied, observed, or visible from there.

Each voxel stores the weighted mean of clip((depth - z) / trunc, -1, 1) over the frames whose ray
through it reached depth within `trunc` behind it. A voxel no frame's ray reached keeps weight 0:
that is space nobody saw, which is what makes coverage honest. Negative means inside a surface
(occupied), positive means seen empty. The mesh is the zero level, from marching cubes over the
observed voxels only.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from skimage.measure import marching_cubes

from recon.depth import Depth

MAX_RANGE_M = 6.0  # the app's coverage range; photos resolve too little of a wall beyond it
MAX_VOXELS = 12_000_000  # about 240 MB of volume
MIN_VOXEL_M = 0.04
CHUNK = 2_000_000


@dataclass
class Volume:
    origin: np.ndarray  # world position of voxel (0, 0, 0)'s centre
    voxel: float
    shape: tuple[int, int, int]
    tsdf: np.ndarray  # (nx, ny, nz) float32
    weight: np.ndarray  # (nx, ny, nz) float32
    color: np.ndarray  # (nx, ny, nz, 3) float32 BGR sums of near-surface samples
    color_n: np.ndarray  # (nx, ny, nz) float32

    @property
    def trunc(self) -> float:
        return 3 * self.voxel

    def ijk(self, points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Nearest voxel indices (..., 3) and whether each lies inside the volume."""
        idx = np.rint((points - self.origin) / self.voxel).astype(np.int64)
        inside = np.all((idx >= 0) & (idx < np.array(self.shape)), axis=-1)
        return np.clip(idx, 0, np.array(self.shape) - 1), inside

    def lookup(self, points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """(tsdf, weight) at the nearest voxel; weight 0 outside the volume."""
        idx, inside = self.ijk(points)
        t = self.tsdf[idx[..., 0], idx[..., 1], idx[..., 2]]
        w = np.where(inside, self.weight[idx[..., 0], idx[..., 1], idx[..., 2]], 0.0)
        return t, w

    def occupied(self, points: np.ndarray) -> np.ndarray:
        t, w = self.lookup(points)
        return (w > 0) & (t < 0)

    def observed(self, points: np.ndarray) -> np.ndarray:
        return self.lookup(points)[1] > 0

    def blocked(self, start: np.ndarray, ends: np.ndarray, stop_short: np.ndarray) -> np.ndarray:
        """Whether an occupied voxel lies on the segment from `start` to each end, ignoring the
        last `stop_short` meters (the surface being looked at, within tolerance)."""
        d = ends - start
        length = np.linalg.norm(d, axis=-1)
        reach = np.maximum(length - stop_short, 0.0)
        step = self.voxel / 2
        n = int(np.ceil(reach.max() / step)) + 1 if len(reach) else 0
        out = np.zeros(len(ends), bool)
        for i in range(0, len(ends), 4096):
            sl = slice(i, i + 4096)
            ts = np.arange(n) * step  # meters along each segment
            along = d[sl] / np.maximum(length[sl], 1e-9)[:, None]
            pts = start + along[:, None, :] * ts[None, :, None]
            occ = self.occupied(pts) & (ts[None, :] < reach[sl][:, None])
            out[sl] = occ.any(axis=1)
        return out


def _points(depth: Depth, T: np.ndarray, stride: int = 8) -> np.ndarray:
    """World points of a depth map, every `stride` pixels, within MAX_RANGE_M."""
    h, w = depth.depth.shape
    v, u = np.mgrid[stride // 2 : h : stride, stride // 2 : w : stride]
    z = depth.depth[v, u]
    ok = np.isfinite(z) & (z > 0.1) & (z < MAX_RANGE_M)
    fx, fy, cx, cy = depth.intrinsics
    x = (u[ok] + 0.5 - cx) / fx * z[ok]
    y = -(v[ok] + 0.5 - cy) / fy * z[ok]
    cam = np.stack([x, y, -z[ok]], axis=-1)
    return cam @ T[:3, :3].T + T[:3, 3]


def bounds(depths: dict[str, Depth], poses: dict[str, np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """The box holding the cameras and the middle 98% of what they saw, plus half a meter."""
    pts = np.concatenate([_points(depths[k], poses[k]) for k in depths])
    cams = np.array([poses[k][:3, 3] for k in depths])
    lo = np.minimum(np.percentile(pts, 1, axis=0), cams.min(axis=0)) - 0.5
    hi = np.maximum(np.percentile(pts, 99, axis=0), cams.max(axis=0)) + 0.5
    return lo, hi


def integrate(
    depths: dict[str, Depth], poses: dict[str, np.ndarray], voxel: float | None = None
) -> Volume:
    lo, hi = bounds(depths, poses)
    size = hi - lo
    if voxel is None:
        voxel = max(MIN_VOXEL_M, float(np.cbrt(np.prod(size) / MAX_VOXELS)))
    shape = tuple(int(np.ceil(s / voxel)) + 1 for s in size)
    vol = Volume(
        lo,
        voxel,
        shape,
        np.ones(shape, np.float32),
        np.zeros(shape, np.float32),
        np.zeros((*shape, 3), np.float32),
        np.zeros(shape, np.float32),
    )
    flat_t, flat_w = vol.tsdf.reshape(-1), vol.weight.reshape(-1)
    flat_c, flat_n = vol.color.reshape(-1, 3), vol.color_n.reshape(-1)
    total = flat_t.size
    grid = np.array(shape)
    for key, dm in depths.items():
        T = poses[key]
        R, c = T[:3, :3], T[:3, 3]
        fx, fy, cx, cy = dm.intrinsics
        h, w = dm.depth.shape
        for start in range(0, total, CHUNK):
            ids = np.arange(start, min(start + CHUNK, total))
            ijk = np.stack(np.unravel_index(ids, grid), axis=-1)
            X = lo + ijk * voxel
            p = (X - c) @ R  # camera coordinates, ARKit axes
            z = -p[:, 2]
            ok = (z > 0.1) & (z <= MAX_RANGE_M)
            u = np.full(len(z), -1.0)
            v = np.full(len(z), -1.0)
            u[ok] = cx + fx * p[ok, 0] / z[ok]
            v[ok] = cy - fy * p[ok, 1] / z[ok]
            ok &= (u >= 0) & (u < w) & (v >= 0) & (v < h)
            sel = np.flatnonzero(ok)
            d = dm.depth[v[sel].astype(np.int64), u[sel].astype(np.int64)]
            sdf = d - z[sel]
            good = np.isfinite(sdf) & (sdf > -vol.trunc)
            sel, sdf = sel[good], sdf[good]
            gid = ids[sel]
            t = np.clip(sdf / vol.trunc, -1, 1).astype(np.float32)
            wo = flat_w[gid]
            flat_t[gid] = (flat_t[gid] * wo + t) / (wo + 1)
            flat_w[gid] = wo + 1
            near = np.abs(sdf) < vol.trunc
            ui, vi = u[sel][near].astype(np.int64), v[sel][near].astype(np.int64)
            flat_c[gid[near]] += dm.color[vi, ui].astype(np.float32)
            flat_n[gid[near]] += 1
    return vol


@dataclass
class Mesh:
    vertices: np.ndarray  # (V, 3) world meters
    faces: np.ndarray  # (F, 3) uint32
    normals: np.ndarray  # (V, 3), pointing out of the surface toward where it was seen from
    colors: np.ndarray  # (V, 3) uint8 RGB


def mesh(vol: Volume) -> Mesh:
    observed = vol.weight > 0
    verts, faces, normals, _ = marching_cubes(
        vol.tsdf,
        level=0.0,
        spacing=(vol.voxel,) * 3,
        mask=observed,
        allow_degenerate=False,
        gradient_direction="ascent",
    )
    verts = verts + vol.origin
    idx, _ = vol.ijk(verts)
    n = vol.color_n[idx[:, 0], idx[:, 1], idx[:, 2]]
    bgr = vol.color[idx[:, 0], idx[:, 1], idx[:, 2]] / np.maximum(n, 1)[:, None]
    rgb = np.where(n[:, None] > 0, bgr[:, ::-1], 128).clip(0, 255).astype(np.uint8)
    # With gradient_direction="ascent" the normals point from negative (inside) to positive (seen).
    return Mesh(verts.astype(np.float32), faces.astype(np.uint32), normals.astype(np.float32), rgb)
