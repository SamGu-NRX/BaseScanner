"""Hand-computed cases for the field-session pipeline, on a synthetic session and survey.

Scene (ARKit world, y up): a wall in the plane z = 0 facing +z, ground at y = 0. Ground contacts
at (0, 0, 0) and (10, 0, 0), a meter on the wall at (2, 1.5, 0), a fence foot at (3, 0, 3). Two
keyframes look along -z with fx = fy = 500 and centre (320, 240): k00001 at (3, 1.5, 12) taps the
first contact and the fence foot, k00002 at (6, 1.5, 12) taps the second contact and the meter.
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
CAMERAS = {"k00001": np.array([3.0, 1.5, 12.0]), "k00002": np.array([6.0, 1.5, 12.0])}
POINTS = {
    "p1": np.array([0.0, 0.0, 0.0]),
    "p2": np.array([10.0, 0.0, 0.0]),
    "p3": np.array([2.0, 1.5, 0.0]),
    "p4": np.array([3.0, 0.0, 3.0]),
}
TAPPED_FROM = {"p1": "k00001", "p4": "k00001", "p2": "k00002", "p3": "k00002"}


def _pixel(X, kid):
    """Continuous pixel of a world point in a keyframe (identity rotation)."""
    x, y, z = X - CAMERAS[kid]
    return [320 + 500 * x / -z, 240 - 500 * y / -z], -z


def _session():
    taps, points = [], []
    for i, (pid, X) in enumerate(POINTS.items()):
        pixel, _ = _pixel(X, TAPPED_FROM[pid])
        taps.append({"id": f"t{i}", "keyframe": TAPPED_FROM[pid], "pixel": pixel, "point": pid})
        points.append({"id": pid, "kind": "ground", "position": X.tolist(), "taps": [f"t{i}"]})

    def keyframe(kid):
        pose = np.eye(4)
        pose[:3, 3] = CAMERAS[kid]
        return {
            "id": kid,
            "img": f"keyframes/{kid}.jpg",
            "w": 640,
            "h": 480,
            "intrinsics": [500.0, 500.0, 320.0, 240.0],
            "pose": pose.T.reshape(-1).tolist(),
            "timestamp": 50.0,
        }

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
        "keyframes": [keyframe(k) for k in CAMERAS],
        "taps": taps,
        "points": points,
        "walls": [
            {"id": "w1", "contacts": ["p1", "p2"], "cameraPosition": CAMERAS["k00001"].tolist()}
        ],
        "measurements": [
            m("m1", "p1", "p2", "alongWall", 10 * 0.98, "w1"),
            m("m2", "p3", "w1", "heightAboveGround", 1.5 * 0.98),
            m("m3", "p4", "w1", "gapToWall", 3 * 0.98),
            m("m4", "p3", "p1", "straight", 2.5 * 0.98),
        ],
        "refusals": [],
    }


def _depth(kid, scale):
    """A keyframe's depth: true z-depth x scale in a small patch around each pixel it taps."""
    d = np.full((480, 640), np.nan)
    for pid, X in POINTS.items():
        if TAPPED_FROM[pid] != kid:
            continue
        (u, v), z = _pixel(X, kid)
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
    for kid in CAMERAS:
        cv2.imwrite(str(folder / "keyframes" / f"{kid}.jpg"), noise)
    archive = tmp_path / "session.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for f in sorted(folder.rglob("*")):
            z.write(f, f.relative_to(tmp_path))
    capture = hashlib.sha256(archive.read_bytes()).hexdigest()
    # MoGe-2's output, as the runner writes it, reading 10% long (turns 0: already upright).
    work = tmp_path / "field" / "work" / "synthetic-field"
    (work / "moge2").mkdir(parents=True)
    (work / "turns.json").write_text(json.dumps(dict.fromkeys(CAMERAS, 0)))
    (work / "capture.json").write_text(json.dumps({"capture": capture}))
    for kid in CAMERAS:
        np.savez(
            work / "moge2" / f"{kid}.npz",
            depth=_depth(kid, 1.1).astype(np.float32),
            valid=np.isfinite(_depth(kid, 1.1)),
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
            measured("wall-length", 10.0),
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
    # Depth 10% long, each keyframe scaling about its own camera: the first contact (from k00001 at
    # x = 3) lands at x = 3 - 1.1 * 3 = -0.3, the second (from k00002 at x = 6) at 6 + 1.1 * 4 =
    # 10.4, so the wall reads 10.7 m, not 11.0. The meter and the fence keep a 10% error against
    # a wall that moved with them: heights and gaps scale about the camera the same way.
    assert _values(native)["wall-length"] == pytest.approx(10.7 / FT, abs=1e-5)
    # The taped 2.5 m reference joins taps on different keyframes; solving along the rays gives
    # depth x 1/1.1, which puts every point back (to float32 depth storage, about 0.01 mm); a
    # length ratio would leave the wall about 1 in off.
    for k, meters in {"wall-length": 10.0, "meter-height": 1.5, "facing": 3.0}.items():
        assert _values(tape)[k] == pytest.approx(meters / FT, abs=1e-4)
    # Each keyframe's only neighbour shares no texture with it, so triangulation fits nothing.
    assert all(m.get("missing") == "failed" for m in tri["measurements"] if m["id"] != "pool")
    # Format: capture id, no scale reference row, absent kept, no uncertainty, no decisions.
    assert native["capture"] == capture and native["outcomes"] is None
    assert "scale" not in _values(native)
    assert {"id": "pool", "value_ft": None, "missing": "absent"} in native["measurements"]
    assert all(m.get("plus_minus_ft") is None for m in native["measurements"])
    assert native["timing"]["capture_s"] == 60.0
    assert native["rules_sha256"] == hashlib.sha256(paths["rules"].read_bytes()).hexdigest()
    # AR scale: the rig read 2% short on the only accepted straight span of 29 ft or more, the
    # 32.8 ft wall. Its bound: 1.96 * hypot(2 in, 0.01 ft) / 32.81 ft = 1.00%, so 2% is not decided.
    assert "AR scale error: -2.00% ± 1.00% (95%, 1 spans, longest 32.8 ft" in report
    assert "Within 2%: cannot tell." in report


def test_scale_report_skips_measurements_the_rig_did_not_accept(case):
    archive, paths, _, _ = case
    session = field.load_session(archive.parent / "synthetic-field")
    session["measurements"][0]["accepted"] = False  # the wall span
    lines = field.ar_scale_report(
        session, json.loads(paths["truth"].read_text()), json.loads(paths["map"].read_text()), 2.0
    )
    assert any("no: the rig did not accept it" in x for x in lines)
    assert lines[-1].startswith("AR scale error: not resolved")


def test_fit_scale_weights_long_spans():
    # Spans of 30 ft and 10 ft, each with 1 in of error: 30 ft read 1% short, 10 ft 10% short.
    # Weighted by t^2: scale = (29.7*30 + 9*10) / (900 + 100) = 0.981.
    est = field.fit_scale(np.array([29.7, 9.0]), np.array([30.0, 10.0]), np.full(2, 1 / 12))
    assert est.scale == pytest.approx(0.981)
    assert est.bound == pytest.approx(1.96 / np.sqrt(1000 * 144))
    assert field.within(1.0, 0.5, 2.0) == "yes"
    assert field.within(3.0, 0.5, 2.0) == "no"
    assert field.within(1.8, 0.5, 2.0) == "cannot tell"


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


@pytest.mark.parametrize(
    ("text", "feet"),
    [("30 0 1/8", 30.010417), ("4 11", 4.916667), ("12", 12.0), ("0", 0.0), ("2 3/4", 2.0625)],
)
def test_parse_tape_reads_feet_inches_fraction(text, feet):
    # "2 3/4" is 2 ft and 3/4 in.
    assert field.parse_tape(text) == pytest.approx(feet, abs=1e-6)


@pytest.mark.parametrize("text", ["30 12", "FILL ft in", "", "3 4 1/2 x"])
def test_parse_tape_refuses_what_it_cannot_read(text):
    with pytest.raises(ValueError):
        field.parse_tape(text)


def test_stamp_fills_in_capture_session_and_feet(case, tmp_path):
    archive, paths, capture, out = case
    survey = json.loads(paths["truth"].read_text())
    survey["captures"] = []
    survey["measurements"][1]["value_ft"] = "32 9 3/4"
    paths["truth"].write_text(json.dumps(survey))
    mapping = json.loads(paths["map"].read_text())
    mapping["session"] = "placeholder"
    paths["map"].write_text(json.dumps(mapping))
    stamped = field.stamp(archive, paths["truth"], paths["map"], out)
    survey = json.loads(paths["truth"].read_text())
    assert survey["captures"] == [capture]
    assert survey["measurements"][1]["value_ft"] == pytest.approx(32 + 9.75 / 12, abs=1e-6)
    assert json.loads(stamped.read_text())["session"] == "synthetic-field"
    # Idempotent: a second stamp adds nothing.
    field.stamp(archive, paths["truth"], paths["map"], out)
    assert json.loads(paths["truth"].read_text())["captures"] == [capture]


@pytest.mark.parametrize("text", ["30 2 5", "30 1/4 2", "1 1/0", "1/2", "30 -2"])
def test_parse_tape_refuses_partial_or_misordered_readings(text):
    # "30 2 5" would drop the 5; "30 1/4 2" would read the fraction as inches then drop it.
    with pytest.raises(ValueError):
        field.parse_tape(text)


@pytest.mark.parametrize("bad", ["../escape", "/abs", "..", "a/b", "", "sp ace"])
def test_safe_id_refuses_path_components(bad):
    with pytest.raises(ValueError):
        field.safe_id(bad, "session id")
    assert field.safe_id("synthetic-field_1.2", "session id") == "synthetic-field_1.2"


def test_session_file_stays_inside_the_session(tmp_path):
    (tmp_path / "keyframes").mkdir()
    (tmp_path / "keyframes" / "k.jpg").write_bytes(b"x")
    assert (
        field.session_file(tmp_path, "keyframes/k.jpg")
        == (tmp_path / "keyframes" / "k.jpg").resolve()
    )
    for bad in ["/etc/hosts", "../outside.jpg", "keyframes/../../outside.jpg"]:
        with pytest.raises(ValueError):
            field.session_file(tmp_path, bad)


def test_score_refuses_predictions_prepared_for_another_capture(case):
    archive, paths, _, out = case
    stamp = field.FIELD_DIR / "work" / "synthetic-field" / "capture.json"
    stamp.write_text(json.dumps({"capture": "0" * 64}))  # same session id, different archive
    with pytest.raises(ValueError, match="prepared for another capture"):
        field.score(archive, paths["truth"], paths["map"], paths["rules"], out)


def test_score_refuses_a_map_for_another_session(case):
    archive, paths, _, out = case
    mapping = json.loads(paths["map"].read_text())
    mapping["session"] = "some-other-session"
    paths["map"].write_text(json.dumps(mapping))
    with pytest.raises(ValueError, match="map is for session"):
        field.score(archive, paths["truth"], paths["map"], paths["rules"], out)


def test_a_failed_tape_reference_fails_only_the_tape_row(case, monkeypatch):
    archive, paths, _, out = case

    def no_scale(*args, **kwargs):
        raise ValueError("no model depth at a reference tap")

    monkeypatch.setattr(field, "tape_scale", no_scale)
    report = field.score(archive, paths["truth"], paths["map"], paths["rules"], out)
    assert "every value failed" in report
    tape_row = json.loads((out / "moge2-tape.json").read_text())
    assert all(m["value_ft"] is None for m in tape_row["measurements"])
    native = json.loads((out / "moge2.json").read_text())
    assert any(m["value_ft"] is not None for m in native["measurements"])
