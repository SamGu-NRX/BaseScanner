# Evals on real data

## Questions

1. How far is ARKit's tracking off after walking 3, 10, 20 and 30 ft outdoors? `docs/02` assumes plus or minus 0.3 ft; this measures it on ADVIO's outdoor walks.
2. How accurately can phone photos reconstruct a real building wall? Measured on ETH3D's facade and electro scenes against their laser scans, for single-image metric depth (MoGe-2, Depth Anything 3 metric), multi-view (MapAnything, Apache checkpoint) and per-frame depth fused with known camera poses, by number of views and scale source.
3. Which frames are worth keeping?

Every reported number comes from real data. Synthetic data appears only in the unit tests of the metric code.

## Setup

```sh
cd experiments/evals
uv sync
uv run pytest -q
```

Data lives outside the repo, in `~/house-scanning-data/` (override with `HOUSE_SCANNING_DATA`). The datasets are for non-commercial research: never commit their files, images from them, or anything derived that shows them.

## Datasets

| Dataset | File | URL | Bytes | sha256 |
| --- | --- | --- | --- | --- |
| ADVIO, CC BY-NC 4.0 | advio-20.zip | https://zenodo.org/record/1476931/files/advio-20.zip | 195538352 | be21154394df09d6ecebe1894062f290bb53d74a5c6ccbca4b3a69f91ee2c8a2 |
| ADVIO | advio-21.zip | https://zenodo.org/record/1476931/files/advio-21.zip | 209791503 | fb8a1cf3f645bbd9ea848e66924e83ae75b5cd18d632986e5629af1eecb58570 |
| ADVIO calibration, sequences 20 to 23 | iphone-04.yaml | https://raw.githubusercontent.com/AaltoVision/ADVIO/master/calibration/iphone-04.yaml | | 6f312ace74f23e41b755fa40829e30a4f96e8abd3c28e6bdbac2e5e39f960813 |

ADVIO sequences 20 to 23 are its outdoor walks (the dataset README calls 20 and 21 "Outdoor", 22 and 23 "Outdoor urban"). Each has 60 fps iPhone 6s video, the ARKit pose for every frame, and a 100 Hz ground-truth track built from the phone's IMU and manually placed fix points.

## Replay session from a real walk

`~/house-scanning-data/replays/advio-20-0040-0075.zip` is 35 s of ADVIO sequence 20 (seconds 40 to 75, a path past a brick building) in Measure Lab session format v2, for the app's replay mode and the verification thread. Rebuild it with:

```sh
uv run python -m evals.replay --sequence 20 --start 40 --end 75
uv run python -m evals.check_replay ~/house-scanning-data/replays/advio-20-0040-0075
```

It holds 79 keyframes chosen by Measure Lab's own rule (0.5 m or 15° since the last keyframe) from the ARKit poses. Beside `session.json` is `ground_truth.json`, ADVIO's ground-truth pose for each keyframe, which the app ignores. The zip's hash changes on every rebuild because zip entries carry timestamps.

How each part was made:

- **Images.** ADVIO's `frames.mov` stores 1280 × 720 landscape frames with a display tag that rotates them to portrait. The coded frames are the unrotated sensor images Measure Lab expects: sky on the left, ground on the right for a phone held upright. Frames are decoded sequentially by index; seeking by time in this file lands several frames off. Each is undistorted with ADVIO's calibration so a plain pinhole model is exact.
- **Intrinsics.** ADVIO calibrated the portrait frames with OpenCV's convention. Rotated to landscape and shifted by half a pixel to continuous coordinates this gives `[1082.1, 1081.1, 641.29, 359.91]` (`evals/camera.py`, `landscape_intrinsics_from_portrait`).
- **Poses.** `arkit.csv` holds ARKit's world position and an orientation in the portrait device frame (+x right and +y up on the portrait screen). The Measure Lab camera is that frame turned a quarter turn about the viewing axis: image right is screen down, image up is screen right (`DEVICE_TO_LANDSCAPE_CAMERA`). Before building the converter, rotations between frame pairs were estimated from the images alone (ORB matches, essential matrix) and compared with the poses: median disagreement 0.22° for this reading, 4.5° to 6.5° for the alternatives.
- **Check.** `check_replay` reads only session.json and the JPEGs and measures how far matched features between keyframes two apart lie from the epipolar lines the poses predict. On this session: median 3.1 px over 77 pairs, p90 5.1 px, world up pointing to image left (−x) as for a portrait phone. With the camera axes deliberately turned 90° the same check gives 61 px.
- **What ADVIO lacks.** It records no ARKit tracking state, so tracking is written as `normal` from the first frame ARKit reports a position (it reports exactly zero until it initialises). There are no taps, points, walls or measurements. The capture time is unpublished, so `startedAt` is the dataset's publication date; timestamps are ADVIO's own seconds.

What it is not: the camera points along the path, not at a wall, and the building is off to one side. It exercises replay plumbing, keyframe handling and real outdoor tracking, not a guided wall scan.
