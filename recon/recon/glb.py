"""A binary glTF 2.0 (.glb) of a colored triangle mesh, viewable in macOS Quick Look.

glTF is y-up, right-handed and in meters, the same as ARKit's world, so vertices go in unchanged.
Vertex colors are normalized unsigned bytes, the smallest form glTF allows.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np

GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942
ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER = 34962, 34963
FLOAT, UNSIGNED_BYTE, UNSIGNED_INT = 5126, 5121, 5125


def _pad(b: bytes, fill: bytes) -> bytes:
    return b + fill * ((4 - len(b) % 4) % 4)


def write_glb(
    path: Path,
    vertices: np.ndarray,
    faces: np.ndarray,
    colors: np.ndarray,
    normals: np.ndarray | None = None,
) -> None:
    v = np.ascontiguousarray(vertices, np.float32)
    f = np.ascontiguousarray(faces, np.uint32)
    c = np.ascontiguousarray(np.c_[colors, np.full(len(colors), 255)], np.uint8)
    if len(v) == 0 or len(f) == 0:
        raise ValueError("empty mesh: nothing to write")
    if f.max() >= len(v) or len(c) != len(v):
        raise ValueError("faces index past the vertices, or colors do not match vertices")
    parts = [
        ("POSITION", v.tobytes(), FLOAT, "VEC3", True),
        ("COLOR_0", c.tobytes(), UNSIGNED_BYTE, "VEC4", False),
    ]
    if normals is not None:
        n = np.ascontiguousarray(normals, np.float32)
        n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
        parts.append(("NORMAL", n.tobytes(), FLOAT, "VEC3", False))
    blob, views, accessors, attributes = b"", [], [], {}
    for name, data, ctype, kind, bounds in parts:
        views.append(
            {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data), "target": ARRAY_BUFFER}
        )
        acc = {"bufferView": len(views) - 1, "componentType": ctype, "count": len(v), "type": kind}
        if ctype == UNSIGNED_BYTE:
            acc["normalized"] = True
        if bounds:
            acc["min"], acc["max"] = v.min(axis=0).tolist(), v.max(axis=0).tolist()
        accessors.append(acc)
        attributes[name] = len(accessors) - 1
        blob = _pad(blob + data, b"\0")
    views.append(
        {
            "buffer": 0,
            "byteOffset": len(blob),
            "byteLength": f.nbytes,
            "target": ELEMENT_ARRAY_BUFFER,
        }
    )
    accessors.append(
        {
            "bufferView": len(views) - 1,
            "componentType": UNSIGNED_INT,
            "count": f.size,
            "type": "SCALAR",
        }
    )
    blob = _pad(blob + f.tobytes(), b"\0")
    doc = {
        "asset": {"version": "2.0", "generator": "house-scanning recon"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [
            {"primitives": [{"attributes": attributes, "indices": len(accessors) - 1, "mode": 4}]}
        ],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accessors,
    }
    js = _pad(json.dumps(doc, separators=(",", ":")).encode(), b" ")
    total = 12 + 8 + len(js) + 8 + len(blob)
    with path.open("wb") as fh:
        fh.write(struct.pack("<III", GLB_MAGIC, 2, total))
        fh.write(struct.pack("<II", len(js), JSON_CHUNK) + js)
        fh.write(struct.pack("<II", len(blob), BIN_CHUNK) + blob)


def read_glb(path: Path) -> tuple[dict, bytes]:
    """The JSON document and binary chunk of a .glb, for checks."""
    data = path.read_bytes()
    magic, version, total = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC or version != 2 or total != len(data):
        raise ValueError(f"{path}: not a glTF 2.0 binary")
    jlen, _ = struct.unpack_from("<II", data, 12)
    doc = json.loads(data[20 : 20 + jlen])
    blen, _ = struct.unpack_from("<II", data, 20 + jlen)
    return doc, data[28 + jlen : 28 + jlen + blen]
