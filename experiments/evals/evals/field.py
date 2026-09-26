"""Learned-depth rows and the AR scale error for one Measure Lab field session.

    uv run python -m evals.field prepare SESSION.zip           # upright keyframes for MoGe-2
    (MoGe-2 on those keyframes: see the Makefile target `field`)
    uv run python -m evals.field score SESSION.zip [--truth survey.json --map map.json --rules rules.json]

Every point the rig made from taps (ground, wall and two-view points) gets a second position from
learned depth: MoGe-2's depth at the tapped pixel of the tapped keyframe, back-projected with that
keyframe's AR pose. Walls and measurement values are then recomputed exactly as Measure Lab
computes them (`Wall.swift`, `Measurements.swift`), so each survey measurement the team's map ties
to a session measurement gets a learned-depth value for the same quantity. Three rows:

- `moge2`: MoGe-2's own metric scale.
- `moge2-triangulated`: each keyframe's depth rescaled to features triangulated with the session's
  AR poses across it and its 7 nearest keyframes (`evals.triangulate`, method (b) of
  `evals.pose_priors`).
- `moge2-tape`: one scale for the whole session, making the survey's scale reference come out at
  its taped length (only if the map ties the scale reference to a session measurement).

Rows are written as scoring-harness results files (experiments/scoring/README.md on
t3/scoring-harness). They state no uncertainty (`plus_minus_ft` null) because no error bar for them
has been validated, so they make no decisions. The AR scale error is the rig's own values against
the tape, over spans of at least 10 ft, where scale dominates tapping error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import zipfile
from pathlib import Path

import cv2
import numpy as np

from evals.paths import EVALS_DIR
from evals.recon import camera_points, load_prediction
from evals.triangulate import view_scales

FEET = 0.3048
UP = np.array([0.0, 1.0, 0.0])
ARKIT_TO_OPENCV = np.diag([1.0, -1.0, -1.0])
NEIGHBOURS = 7
SCALE_SPAN_MIN_FT = 10.0
SCALE_KEYS = ("straight", "horizontal", "alongWall")
FIELD_DIR = EVALS_DIR / "field"


# --- Session ---------------------------------------------------------------------------------


def unpack(session: Path) -> tuple[Path, str | None]:
    """The session folder, and the zip's sha256 (the scoring harness's capture id) if zipped."""
    if session.is_dir():
        return session, None
    digest = hashlib.sha256(session.read_bytes()).hexdigest()
    out = FIELD_DIR / digest[:16]
    with zipfile.ZipFile(session) as z:
        names = [n for n in z.namelist() if not n.startswith("__MACOSX/")]
        roots = [n for n in names if n.split("/")[-1] == "session.json" and n.count("/") <= 1]
        if len(roots) != 1:
            raise ValueError(f"{session}: expected one session.json, found {roots}")
        if not (out / roots[0]).exists():
            z.extractall(out, members=names)
    return (out / roots[0]).parent, digest


def load_session(folder: Path) -> dict:
    data = json.loads((folder / "session.json").read_text())
    if data.get("format") != "measure-lab-session" or data.get("formatVersion") != 2:
        raise ValueError(f"{folder}: not a Measure Lab session, format 2")
    return data


def keyframe_pose_cv(kf: dict) -> np.ndarray:
    """Camera-to-world with OpenCV camera axes, from the session's ARKit pose (column-major)."""
    T = np.array(kf["pose"], dtype=np.float64).reshape(4, 4).T
    T[:3, :3] = T[:3, :3] @ ARKIT_TO_OPENCV
    return T


def keyframe_K_cv(kf: dict) -> np.ndarray:
    """Intrinsics with OpenCV's integer pixel centres (the session's are continuous)."""
    fx, fy, cx, cy = kf["intrinsics"]
    return np.array([[fx, 0, cx - 0.5], [0, fy, cy - 0.5], [0, 0, 1.0]])


# --- Upright images for the model ------------------------------------------------------------


def upright_turns(T_cv: np.ndarray) -> int:
    """np.rot90 turns (counter-clockwise) that put world up at the top of this keyframe's image.

    Session images are unrotated sensor images, sideways for a phone held upright, and depth
    models are trained on upright photos."""
    up = T_cv[:3, :3].T @ UP  # world up in OpenCV camera axes; image "up" is -y
    x, y = up[0], -up[1]
    if abs(y) >= abs(x):
        return 0 if y > 0 else 2
    return 1 if x > 0 else 3


def rotated_K(K: np.ndarray, w: int, h: int, turns: int) -> np.ndarray:
    """Intrinsics of the image turned by np.rot90(image, turns), for a w x h original."""
    fx, fy, cx, cy = K[0, 0], K[1, 1], K[0, 2], K[1, 2]
    new = {
        0: (fx, fy, cx, cy),
        1: (fy, fx, cy, w - 1 - cx),
        2: (fx, fy, w - 1 - cx, h - 1 - cy),
        3: (fy, fx, h - 1 - cy, cx),
    }[turns % 4]
    return np.array([[new[0], 0, new[2]], [0, new[1], new[3]], [0, 0, 1.0]])


def work_dir(folder: Path) -> Path:
    return FIELD_DIR / "work" / load_session(folder)["session"]["id"]


def prepare(folder: Path) -> Path:
    """Upright copies of every keyframe plus the model runner's image list and intrinsics."""
    session = load_session(folder)
    out = work_dir(folder)
    (out / "upright").mkdir(parents=True, exist_ok=True)
    listing, intrinsics, turns = [], {}, {}
    for kf in session["keyframes"]:
        img = cv2.imread(str(folder / kf["img"]))
        if img is None:
            raise FileNotFoundError(folder / kf["img"])
        k = upright_turns(keyframe_pose_cv(kf))
        path = out / "upright" / f"{kf['id']}.jpg"
        cv2.imwrite(str(path), np.rot90(img, k), [cv2.IMWRITE_JPEG_QUALITY, 95])
        Kr = rotated_K(keyframe_K_cv(kf), img.shape[1], img.shape[0], k)
        listing.append(str(path))
        intrinsics[str(path)] = [Kr[0, 0], Kr[1, 1], Kr[0, 2], Kr[1, 2]]
        turns[kf["id"]] = k
    (out / "images.txt").write_text("\n".join(listing) + "\n")
    (out / "intrinsics.json").write_text(json.dumps(intrinsics, indent=1))
    (out / "turns.json").write_text(json.dumps(turns, indent=1))
    return out


def keyframe_depth(out: Path, kid: str, turns: int) -> np.ndarray:
    """MoGe-2's depth for a keyframe, turned back to the session's sensor orientation."""
    depth, _, _ = load_prediction(out / "moge2" / f"{kid}.npz")
    return np.rot90(depth, -turns)


# --- Scale per keyframe ------------------------------------------------------------------------


def neighbours(poses: dict[str, np.ndarray], kid: str, n: int = NEIGHBOURS) -> list[str]:
    """The keyframe and its n nearest keyframes looking the same way (within 60 degrees)."""
    T = poses[kid]
    fwd = T[:3, 2]
    near = [k for k in poses if k != kid and poses[k][:3, 2] @ fwd > 0.5]
    near.sort(key=lambda k: np.linalg.norm(poses[k][:3, 3] - T[:3, 3]))
    return [kid, *near[:n]]


def triangulated_scales(folder: Path, out: Path, session: dict, kids: list[str]) -> dict:
    """{keyframe: ScaleFit} for the given keyframes, each fitted within its neighbourhood."""
    kfs = {kf["id"]: kf for kf in session["keyframes"]}
    turns = json.loads((out / "turns.json").read_text())
    poses = {k: keyframe_pose_cv(kf) for k, kf in kfs.items()}
    cache: dict[str, tuple] = {}

    def inputs(k):
        if k not in cache:
            gray = cv2.imread(str(folder / kfs[k]["img"]), cv2.IMREAD_GRAYSCALE)
            cache[k] = (gray, keyframe_K_cv(kfs[k]), keyframe_depth(out, k, turns[k]))
        return cache[k]

    fits = {}
    for kid in kids:
        group = neighbours(poses, kid)
        if len(group) < 2:
            continue
        fits[kid] = view_scales(
            {k: inputs(k)[0] for k in group},
            {k: inputs(k)[1] for k in group},
            {k: poses[k] for k in group},
            {k: inputs(k)[2] for k in group},
        )[kid]
    return fits


# --- Points, walls, values (Measure Lab's definitions) ------------------------------------------


def tap_point(kf: dict, pixel: list[float], depth: np.ndarray, scale: float) -> np.ndarray:
    """World position of a tapped pixel from (scaled) depth; NaN if the depth there is invalid."""
    uv = np.array([[pixel[0] - 0.5, pixel[1] - 0.5]])  # continuous -> OpenCV pixel centres
    pc = camera_points(depth * scale, keyframe_K_cv(kf), uv)[0]
    T = keyframe_pose_cv(kf)
    return T[:3, :3] @ pc + T[:3, 3]


def learned_points(session: dict, depth_of, scale_of) -> dict[str, np.ndarray]:
    """{point id: position}, each the mean of its taps' depth-based positions."""
    kfs = {kf["id"]: kf for kf in session["keyframes"]}
    taps = {t["id"]: t for t in session["taps"]}
    out = {}
    for p in session["points"]:
        positions = []
        for tid in p["taps"]:
            tap = taps[tid]
            s = scale_of(tap["keyframe"])
            if s is None:
                positions.append(np.full(3, np.nan))
                continue
            positions.append(
                tap_point(kfs[tap["keyframe"]], tap["pixel"], depth_of(tap["keyframe"]), s)
            )
        out[p["id"]] = np.mean(positions, axis=0)
    return out


def wall_frame(c1: np.ndarray, c2: np.ndarray, camera: np.ndarray) -> dict:
    """Measure Lab's wall: direction u (horizontal c1 -> c2), normal u x up toward the camera."""
    run = c2 - c1
    run[1] = 0.0
    length = float(np.linalg.norm(run))
    u = run / length
    n = np.cross(u, UP)
    if n @ (camera - c1) < 0:
        n = -n
    return {"start": c1, "end": c2, "u": u, "n": n, "length": length}


def values(a: np.ndarray, target, reference: dict | None) -> dict[str, float]:
    """Measure Lab's `measuredValues`: point to point, or point to wall."""
    if isinstance(target, dict):
        w = target
        along = w["u"] @ (a - w["start"])
        ground = w["start"][1] + (w["end"][1] - w["start"][1]) * along / w["length"]
        return {"gapToWall": abs(w["n"] @ (a - w["start"])), "heightAboveGround": a[1] - ground}
    d = target - a
    out = {
        "straight": float(np.linalg.norm(d)),
        "horizontal": float(np.hypot(d[0], d[2])),
        "vertical": abs(float(d[1])),
    }
    if reference is not None:
        out["alongWall"] = abs(float(reference["u"] @ d))
    return out


def learned_values(session: dict, points: dict[str, np.ndarray]) -> dict[str, dict[str, float]]:
    """{session measurement id: values} recomputed from learned-depth points."""
    walls = {}
    for w in session["walls"]:
        c1, c2 = (points[c] for c in w["contacts"][:2])
        walls[w["id"]] = wall_frame(c1, c2, np.array(w["cameraPosition"], dtype=np.float64))
    out = {}
    for m in session["measurements"]:
        target = walls[m["to"]] if m["to"] in walls else points[m["to"]]
        reference = walls.get(m.get("referenceWall")) if m.get("referenceWall") else None
        out[m["id"]] = values(points[m["from"]], target, reference)
    return out


# --- Scoring-harness files --------------------------------------------------------------------


def feet(meters: float) -> float:
    return round(meters / FEET, 6)


def results_file(
    pipeline: str,
    scale_source: str,
    capture: str,
    rules_sha256: str,
    truth: dict,
    mapping: dict,
    recomputed: dict[str, dict[str, float]],
    capture_s: float | None,
    processing_s: float,
) -> dict:
    rows = []
    for m in truth["measurements"]:
        if m["id"] == truth["scale_reference"]:
            continue  # optional in a results file, and never scored
        entry = mapping["measurements"].get(m["id"])
        if entry in ("absent", "unsupported"):
            rows.append({"id": m["id"], "value_ft": None, "missing": entry})
        elif not isinstance(entry, dict) or "session_measurement" not in entry:
            # A rig refusal, or no entry: nothing this pipeline can recompute.
            rows.append({"id": m["id"], "value_ft": None, "missing": "unsupported"})
        else:
            v = recomputed[entry["session_measurement"]].get(entry["key"], np.nan)
            if not np.isfinite(v) or v < 0:
                rows.append({"id": m["id"], "value_ft": None, "missing": "failed"})
            else:
                rows.append({"id": m["id"], "value_ft": feet(v), "plus_minus_ft": None})
    return {
        "format": 1,
        "unit": "ft",
        "pipeline": pipeline,
        "capture": capture,
        "rules_sha256": rules_sha256,
        "scale_source": scale_source,
        "measurements": rows,
        "outcomes": None,
        "timing": {"capture_s": capture_s, "processing_s": round(processing_s, 3)},
    }


def capture_seconds(session: dict) -> float | None:
    """As the harness's importer computes it, so rows on one capture agree."""
    times = [m["time"] for m in session["measurements"]]
    if not times:
        return None
    return round(max(times) - session["session"]["startedAtUptime"], 3)


def ar_scale_report(session: dict, truth: dict, mapping: dict) -> list[str]:
    """The rig's values against the tape, and the scale error over long spans."""
    rig = {m["id"]: m for m in session["measurements"]}
    tape = {m["id"]: m for m in truth["measurements"] if m["status"] == "measured"}
    lines = [
        "| Survey measurement | Key | Tape (ft) | AR (ft) | AR / tape |",
        "| --- | --- | --- | --- | --- |",
    ]
    long_ratios = []
    for sid, entry in mapping["measurements"].items():
        if not isinstance(entry, dict) or "session_measurement" not in entry or sid not in tape:
            continue
        ar_ft = rig[entry["session_measurement"]]["values"][entry["key"]] / FEET
        t = tape[sid]["value_ft"]
        ratio = ar_ft / t
        lines.append(f"| {sid} | {entry['key']} | {t:.3f} | {ar_ft:.3f} | {ratio:.4f} |")
        if entry["key"] in SCALE_KEYS and t >= SCALE_SPAN_MIN_FT:
            long_ratios.append(ratio)
    if long_ratios:
        err = (np.median(long_ratios) - 1) * 100
        lines += [
            "",
            f"AR scale error: {err:+.1f}% (median over {len(long_ratios)} spans of "
            f"{SCALE_SPAN_MIN_FT:g} ft or more).",
        ]
    else:
        lines += [
            "",
            f"AR scale error: not measured (no mapped span of {SCALE_SPAN_MIN_FT:g} ft or more).",
        ]
    return lines


# --- Command ----------------------------------------------------------------------------------


def score(session_path: Path, truth_path, map_path, rules_path, out_dir: Path) -> str:
    folder, capture = unpack(session_path)
    session = load_session(folder)
    out = work_dir(folder)
    turns = json.loads((out / "turns.json").read_text())
    started = time.perf_counter()

    tapped = sorted({t["keyframe"] for t in session["taps"]})
    kids = tapped or [kf["id"] for kf in session["keyframes"]]
    fits = triangulated_scales(folder, out, session, kids)
    depth_cache: dict[str, np.ndarray] = {}

    def depth_of(k):
        if k not in depth_cache:
            depth_cache[k] = keyframe_depth(out, k, turns[k])
        return depth_cache[k]

    tri = [f.scale for f in fits.values() if f.scale is not None]
    lines = [
        f"# Field session {session['session']['id']} (generated by `uv run python -m evals.field score`)",
        "",
        f"- Keyframes: {len(session['keyframes'])}; taps: {len(session['taps'])}; points: "
        f"{len(session['points'])}; walls: {len(session['walls'])}; measurements: "
        f"{len(session['measurements'])}.",
        f"- Triangulation scale fitted for {len(tri)} of {len(fits)} "
        f"{'tapped ' if tapped else ''}keyframes"
        + (
            f": MoGe-2 x {np.median(tri):.3f} median (range {min(tri):.3f} to {max(tri):.3f})."
            if tri
            else "."
        ),
    ]
    rows = {
        "moge2": (
            "native_metric",
            learned_values(session, learned_points(session, depth_of, lambda k: 1.0)),
        ),
        "moge2-triangulated": (
            "ar_poses",
            learned_values(
                session,
                learned_points(session, depth_of, lambda k: fits[k].scale if k in fits else None),
            ),
        ),
    }
    missing = []
    if not session["measurements"]:
        missing.append(
            "measurements: the session has no taps or measurements, so no row has values"
        )
    if truth_path is None or map_path is None or rules_path is None:
        missing.append("a tape survey, its map and the rules file: no results files are written")
    if capture is None:
        missing.append("the session zip: its sha256 is the capture id the survey must list")
    if missing:
        lines += ["", "Missing:", *[f"- {m}" for m in missing]]
        return "\n".join(lines) + "\n"

    truth = json.loads(Path(truth_path).read_text())
    mapping = json.loads(Path(map_path).read_text())
    rules_sha = hashlib.sha256(Path(rules_path).read_bytes()).hexdigest()
    ref = mapping["measurements"].get(truth["scale_reference"])
    tape = {m["id"]: m for m in truth["measurements"]}.get(truth["scale_reference"])
    if (
        isinstance(ref, dict)
        and "session_measurement" in ref
        and tape
        and tape["status"] == "measured"
    ):
        native = rows["moge2"][1][ref["session_measurement"]][ref["key"]]
        s = tape["value_ft"] * FEET / native
        rows["moge2-tape"] = (
            "scale_reference",
            learned_values(session, learned_points(session, depth_of, lambda k: s)),
        )
    else:
        lines.append(
            "- No `moge2-tape` row: the map does not tie the survey's scale reference to a "
            "session measurement."
        )
    processing = time.perf_counter() - started
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, (source, recomputed) in rows.items():
        doc = results_file(
            name,
            source,
            capture,
            rules_sha,
            truth,
            mapping,
            recomputed,
            capture_seconds(session),
            processing,
        )
        (out_dir / f"{name}.json").write_text(json.dumps(doc, indent=1) + "\n")
    lines += [
        "",
        "## AR scale error against the tape",
        "",
        *ar_scale_report(session, truth, mapping),
    ]
    lines += ["", f"Results files: {', '.join(f'{n}.json' for n in rows)} in {out_dir}."]
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("step", choices=["prepare", "score"])
    ap.add_argument("session", type=Path, help="session zip shared from Measure Lab, or its folder")
    ap.add_argument("--truth", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--rules", type=Path)
    ap.add_argument("--out-dir", type=Path, default=FIELD_DIR / "results")
    args = ap.parse_args()
    if args.step == "prepare":
        print(prepare(unpack(args.session)[0]))
        return
    report = score(args.session, args.truth, args.map, args.rules, args.out_dir)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "field_report.md").write_text(report)
    print(report)


if __name__ == "__main__":
    main()
