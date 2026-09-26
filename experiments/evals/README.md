# Evals on real data

## Questions

1. How far is ARKit's tracking off after walking 3, 10, 20 and 30 ft outdoors? `docs/02` assumes plus or minus 0.3 ft (3.6 in).
2. How accurately can phone photos reconstruct a real building wall? Scored on ETH3D's facade and electro scenes against their laser scans, for single-image metric depth (MoGe-2, Depth Anything 3 metric), multi-view reconstruction (MapAnything, Apache checkpoint) and per-frame depth placed with known camera poses, by number of views and scale source.

Every reported number comes from real data. Synthetic data appears only in the unit tests of the metric code.

## Answers

<!-- ANSWERS -->

## Reproduce

From a clean checkout, on macOS with Apple silicon or Linux:

```sh
cd experiments/evals
uv sync
uv run pytest -q                                  # metric code against hand-computed cases

make drift        # ADVIO download (about 800 MB) and the drift tables -> results/advio_drift.md
make replay       # the replay session -> ~/house-scanning-data/replays/
make recon        # ETH3D download (about 2.4 GB), model runs, scoring -> results/eth3d_recon.md
```

Data lives outside the repo, in `~/house-scanning-data/` (override with `HOUSE_SCANNING_DATA`). `evals/datasets.py` checks every archive's size and sha256, unpacks only what the evals read, deletes the archive, and refuses to download with less than 6 GB free. Both datasets are licensed for non-commercial research: they measure accuracy here and are never committed, redistributed or used for training.

## Datasets

| Dataset and license | File | URL | Bytes | sha256 |
| --- | --- | --- | --- | --- |
| ADVIO, CC BY-NC 4.0 | advio-20.zip | https://zenodo.org/record/1476931/files/advio-20.zip | 195538352 | be21154394df09d6ecebe1894062f290bb53d74a5c6ccbca4b3a69f91ee2c8a2 |
| | advio-21.zip | https://zenodo.org/record/1476931/files/advio-21.zip | 209791503 | fb8a1cf3f645bbd9ea848e66924e83ae75b5cd18d632986e5629af1eecb58570 |
| | advio-22.zip | https://zenodo.org/record/1476931/files/advio-22.zip | 254664089 | 96c7212fc9cb610a88ba9fa62ac2581f0cdae49e80007888698ee2cf5ebd56f4 |
| | advio-23.zip | https://zenodo.org/record/1476931/files/advio-23.zip | 134340011 | 726d9b80d30036a8585f6cecaae385236b689cc4b8b19be6362c6df223825dc1 |
| | iphone-04.yaml (calibration, sequences 20 to 23; copied into `evals/advio.py`) | https://raw.githubusercontent.com/AaltoVision/ADVIO/master/calibration/iphone-04.yaml | | 6f312ace74f23e41b755fa40829e30a4f96e8abd3c28e6bdbac2e5e39f960813 |
| ETH3D, CC BY-NC-SA 4.0 | facade_dslr_undistorted.7z | https://www.eth3d.net/data/facade_dslr_undistorted.7z | 1252088400 | 046e577388db0633eeb2d8d72da6a2de53857434b4a7a98e4c97485795f9ce82 |
| | facade_dslr_scan_eval.7z | https://www.eth3d.net/data/facade_dslr_scan_eval.7z | 176517224 | d686462d417fbea010d0021f918bec8b881444929ec06e3bd4e8a5230ebf59a8 |
| | facade_dslr_occlusion.7z | https://www.eth3d.net/data/facade_dslr_occlusion.7z | 144292883 | 26a9d2076ba16b7f8e24311579c47b0b7b826b180906ced20fa1cba8f3dd130d |
| | electro_dslr_undistorted.7z | https://www.eth3d.net/data/electro_dslr_undistorted.7z | 514345623 | 0d2bc31fec0032b8fb20703abba8e45ef7a395c13d2d3476adc1f4dd4ffd7d8b |
| | electro_dslr_scan_eval.7z | https://www.eth3d.net/data/electro_dslr_scan_eval.7z | 250703286 | 5ca10a73e7da0e3c511e255bba5656cca4c372dc00c1417c97b75228a5bb3bac |
| | electro_dslr_occlusion.7z | https://www.eth3d.net/data/electro_dslr_occlusion.7z | 47214879 | cc25a22de9fc27251a5178454c24785671a2b2c199756a0d03297413290830b3 |

Model checkpoints, all licensed for commercial use, are pinned by revision and checked against Hugging Face's sha256 in `models/` (see `models/README.md`).

## 1. ARKit drift outdoors (ADVIO)

`uv run python -m evals.drift` writes [results/advio_drift.md](results/advio_drift.md).

**Data.** ADVIO's four outdoor walks (sequences 20 to 23, 3 to 6 minutes and 380 to 510 m each) were recorded in 2018 on a rig carrying an iPhone 6s (ARKit 1.0, video, GPS) and a Google Pixel running ARCore. The dataset's ground truth is an inertial track pinned to fix points that were marked on a map.

**Method.** From every half second of each walk, the walk continues until 3, 10, 20 or 30 ft of path has been covered. The error is ARKit's straight-line displacement minus the reference's. This distance error needs no heading alignment, and it is what a span measured by walking it (a 30 ft wall, the gap to a fence) would be off by.

**The ground truth is not good enough on its own, for two reasons.**

- Its scale is wrong in sequences 20 and 21. ARKit covers only 0.70 and 0.75 of the ground truth's distance there, which is why ARKit's path totals 345 m against the truth's 474 m in sequence 20. The phone's GPS says the truth is too long: the best GPS fit scales it by 0.835 and 0.799 (95% intervals 0.81 to 0.86 and 0.78 to 0.82). The Pixel's ARCore, an independent tracker, agrees (0.80 and 0.82). In sequences 22 and 23, which were recorded in a different place, GPS and ARCore agree with the truth's scale (1.03 and 1.03 in 22). The fix points show why: sequences 20 and 21 were pinned on one map, converted at 0.0422 m per map pixel, and 22 and 23 on another at 0.2256 m per pixel (`ground-truth/fixpoints.csv`). A first map scaled about 20% too large explains all of this. So most of the path-length gap is the reference's error; the rest, about 5% to 16%, is ARKit reading short (ARKit over GPS: 0.83, 0.94, 0.95 in sequences 20 to 22).
- Its random error is larger than ARKit's. The variances of the pairwise differences between ARKit, ARCore and the truth split into each tracker's own variance, if their errors are independent (the three-cornered hat, `three_cornered_hat`). At every distance in every sequence the truth's own spread is the largest: at 30 ft it is 35 to 73 in (1 sigma) against ARKit's 13 to 24 in, and in sequence 22 ARKit's is below what the method resolves. The inertial track wanders between fix points. Plain variances are used because only they add; they are sensitive to outliers, so treat these spreads as rough.

So the report scores ARKit against three references: the truth as published, the truth rescaled to GPS, and ARCore. ARCore is the tightest, and its errors add to ARKit's, so the "vs ARCore" column overstates ARKit's random error rather than hiding it. The bias columns carry the scale disagreement, which GPS attributes mostly to ARKit.

**Results, pooled over sequences 20 to 22** (sequence 23: ARKit lost tracking 5.5 s in, jumping at 826 m/s, and never recovered; it counts as a failure, not a number). |ARKit − reference|, inches:

| Walked | vs truth as published, median / p90 | vs truth rescaled to GPS | vs ARCore | ARKit short by (median, vs ARCore) |
| --- | --- | --- | --- | --- |
| 3 ft | 9.7 / 17.8 | 4.7 / 13.1 | 2.8 / 8.2 | 2.4 |
| 10 ft | 31.6 / 55.8 | 15.4 / 40.5 | 8.6 / 22.3 | 8.1 |
| 20 ft | 60.4 / 106.0 | 30.9 / 70.1 | 16.9 / 41.5 | 15.9 |
| 30 ft | 88.2 / 156.8 | 44.5 / 92.9 | 25.7 / 60.1 | 24.8 |

Per sequence against ARCore, the 30 ft median is 42.2 in (sequence 20), 23.1 in (21) and 17.3 in (22). Per-sequence tables and the noise split are in the results file.

**Limits.** This is a 2018 phone with ARKit 1.0, walking briskly with the camera pointed along the path rather than at a wall. Current iPhones and ARKit versions may track better; this eval has no data on them. The Measure Lab outdoor protocol (on `t3/measure-lab`) measures it on a current phone with a tape.

## 2. Reconstruction accuracy on building walls (ETH3D)

<!-- RECON -->

## Replay session from a real walk

`~/house-scanning-data/replays/advio-20-0040-0075.zip` is 35 s of ADVIO sequence 20 (seconds 40 to 75, a path past a brick building) in Measure Lab session format v2, for the app's replay mode and the verification thread. `make replay` rebuilds it and checks it:

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
