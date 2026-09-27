"""Write a packet: files with their sizes and hashes, CSV streams, the manifest.

The sample builders and the test fixture go through this, so every packet they produce is
described by the same code the validator checks.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import shutil
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

from packet.validate import STREAM_COLUMNS

PACKET_VERSION = "1.1"
SHARPNESS_METHOD = "laplacian_variance_luma_640"


class PacketWriter:
    def __init__(self, folder: Path):
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
        self.folder = folder

    def add_bytes(self, path: str, data: bytes) -> dict:
        target = self.folder / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return {"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    def add_file(self, path: str, source: Path) -> dict:
        """Copy a file in unchanged (an original photo keeps its bytes)."""
        target = self.folder / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        digest = hashlib.sha256()
        with target.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
        return {"path": path, "bytes": target.stat().st_size, "sha256": digest.hexdigest()}

    def add_stream(self, name: str, rows: list[list], rate_hz: float | None = None) -> dict:
        buf = io.StringIO()
        out = csv.writer(buf, lineterminator="\n")
        out.writerow(STREAM_COLUMNS[name])
        out.writerows(rows)
        ref = self.add_bytes(f"streams/{name}.csv", buf.getvalue().encode())
        ref["rows"] = len(rows)
        if rate_hz is not None:
            ref["nominal_rate_hz"] = rate_hz
        return ref

    def add_depth(
        self,
        name: str,
        depth: np.ndarray,
        confidence: np.ndarray | None = None,
        sigma: np.ndarray | None = None,
        folder: str = "depth",
    ) -> dict:
        h, w = depth.shape
        ref = {
            "map": self.add_bytes(f"{folder}/{name}.f32", depth.astype("<f4").tobytes()),
            "width": w,
            "height": h,
        }
        if confidence is not None:
            conf = confidence.astype(np.uint8).tobytes()
            ref["confidence"] = self.add_bytes(f"{folder}/{name}.conf.u8", conf)
        if sigma is not None:
            ref["sigma"] = self.add_bytes(
                f"{folder}/{name}.sigma.f32", sigma.astype("<f4").tobytes()
            )
        return ref

    def finish(self, manifest: dict, zip_too: bool = False) -> Path:
        (self.folder / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
        if not zip_too:
            return self.folder
        archive = self.folder.with_suffix(".zip")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_STORED) as z:
            for p in sorted(self.folder.rglob("*")):
                if p.is_file():
                    z.write(p, f"{self.folder.name}/{p.relative_to(self.folder).as_posix()}")
        return archive


# --- Photo measurements -------------------------------------------------------------------------


def sharpness(image: Image.Image) -> float:
    """Variance of the 4-neighbour Laplacian of the luma, after scaling the long side to 640 px
    (bilinear; images already smaller are used as they are). README.md fixes this method so scores
    compare across phones and resolutions."""
    luma = image.convert("L")
    scale = 640 / max(luma.size)
    if scale < 1:
        size = (round(luma.width * scale), round(luma.height * scale))
        luma = luma.resize(size, Image.Resampling.BILINEAR)
    a = np.asarray(luma, dtype=np.float64)
    lap = a[1:-1, :-2] + a[1:-1, 2:] + a[:-2, 1:-1] + a[2:, 1:-1] - 4 * a[1:-1, 1:-1]
    return float(lap.var())


# --- Frames and poses ---------------------------------------------------------------------------


def column_major(m: np.ndarray) -> list[float]:
    return [float(v) for v in np.asarray(m).T.reshape(-1)]


def from_column_major(pose: list[float]) -> np.ndarray:
    return np.asarray(pose, dtype=np.float64).reshape(4, 4).T


def orthonormalize(m: np.ndarray) -> np.ndarray:
    """The nearest rotation to a rounded one (SVD), keeping the translation."""
    u, _, vt = np.linalg.svd(m[:3, :3])
    out = m.copy()
    out[:3, :3] = u @ np.diag([1.0, 1.0, np.linalg.det(u @ vt)]) @ vt
    return out


def meter_frame(meter_world: np.ndarray, wall_along_world: np.ndarray) -> np.ndarray:
    """Meter-to-world pose: origin at the meter, +y up (world +y, gravity aligned), +x along the
    wall to the right as seen from outside, +z out of the wall toward the homeowner."""
    x = np.array([wall_along_world[0], 0.0, wall_along_world[2]])
    x /= np.linalg.norm(x)
    y = np.array([0.0, 1.0, 0.0])
    z = np.cross(x, y)
    t = np.eye(4)
    t[:3, 0], t[:3, 1], t[:3, 2], t[:3, 3] = x, y, z, meter_world
    return t


def quaternion_xyzw(r: np.ndarray) -> list[float]:
    """Unit quaternion (x, y, z, w) of a rotation matrix, w >= 0."""
    m = r
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = 2 * np.sqrt(tr + 1)
        q = [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, s / 4]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = 2 * np.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2])
        q = [s / 4, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    elif m[1, 1] > m[2, 2]:
        s = 2 * np.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2])
        q = [(m[0, 1] + m[1, 0]) / s, s / 4, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    else:
        s = 2 * np.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1])
        q = [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, s / 4, (m[1, 0] - m[0, 1]) / s]
    q = np.asarray(q)
    q /= np.linalg.norm(q)
    return [float(v) for v in (q if q[3] >= 0 else -q)]


def trajectory_row(t: float, tracking: str, pose: np.ndarray, digits: int = 6) -> list:
    p, q = pose[:3, 3], quaternion_xyzw(pose[:3, :3])
    return [round(t, 6), tracking, *(round(float(v), digits) for v in p), *(round(v, 7) for v in q)]
