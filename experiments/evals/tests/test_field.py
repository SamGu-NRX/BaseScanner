"""Hand-computed cases for the field-session pipeline, on a synthetic session and survey.

Scene (ARKit world, y up): a wall in the plane z = 0 facing +z, ground at y = 0. Ground contacts
at (0, 0, 0) and (6, 0, 0), a meter on the wall at (2, 1.5, 0), a fence foot at (3, 0, 3). One
keyframe at (3, 1.5, 8) looking along -z with fx = fy = 500 and centre (320, 240) sees all four.
"""

import hashlib
import json
import zipfile

import cv2
import numpy as np
import pytest

from evals import field
from evals.field import rotated_K, upright_turns

FT = 0.3048
CAMERA = np.array([3.0, 1.5, 8.0])
POINTS = {
    "p1": np.array([0.0, 0.0, 0.0]),
    "p2": np.array([6.0, 0.0, 0.0]),
    "p3": np.array([2.0, 1.5, 0.0]),
    "p4": np.array([3.0, 0.0, 3.0]),
}


def _pixel(X):
    """Continuous pixel of a world point in the keyframe (identity rotation, camera at CAMERA)."""
    x, y, z = X - CAMERA
    return [320 + 500 * x / -z, 240 - 500 * y / -z], -z


def _session():
    taps, points = [], []
    for i, (pid, X) in enumerate(POINTS.items()):
        pixel, _ = _pixel(X)
        taps.append({"id": f"t{i}", "keyframe": "k00001", "pixel": pixel, "point": pid})
        points.append({"id": pid, "kind": "ground", "position": X.tolist(), "taps": [f"t{i}"]})
    pose = np.eye(4)
    pose[:3, 3] = CAMERA

    def m(mid, a, b, key, value, ref=None):
        return {
            "id": mid,
            "time": 100.0,
            "from": a,
            "to": b,
            "referenceWall": ref,
            "values": {key: value},
            "compared": key,
            "accepted": True,
        }

    # The rig reads 2% short on every value.
    return {
        "format": "measure-lab-session",
        "formatVersion": 2,
        "units": {"length": "meters"},
        "session": {"id": "synthetic-field", "startedAtUptime": 40.0},
        "keyframes": [
            {
                "id": "k00001",
                "img": "keyframes/k00001.jpg",
                "w": 640,
                "h": 480,
                "intrinsics": [500.0, 500.0, 320.0, 240.0],
                "pose": pose.T.reshape(-1).tolist(),
                "timestamp": 50.0,
            }
        ],
        "taps": taps,
        "points": points,
        "walls": [{"id": "w1", "contacts": ["p1", "p2"], "cameraPosition": CAMERA.tolist()}],
        "measurements": [
            m("m1", "p1", "p2", "alongWall", 6 * 0.98, "w1"),
            m("m2", "p3", "w1", "heightAboveGround", 1.5 * 0.98),
            m("m3", "p4", "w1", "gapToWall", 3 * 0.98),
            m("m4", "p3", "p1", "straight", 2.5 * 0.98),
        ],
        "refusals": [],
    }


def _depth(scale):
    """The keyframe's depth: true z-depth x scale in a small patch around each tapped pixel."""
    d = np.full((480, 640), np.nan)
    for X in POINTS.values():
        (u, v), z = _pixel(X)
        cu, cv_ = int(u - 0.5), int(v - 0.5)
        d[cv_ - 2 : cv_ + 3, cu - 2 : cu + 3] = z * scale
    return d


@pytest.fixture
def case(tmp_path, monkeypatch):
    monkeypatch.setattr(field, "FIELD_DIR", tmp_path / "field")
    session = _session()
    folder = tmp_path / "synthetic-field"
    (folder / "keyframes").mkdir(parents=True)
    (folder / "session.json").write_text(json.dumps(session))
    noise = np.random.default_rng(0).integers(0, 255, (480, 640), np.uint8)
    cv2.imwrite(str(folder / "keyframes" / "k00001.jpg"), noise)
    archive = tmp_path / "session.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for f in sorted(folder.rglob("*")):
            z.write(f, f.relative_to(tmp_path))
    capture = hashlib.sha256(archive.read_bytes()).hexdigest()
    # MoGe-2's output, as the runner writes it, reading 10% long (turns 0: already upright).
    work = tmp_path / "field" / "work" / "synthetic-field"
    (work / "moge2").mkdir(parents=True)
    (work / "turns.json").write_text(json.dumps({"k00001": 0}))
    np.savez(
        work / "moge2" / "k00001.npz",
        depth=_depth(1.1).astype(np.float32),
        valid=np.isfinite(_depth(1.1)),
        intrinsics=np.array([500.0, 500.0, 319.5, 239.5]),
    )

    def measured(mid, meters):
        return {
            "id": mid,
            "candidate": None,
            "from": "a",
            "to": "b",
            "status": "measured",
            "value_ft": round(meters / FT, 6),
            "plus_minus_ft": 0.01,
            "method": "tape",
            "measured_by": ["s"],
        }

    truth = {
        "format": 1,
        "unit": "ft",
        "house": "synthetic",
        "captures": [capture],
        "scale_reference": "scale",
        "candidates": [],
        "measurements": [
            measured("scale", 2.5),
            measured("wall-length", 6.0),
            measured("meter-height", 1.5),
            measured("facing", 3.0),
            {
                "id": "pool",
                "candidate": None,
                "from": "a",
                "to": "b",
                "status": "absent",
                "method": "look",
                "measured_by": ["s"],
            },
        ],
        "checks": [],
    }
    mapping = {
        "format": 1,
        "unit": "ft",
        "pipeline": "measure-lab",
        "session": "synthetic-field",
        "plus_minus_ft_by_key": {"straight": 0.3},
        "measurements": {
            "scale": {"session_measurement": "m4", "key": "straight"},
            "wall-length": {"session_measurement": "m1", "key": "alongWall"},
            "meter-height": {"session_measurement": "m2", "key": "heightAboveGround"},
            "facing": {"session_measurement": "m3", "key": "gapToWall"},
            "pool": "absent",
        },
    }
    paths = {}
    for name, doc in (("truth", truth), ("map", mapping), ("rules", {"format": 1})):
        paths[name] = tmp_path / f"{name}.json"
        paths[name].write_text(json.dumps(doc))
    return archive, paths, capture, tmp_path / "results"


def _values(doc):
    return {m["id"]: m["value_ft"] for m in doc["measurements"]}


def test_rows_recompute_the_rigs_measurements_from_depth(case):
    archive, paths, capture, out = case
    report = field.score(archive, paths["truth"], paths["map"], paths["rules"], out)
    native = json.loads((out / "moge2.json").read_text())
    tape = json.loads((out / "moge2-tape.json").read_text())
    tri = json.loads((out / "moge2-triangulated.json").read_text())
    # Depth 10% long, scaled about the camera: every length comes out 10% long.
    expected = {"wall-length": 6.0, "meter-height": 1.5, "facing": 3.0}
    for k, meters in expected.items():
        assert _values(native)[k] == pytest.approx(1.1 * meters / FT, abs=1e-5)
        # The taped 2.5 m scale reference undoes the 10% exactly.
        assert _values(tape)[k] == pytest.approx(meters / FT, abs=1e-5)
    # One keyframe has no neighbours to triangulate with, so every value fails.
    assert all(m.get("missing") == "failed" for m in tri["measurements"] if m["id"] != "pool")
    # Format: capture id, no scale reference row, absent kept, no uncertainty, no decisions.
    assert native["capture"] == capture and native["outcomes"] is None
    assert "scale" not in _values(native)
    assert {"id": "pool", "value_ft": None, "missing": "absent"} in native["measurements"]
    assert all(m.get("plus_minus_ft") is None for m in native["measurements"])
    assert native["timing"]["capture_s"] == 60.0
    assert native["rules_sha256"] == hashlib.sha256(paths["rules"].read_bytes()).hexdigest()
    # AR scale error: the rig read 2% short on the only span of 10 ft or more (the 6 m wall).
    assert "AR scale error: -2.0% (median over 1 spans" in report


@pytest.mark.parametrize("turns", [0, 1, 2, 3])
def test_rotated_K_follows_np_rot90(turns):
    K = np.array([[500.0, 0, 300.0], [0, 510.0, 200.0], [0, 0, 1]])
    w, h = 640, 480
    img = np.zeros((h, w))
    img[150, 400] = 1  # pixel (u, v) = (400, 150)
    rot = np.rot90(img, turns)
    v2, u2 = np.argwhere(rot == 1)[0]
    # The same ray in the turned camera: turning the image turns the camera about its axis.
    x, y = (400 - 300) / 500, (150 - 200) / 510
    x2, y2 = {0: (x, y), 1: (y, -x), 2: (-x, -y), 3: (-y, x)}[turns]
    Kr = rotated_K(K, w, h, turns)
    assert Kr[0, 0] * x2 + Kr[0, 2] == pytest.approx(u2)
    assert Kr[1, 1] * y2 + Kr[1, 2] == pytest.approx(v2)


def test_upright_turns_for_a_portrait_phone():
    # ARKit identity pose: the landscape image is already upright (0 turns). Rolled a quarter turn
    # so world up points to image right, one counter-clockwise turn (1) puts it on top; rolled the
    # other way, as a phone held upright in portrait is, one clockwise turn (3) does.
    T = np.eye(4)
    T[:3, :3] = np.diag([1.0, -1.0, -1.0])  # OpenCV axes of the ARKit identity pose
    assert upright_turns(T) == 0
    roll = np.array([[0.0, -1, 0], [1, 0, 0], [0, 0, 1]])  # camera +x now points world up
    T[:3, :3] = roll @ np.diag([1.0, -1.0, -1.0])
    assert upright_turns(T) == 1
    T[:3, :3] = roll.T @ np.diag([1.0, -1.0, -1.0])
    assert upright_turns(T) == 3
