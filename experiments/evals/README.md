# Evals on real data

## Questions

1. How far is ARKit's tracking off after walking 3, 10, 20 and 30 ft outdoors? `docs/02` assumes plus or minus 0.3 ft (3.6 in).
2. How accurately can phone photos reconstruct a real building wall? Scored on ETH3D's facade and electro scenes against their laser scans, for single-image metric depth (MoGe-2, Depth Anything 3 metric), multi-view reconstruction (MapAnything, Apache checkpoint) and per-frame depth placed with known camera poses, by number of views and scale source.

Every reported number comes from real data. Synthetic data appears only in the unit tests of the metric code.

## Answers

Plain answers first; the evidence and limits follow in sections 1 to 3.

1. **ARKit drift: much worse than plus or minus 0.3 ft beyond a few feet, on the only phone measured.** On a 2018 iPhone 6s outdoors, a distance walked comes out a median 2.8 in off after 3 ft (p90 8.2 in), 8.6 in after 10 ft (p90 22.3), and 25.7 in after 30 ft (p90 60.1). It is mostly one steady error: ARKit read distances about 7% short against ARCore (5% to 17% short against GPS). The 0.3 ft guess holds in the median only for spans of about 3 ft, and never at p90. One of the four walks lost tracking entirely. ADVIO's own ground truth could not score this: its scale is 20% off in two walks and its random error is larger than ARKit's, so ARKit is scored against ARCore on the same rig, with GPS confirming the scale.
2. **Photos alone: no.** Without anything measured by hand, every model's scale is off. At phone range (points within 6 m of a camera), MoGe-2 reads +4% to +12% long, Depth Anything 3 metric −7% to −11% short, and MapAnything −9% to −24% short, giving median errors of 6 to 20 in on 1 to 3 m spans and 14 to 42 in on 3 to 10 m spans.
3. **Photos plus one taped distance: good in the median, loose in the tail.** Scaling by one taped 1 to 3 m distance, a single photo through MoGe-2 is off a median 1.6 in on 1 to 3 m spans and 3.0 in on 3 to 10 m spans (electro, within 6 m). But one span in ten is off by more than 8 in and 15 in. Under the strict decision rule (PASS only when the margin beats the error), the usable bound is about ±8 in for 1 to 3 m and ±15 in for 3 to 10 m: enough for clear-cut placements, not for anything near a threshold.
4. **More photos, or depth per photo placed with AR poses ("the phone imitates LiDAR"): no gain.** Per-photo depth placed with the true camera poses is no better than one photo, and with a taped distance it gets worse as views are added (MoGe-2 median 1.6 to 4.6 in on 1 to 3 m spans, 1 to 8 views): each photo has its own scale error, and one scale factor cannot fix all of them. MapAnything's joint reconstruction corrects part of its scale error with more views (−21% alone, about −10% with 2 to 8), but not enough to skip the tape.

5. **Which photos to keep: the close ones.** Scored one photo at a time (MoGe-2, one taped distance), keeping only photos with the wall within 6 m cut the error from 2.7 / 11.2 in (median / p90) to 1.9 / 6.8 in on 1 to 3 m spans, and from 7.6 / 38.5 in to 4.3 / 14.4 in on 3 to 10 m spans. Viewing angle made little difference across these photos (26 to 75 degrees off head-on).

What it means for the capture: without LiDAR, ask for one taped reference distance (or a known-size object) and use single-photo depth scaled by it, with an error bound set from the p90, not the median. Walking long distances with AR tracking to measure a span adds its own 7% bias on the phone measured here; a current phone must be checked with the Measure Lab tape protocol before that number is trusted.

## Reproduce

From a clean checkout, on macOS with Apple silicon or Linux:

```sh
cd experiments/evals
uv sync
uv run pytest -q                                  # metric code against hand-computed cases

make drift        # ADVIO download (about 800 MB) and the drift tables -> results/advio_drift.md
make replay       # the replay session -> ~/house-scanning-data/replays/
make recon        # ETH3D download (about 2.4 GB), model runs, scoring -> results/eth3d_recon.md
make frames       # after make recon: which photos to keep -> results/frames.md
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

`make recon` (or `uv run python -m evals.recon prepare` then `score` once the model outputs exist) writes [results/eth3d_recon.md](results/eth3d_recon.md), every method at 1, 2, 4 and 8 views for both scenes, both scale sources, and two ranges.

**Data.** ETH3D's facade (76 photos) and electro (45 photos) scenes: building walls photographed with a 24 MP DSLR, camera poses registered to terrestrial laser scans of the same walls. The photos are resized to 1024 px wide and fed to each model with their known intrinsics (a phone knows its own).

**What is scored.** The error in the distance between two points on the wall, against the laser scan's distance between the same two points, for pairs 1 to 3 m and 3 to 10 m apart. Distances do not change under rotation or translation, so no alignment step can hide error: only scale and shape count. Scale error is the median of predicted over true length, minus one.

**How ground truth is matched to pixels** (`evals/eth3d.py`). ETH3D's rendered depth maps belong to the original distorted photos, whose camera model is not published with the undistorted set, so the laser scan points are projected into each undistorted view directly. A point counts as visible when it is within 4% of the nearest depth in a z-buffer built from all scan points plus ETH3D's occlusion splats. Points on depth edges and in ETH3D's masked regions (glass, and objects missing from the scan such as trees and a tram; mapped from the distorted frame and dilated 13 px) are dropped. The scan's depth agrees with ETH3D's own sparse 3-D points to a median 0.2 to 0.4% where both exist. Scoring the scan's own rendered depth through the same pipeline gives 0.2 to 0.8 in median error on 1 to 3 m spans (p90 under 3 in): the evaluation's floor, far below every model's error.

**Methods.**

- One photo: MoGe-2 and Depth Anything 3 metric, each photo alone.
- Per-photo depth placed with the true camera poses, standing in for AR poses: each scan point's position averaged over the photos of a group that see it. Groups are 8 seed photos spread through each capture, each with its 1, 3 or 7 nearest cameras that face the same way.
- MapAnything, Apache checkpoint: one joint reconstruction per group, in its own frame and scale.
- Scale source: the model's own metric output, or one taped distance, simulated by rescaling so one random 1 to 3 m pair has its true length (25 different pairs per group, pooled, so an unlucky reference counts).

**Results at phone range: electro, points within 6 m of a camera** (41% of electro's points; facade's scored points lie 10 to 23 m from its cameras, and its few near points agree). |length error|, inches, median / p90:

| Method | Views | Model scale: 1-3 m | 3-10 m | Scale error | One taped distance: 1-3 m | 3-10 m |
| --- | --- | --- | --- | --- | --- | --- |
| MoGe-2, one photo | 1 | 6.8 / 18.7 | 14.9 / 39.5 | +4.4% | 1.6 / 8.3 | 3.0 / 14.6 |
| Depth Anything 3 metric, one photo | 1 | 5.9 / 17.2 | 13.5 / 36.5 | −7.2% | 2.7 / 16.5 | 5.7 / 31.6 |
| MoGe-2 per photo + true poses | 2 | 5.4 / 15.2 | 12.6 / 30.6 | +2.4% | 2.9 / 13.8 | 5.5 / 23.3 |
| MoGe-2 per photo + true poses | 8 | 5.2 / 12.8 | 12.3 / 26.3 | +3.0% | 4.6 / 18.1 | 9.8 / 41.9 |
| Depth Anything 3 metric per photo + true poses | 8 | 5.4 / 14.5 | 15.5 / 34.9 | −6.8% | 4.1 / 15.8 | 8.9 / 36.1 |
| MapAnything | 1 | 20.0 / 40.4 | 42.1 / 77.0 | −21.4% | 2.0 / 15.2 | 4.2 / 25.3 |
| MapAnything | 2 | 10.3 / 31.9 | 21.4 / 68.4 | −8.5% | 2.1 / 12.0 | 4.6 / 22.8 |
| MapAnything | 8 | 8.8 / 22.2 | 21.6 / 60.5 | −10.6% | 2.9 / 9.5 | 6.8 / 22.0 |
| Scan rendered as depth (evaluation floor) | 1 | 0.7 / 1.6 | 1.3 / 2.4 | −0.8% | 0.5 / 1.5 | 1.0 / 2.5 |

Over all points (4 to 23 m from the cameras) errors are larger and the model scale errors wider: MoGe-2 −8% on facade and +0.5% on electro, Depth Anything 3 metric −10% to −15%, MapAnything −10% to −33%. With a taped distance, one MoGe-2 photo is off a median 2.5 to 3.0 in on 1 to 3 m spans and 6 to 9 in on 3 to 10 m spans at that range.

**Limits.** Two scenes, both institutional buildings rather than houses, photographed with a DSLR that is sharper and lower-noise than a phone camera; phone photos should score the same or worse. The true poses are exact; real AR poses add the drift measured in section 1. The taped distance is simulated as exact. MapAnything was given intrinsics but not poses; giving it AR poses is untested here.

## 3. Which photos to keep (ETH3D)

`uv run python -m evals.frames` writes [results/frames.md](results/frames.md). Each ETH3D photo is scored alone (MoGe-2, scaled by one taped 1 to 3 m distance) and described by what an app can measure while capturing: the median distance to the wall points in view, and the median angle between the viewing ray and the wall's surface (from the laser scan's normals). Both scenes pooled, |length error| in inches, median / p90:

| Keep | Photos kept | 1-3 m spans | 3-10 m spans |
| --- | --- | --- | --- |
| every photo | 121 of 121 | 2.7 / 11.2 | 7.6 / 38.5 |
| wall within 6 m | 15 of 121 | 1.9 / 6.8 | 4.3 / 14.4 |
| wall within 8 m | 27 of 121 | 2.1 / 7.2 | 4.8 / 16.1 |
| wall within 12 m | 42 of 121 | 2.2 / 8.0 | 5.3 / 19.4 |
| wall seen within 40 degrees of head-on | 53 of 121 | 2.4 / 9.5 | 7.5 / 36.1 |
| wall seen more than 50 degrees off head-on | 40 of 121 | 2.8 / 11.6 | 7.1 / 32.0 |

Distance is what matters: the p90 on 3 to 10 m spans falls from 38.5 to 14.4 in when only photos within 6 m are kept. Viewing angle barely changes anything, but no photo here is closer to head-on than 26 degrees, so a head-on shot is untested. Only 15 photos are within 6 m, all of them from electro, so the near-range numbers rest on one building.

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
