"""A sample packet from the iOS app's own export (scan.zip) of a Simulator run on the ADVIO
replay, so the server team sees exactly what the app records today, in the packet's layout.

The app's export is scene.json (C1, feet) plus one JPEG per keyframe with its pose and
intrinsics. It has no timestamps; each photo's time is recovered by matching its pixels to the
replay keyframe it was taken from. Everything else the packet can hold is absent, and
provenance.notes lists it.

    uv run python -m packet.samples.app_export \
        --sim-report ~/house-scanning-data/reports/sim/20260926-071459-t3-ios-mvf-a39d0a50-replay \
        --replay ~/house-scanning-data/replays/advio-20-0040-0075 \
        --out ~/house-scanning-data/packets/app-export-a39d0a5
"""

from __future__ import annotations

import argparse
import io
import json
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

from packet.write import (
    PACKET_VERSION,
    SHARPNESS_METHOD,
    PacketWriter,
    column_major,
    from_column_major,
    meter_frame,
    orthonormalize,
    sharpness,
)

FEET = 0.3048
MATCH_SIZE = (64, 36)
# The app re-encodes the replay's JPEGs; a true match differs by JPEG noise only (mean absolute
# difference of a few grey levels on a 64 x 36 thumbnail). Anything above this is not a match.
MATCH_MAX_DIFF = 6.0
# scene.json object types that are also packet mark kinds (fences and drives are not objects).
MARK_OBJECTS = {"gas_meter", "ac", "door", "window", "garage_door"}


def thumbnail(data: bytes | Path) -> np.ndarray:
    with Image.open(io.BytesIO(data) if isinstance(data, bytes) else data) as img:
        return np.asarray(img.convert("L").resize(MATCH_SIZE, Image.Resampling.BILINEAR), float)


def build(sim_report: Path, replay: Path, out: Path) -> Path:
    report = json.loads((sim_report / "report.json").read_text())
    bundle = zipfile.ZipFile(sim_report / report["app_export"])
    scene_bytes = bundle.read("scene.json")
    scene = json.loads(scene_bytes)

    session = json.loads((replay / "session.json").read_text())
    replay_thumbs = [
        (kf["timestamp"], thumbnail(replay / kf["img"])) for kf in session["keyframes"]
    ]

    meter_ft = np.asarray(scene["meter"]["pos"], float)
    wall = next(w for w in scene["walls"] if w["id"] == scene["meter"]["wall_id"])
    (x0, z0), (x1, z1) = wall["baseline"][0], wall["baseline"][-1]
    along = np.array([x1 - x0, 0.0, z1 - z0])
    anchor = meter_frame(meter_ft * FEET, along)
    to_meter = np.linalg.inv(anchor)

    w = PacketWriter(out)
    photos = []
    for kf in scene["keyframes"]:
        data = bundle.read(kf["img"])
        thumb = thumbnail(data)
        diffs = [float(np.abs(thumb - t).mean()) for _, t in replay_thumbs]
        best = int(np.argmin(diffs))
        if diffs[best] > MATCH_MAX_DIFF:
            raise ValueError(
                f"{kf['img']}: no replay keyframe matches (best diff {diffs[best]:.1f})"
            )
        pose = from_column_major(kf["pose"])
        pose[:3, 3] *= FEET
        pose = orthonormalize(to_meter @ pose)  # scene.json rounds rotations to 4 decimals
        pid = f"p{int(kf['id'][1:]):05d}"
        photos.append(
            {
                "id": pid,
                "image": w.add_bytes(f"photos/{pid}.jpg", data),
                "width": kf["w"],
                "height": kf["h"],
                "t": replay_thumbs[best][0],
                "pose": column_major(pose),
                "intrinsics": kf["intrinsics"],
                "sharpness": {
                    "method": SHARPNESS_METHOD,
                    "value": round(sharpness(Image.open(io.BytesIO(data))), 3),
                },
            }
        )
    photos.sort(key=lambda p: p["t"])
    times = [p["t"] for p in photos]
    if len(set(times)) != len(times):
        raise ValueError("two app photos matched the same replay keyframe")
    camera_z = np.median([p["pose"][14] for p in photos])
    if camera_z <= 0:
        raise ValueError(
            f"cameras sit behind the wall (median z {camera_z:.2f} m): wall direction?"
        )

    def on_wall(s_ft: float, height_ft: float) -> list[float]:
        """A point on the wall at s (along it) and a height above the ground, in the meter frame."""
        return [round(s_ft * FEET, 4), round((height_ft - meter_ft[1]) * FEET, 4), 0.0]

    marks = [{"id": "meter", "kind": "meter", "points": [[0.0, 0.0, 0.0]]}]
    for i, obj in enumerate(scene.get("objects", [])):
        kind = obj["type"]
        if kind not in MARK_OBJECTS:
            continue
        s0, s1 = obj["span_ft"]
        bottom, top = obj.get("bottom_ft", 0.0), obj.get("top_ft", obj.get("bottom_ft", 0.0))
        points = (
            [on_wall((s0 + s1) / 2, (bottom + top) / 2)]
            if kind in ("gas_meter", "ac")
            else [on_wall(s0, bottom), on_wall(s1, top)]
        )
        mark = {"id": f"object{i}", "kind": kind, "points": points}
        if "operable" in obj.get("attrs", {}):
            mark["attrs"] = {"operable": obj["attrs"]["operable"]}
        marks.append(mark)
    ends = scene.get("coverage", {}).get("ends", {})
    for side, (ex, ez) in (("left", (x0, z0)), ("right", (x1, z1))):
        if side in ends:
            s = (np.array([ex, 0.0, ez]) - meter_ft * [1, 0, 1]) @ anchor[:3, 0]
            marks.append(
                {
                    "id": f"end-{side}",
                    "kind": "wall_end",
                    "points": [on_wall(float(s), meter_ft[1])],
                    "side": side,
                    "end_kind": ends[side]["kind"],
                }
            )

    manifest = {
        "packet_version": PACKET_VERSION,
        "session": {
            "id": f"app-export-{report['sha'][:7]}",
            "producer": {"kind": "converter", "name": "packet.samples.app_export", "version": "1"},
            "device": {"model": "iOS Simulator", "lidar": False},
            "capture": {"started_at_uptime": times[0], "ended_at_uptime": times[-1]},
            "world_alignment": "gravity",
            "meter_anchor": {
                "pose_in_world": column_major(anchor),
                "ground_y_m": round(-meter_ft[1] * FEET, 4),
            },
        },
        "photos": photos,
        "marks": marks,
        "scene": w.add_bytes("scene.json", scene_bytes)
        | {"schema_version": scene["schema_version"]},
        "provenance": {
            "dataset": "ADVIO sequence 20 via the app's replay",
            "license": "CC BY-NC 4.0 (ADVIO): accuracy testing only; never commit or share",
            "source": f"t3/ios-mvf {report['sha'][:7]}, Simulator run {sim_report.name}, scan.zip",
            "notes": [
                "Photos, poses, intrinsics, marks and scene.json are the app's; the JPEGs are "
                "unchanged. Poses are converted from scene.json's feet to meters and into the "
                "meter frame, with rotations re-orthonormalized after scene.json's rounding.",
                "pose_in_world is in scene.json's frame: ARKit's world moved so the ground at the "
                "wall is y = 0. The app does not export the offset to ARKit's own origin.",
                "t is recovered: each photo matched to the replay keyframe it came from. The "
                "app exports no timestamps.",
                "Absent because the app does not record them yet: device model and iOS version, "
                "wall-clock start, tracking state, exposure, ISO, lens, depth, trajectory, IMU, "
                "distance walked, mesh, planes, mark times and the guidance log.",
            ],
        },
    }
    return w.finish(manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sim-report", type=Path, required=True)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(build(args.sim_report.expanduser(), args.replay.expanduser(), args.out.expanduser()))


if __name__ == "__main__":
    main()
