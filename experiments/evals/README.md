# Evals on real data

## Questions

1. How far is ARKit's tracking off after walking 3, 10, 20 and 30 ft outdoors? `docs/02` assumes plus or minus 0.3 ft (3.6 in).
2. How accurately can phone photos reconstruct a real building wall, with the model's own scale or with one taped distance, from one photo or several?
3. Can the phone's AR poses fix the learned models' scale, well enough for about 4 in at p90 on 1 to 3 m spans, the error that decides a 3 ft clearance?
4. Which photos are worth keeping?
5. On a real field session with a tape survey, how do the phone's AR taps and the learned-depth methods compare, and what is the phone's AR scale error?
6. How large is a current iPhone's ARKit scale error, from public data?

Every number comes from real data. Synthetic data appears only in the unit tests of the metric code.

## Answers

What the ETH3D numbers measure: the error in the distance between two scanned surface points, against a laser scan, reported separately for surface interiors, vertical surfaces (walls, fences) and depth edges (window frames, equipment, fence edges). Clearance endpoints are often edges, and edges score worst. Every "p90" below counts failures (no prediction, or a taped reference that no scale could match) as infinitely wrong.

1. **ARKit drift: far worse than plus or minus 0.3 ft beyond a few feet, on the only phone measured.** On a 2018 iPhone 6s outdoors, ARKit and ARCore on the same rig disagree about a walked distance by a median 2.8 in after 3 ft (p90 8.2 in), 8.6 in after 10 ft (p90 22.3) and 25.7 in after 30 ft (p90 60.1). That is a disagreement between two trackers, not a bound on ARKit's error, but most of it is one steady offset that GPS attributes to ARKit: it reads distances 5% to 17% short. Position error, which also counts sideways drift, is larger against ADVIO's truth: p90 18.6, 55.7, 94.6 and 132.6 in after 3, 10, 20 and 30 ft. That is two to three times the server's allowance of 0.16 ft per ft, though the truth's own heading and position noise inflate it. One of four walks lost tracking entirely.
2. **Photos alone: no.** Each model's own metric scale is off. Within 6 m of the camera, MoGe-2 reads 4% to 12% long and Depth Anything 3 metric 7% to 11% short: median errors of 6 to 8 in on 1 to 3 m spans, p90 about 20 in.
3. **One photo plus one taped distance: good median, loose tail, worst on walls and edges.** A single MoGe-2 photo scaled by a taped 1 to 3 m distance is off a median 1.6 in on 1 to 3 m spans (electro, within 6 m). The p90 is 9.6 in on surfaces overall, 15.1 in on vertical surfaces and 26.9 in at edges. That settles only clear-cut placements.
4. **More photos with true poses and no rescale: no gain.** On a fixed set of points and pairs, per-photo depth averaged over 1, 2, 4 and 8 photos with the true poses gives, with one tape, medians of 1.8, 2.3, 2.5 and 2.8 in and p90s of 8.6, 11.4, 15.7 and 10.8 in on 1 to 3 m spans. Each photo carries its own scale error, and averaging mixes them.
5. **AR poses fixing scale: not to about 4 in, even at an assumed 2% pose error.** Rescaling each photo's MoGe-2 depth to points triangulated with the poses, then fusing 8 photos, gives these p90s on 1 to 3 m spans (electro, within 6 m, no tape, 95% intervals over seed groups and 5 pose-noise draws):
   - exact poses: 4.0 in [3.3, 4.8] overall, 2.8 in [2.0, 4.4] on walls;
   - an assumed modern phone (2% scale error, 1 cm and 0.1° of noise): 5.6 in [4.6, 6.7] overall, 5.0 in [3.8, 6.8] on walls;
   - the errors measured on the 2018 phone: 14.6 in [10.6, 18.7] overall, 10.8 in [8.6, 13.1] on walls.

   These assume perfect feature matching across photos; without it, walls reach 6.3 in even with exact poses. Edges stay at 8 in or worse everywhere. The pose's scale error passes straight into every length. MapAnything given the poses fixes its scale on one scene but not the other, and leaves 10% to 20% of pairs without a prediction.

   **Verdict:** neither way reaches about 4 in at p90 with realistic pose error. An earlier single noise draw showed walls at 3.9 in; with five draws that was the lucky end of the spread.
6. **Which photos to keep: the close ones.** Keeping only photos with the wall within 6 m cuts a single photo's p90 from 11.4 to 6.9 in on 1 to 3 m spans, and from 39.0 to 14.8 in on 3 to 10 m spans. Viewing angle barely mattered.
7. **The field session: not measured yet.** `make field` (section 5) puts the phone's AR taps and three learned-depth rows in one table against tomorrow's tape survey, with the phone's AR scale error beside it. It runs end to end on the ADVIO replay and on a synthetic survey, but the numbers need the real session.
8. **A current iPhone's ARKit scale: within 2% of the only public reference, which cannot itself be checked to 2%.** On MARViN's 35 outdoor walks (iPhone 14 Pro Max, ARKit 6, 45 to 255 m each), ARKit's scale matched the dataset's COLMAP reference within 2% on 30. Scene by scene the median walk reads +0.3%, +1.2% and −1.7%. So section 3's modern_assumed 2% is plausible for this phone, though even that setting leaves walls at a p90 of 5.0 in [3.8, 6.8]. It is not proven: that reference gets its meters from its authors, not from a tape or a laser, and GPS can only check it to several percent. The phone also has LiDAR, so it may track better than the LiDAR-less phones we target. Its position error p90 over trusted walks is 8.6, 13.4 and 18.5 in after 10, 20 and 30 ft (50.0 in at 30 ft counting the three doubtful walks), inside the server's 0.16 ft per ft allowance. The field tape test stays decisive (section 6).

## Reproduce

From a clean checkout (macOS with Apple silicon, or Linux for everything but the models):

```sh
cd experiments/evals
uv sync
make test          # metric code against hand-computed cases, lint, format
make drift         # ADVIO download (about 800 MB) -> results/advio_drift.md
make replay        # the replay session -> ~/house-scanning-data/replays/
make recon         # ETH3D download (about 2.4 GB), MoGe-2 and Depth Anything 3 runs -> results/eth3d_recon.md
make sensitivity   # after recon -> results/eth3d_visibility_sensitivity.md
make pose-priors   # after recon -> results/pose_priors.md
make frames        # after recon -> results/frames.md
make field SESSION=... TRUTH=... MAP=... RULES=... SCORING=../scoring   # a field session, section 5
make modern-arkit  # MARViN pose files (about 3 MB) -> results/modern_arkit.md, section 6
```

Data lives in `~/house-scanning-data/` (override with `HOUSE_SCANNING_DATA`). `evals/datasets.py` checks each archive's size and sha256, unpacks only what the evals read, deletes the archive, and refuses to download with less than 6 GB free. Both datasets are licensed for non-commercial research: they measure accuracy here and are never committed, redistributed or used for training.

Every process stays near or under 4 GB, because the machine is shared. MapAnything's 1.2 B parameters are loaded with their transformer weights in bf16 (`models/map_anything.py`), and even then only 2 and 4 views at 392 px fit (peak 4.05 GB). An earlier run at its native 518 px, with fp32 weights, read 10% to 33% short, where the 392 px run reads 17% long on electro's near walls and 14% short on facade. So its metric scale depends on input resolution, and neither run is a stable baseline.

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

MARViN (iPhone 14 Pro Max; https://github.com/XRIM-Lab/MarViN) states no data license, so it is used only to measure accuracy and never redistributed. Only its pose and GPS text files are fetched, from its public Google Drive folder, and each file's sha256 is listed in [results/modern_arkit.md](results/modern_arkit.md).

Model checkpoints (MIT and Apache-2.0) are pinned by revision and checked against Hugging Face's sha256 (`models/README.md`).

## 1. ARKit drift outdoors (ADVIO)

[results/advio_drift.md](results/advio_drift.md), `make drift`.

**Data.** ADVIO's four outdoor walks (sequences 20 to 23, 3 to 6 minutes and 380 to 510 m each), recorded in 2018 on a rig carrying an iPhone 6s (ARKit 1.0, video, GPS) and a Google Pixel running ARCore. The ground truth is an inertial track pinned to fix points marked on a map.

**Method.** From every half second of a walk, the walk continues until exactly 3, 10, 20 or 30 ft of path has been covered. The error is ARKit's straight-line displacement minus the reference's. It needs no heading alignment, and it is what a span measured by walking it would be off by.

**Why ARKit is not scored against ADVIO's ground truth alone.** Its scale is wrong in walks 20 and 21. ARKit covers only 0.70 and 0.75 of the truth's distance there, which is why ARKit's path totals 345 m against the truth's 474 m in walk 20. GPS scales the truth by 0.835 and 0.799 (95% intervals 0.81 to 0.86 and 0.78 to 0.82), and ARCore agrees (0.80 and 0.82). In walks 22 and 23 both agree with the truth's scale. The fix points explain it: walks 20 and 21 were pinned on one map at 0.0422 m per map pixel, and 22 and 23 on another at 0.2256 m per pixel. So most of the path-length gap is the reference's error; the rest is ARKit reading 5% to 17% short (ARKit over GPS: 0.83, 0.94, 0.95 in walks 20 to 22).

The truth also wanders between fix points. The results file splits the variance of each pairwise difference into per-tracker parts, but that split assumes the three trackers' errors are independent. Walk 22 violates it: it gives negative variances, and at 3 ft it puts ARCore's spread (16.3 in) above the truth's (8.1 in). Read the split as conditional, not as a resolution limit or a bound.

**Results, pooled over walks 20 to 22** (walk 23: ARKit jumped at 826 m/s 5.5 s in and never recovered). |ARKit − reference|, inches, median / p90:

| Walked | vs truth as published | vs truth rescaled to GPS | ARKit − ARCore disagreement | Signed median, ARKit − ARCore |
| --- | --- | --- | --- | --- |
| 3 ft | 9.7 / 17.8 | 4.7 / 13.1 | 2.8 / 8.2 | −2.4 |
| 10 ft | 31.6 / 55.8 | 15.4 / 40.5 | 8.6 / 22.3 | −8.1 |
| 20 ft | 60.4 / 106.0 | 30.9 / 70.1 | 16.9 / 41.5 | −15.9 |
| 30 ft | 88.2 / 156.8 | 44.5 / 92.9 | 25.7 / 60.1 | −24.8 |

The ARCore column is the tightest comparison, but it is not a conservative estimate of ARKit's error: two trackers on one rig can share errors that cancel in their difference.

**Position error.** Distance error only compares how far each track moved, so it cannot see sideways drift, and placement relative to the meter needs the whole displacement. Here ARKit's displacement is turned by the heading difference at each window's start, against the GPS-rescaled truth, both as tracked and with each walk's own ARKit scale divided out (0.838, 0.943 and 0.951 in walks 20 to 22). Pooled over walks 20 to 22, median / p90 inches:

| Walked | As tracked | Scale removed | Server allowance, 0.16 ft per ft |
| --- | --- | --- | --- |
| 3 ft | 8.3 / 18.6 | 7.7 / 20.4 | 5.8 |
| 10 ft | 26.3 / 55.7 | 24.5 / 59.6 | 19.2 |
| 20 ft | 50.4 / 94.6 | 47.7 / 102.5 | 38.4 |
| 30 ft | 73.8 / 132.6 | 70.4 / 144.6 | 57.6 |

Removing the scale barely changes the numbers, so what remains is heading and random error. Much of it is the reference's own: its random error is the largest of the three trackers', and its heading at each window's start enters directly. These numbers therefore overstate ARKit's error, but they are the only position errors this data supports. ARCore cannot serve as a position reference, because its orientation convention is undocumented.

**Limits.** A 2018 phone with ARKit 1.0, walking briskly with the camera pointed along the path. Current phones may track better; there is no data on them here.

## 2. Reconstruction accuracy on building walls (ETH3D)

[results/eth3d_recon.md](results/eth3d_recon.md), `make recon`; [results/eth3d_visibility_sensitivity.md](results/eth3d_visibility_sensitivity.md), `make sensitivity`.

**Data.** ETH3D's facade (76 photos) and electro (45 photos) scenes: building walls photographed with a 24 MP DSLR, camera poses registered to terrestrial laser scans. Photos are resized to 1024 px wide and fed to each model with their known intrinsics.

**What is scored.** The error in the distance between two scanned points, for pairs 1 to 3 m and 3 to 10 m apart. Distances do not change under rotation or translation, so no alignment step can hide error. Scale error is the median of predicted over true length, minus one.

**How points are chosen** (`evals/eth3d.py`, `evals/recon.py`):
- **Visibility.** Scan points are projected into each view. A point is visible when it is within 4% of the nearest scanned depth along its pixel, in a z-buffer that also holds ETH3D's occlusion splats. Points in ETH3D's masked regions are dropped: glass, and objects missing from the scan such as trees. The masks are drawn on the distorted originals, so they are stretched to the undistorted frame and dilated 13 px.
- **Cohorts.** Points where the depth jumps by more than 10% within 5 pixels are depth edges; the rest are surface interior, and interior points whose scan normal is within 17° of horizontal form the vertical cohort.
- **Fixed evaluation sets.** Each of 8 seed photos per scene fixes a set of points (those it sees; within 6 m of it for the near slice), test pairs and 25 taped reference pairs. The same set scores every method and every group size (the seed plus its 1, 3 or 7 nearest cameras facing the same way). Other photos only add predictions for those points, and in the near slice a photo contributes a point only if its own camera is within 6 m of it.
- **Failures.** A pair with no prediction, or a taped reference no scale can match, counts as infinitely wrong. The tables report the calibration success rate.

**Checks.** Scan depths agree with ETH3D's own sparse 3-D points to a median 0.2% to 0.4%. Depth rendered from the scan itself, scored through the same pipeline, is off 0.2 to 0.8 in median on 1 to 3 m spans (p90 under 2.5 in): the evaluation's floor. Changing the visibility tolerance to 2% or 8% moves model scale errors by about 1 point and medians by about 0.5 in, but p90s by up to 20% (MoGe-2) and more for Depth Anything 3. Treat p90s as carrying roughly that much evaluation uncertainty.

**Results at phone range: electro, within 6 m** (facade's photos were taken from 10 to 25 m). |length error|, inches, median / p90; "all photos" rows score every photo on its own evaluation set:

| Method | Photos | Cohort | Model scale: 1-3 m | Scale error, 1-3 m pairs | One taped distance: 1-3 m | 3-10 m |
| --- | --- | --- | --- | --- | --- | --- |
| MoGe-2, one photo | all | surface interior | 6.8 / 19.5 | +3.5% | 1.6 / 9.6 | 3.0 / 17.8 |
| | | vertical interior | 7.1 / 24.7 | +1.0% | 1.8 / 15.1 | 3.6 / 58.2 |
| | | edges | 8.3 / 31.8 | +3.6% | 3.7 / 26.9 | 5.8 / 36.8 |
| Depth Anything 3 metric, one photo | all | surface interior | 6.0 / 20.2 | −6.6% | 2.9 / 25.3 | 6.1 / 62.6 |
| MoGe-2 per photo + true poses | 1 | surface interior | 6.9 / 14.9 | +4.4% | 1.8 / 8.7 | 3.5 / 17.5 |
| | 2 | | 6.8 / 15.0 | +2.4% | 2.3 / 11.3 | 4.0 / 21.1 |
| | 4 | | 6.1 / 14.4 | +2.5% | 2.5 / 15.7 | 4.4 / 33.1 |
| | 8 | | 5.4 / 12.5 | +0.7% | 2.8 / 10.8 | 4.3 / 21.1 |
| Scan rendered as depth (floor) | 1 | surface interior | 0.7 / 1.6 | −0.9% | 0.5 / 1.6 | 0.9 / 2.8 |

Back-projection uses ETH3D's own intrinsics, not the centred ones MoGe-2 reports (a 0.8 to 3.6 px difference that moves medians by at most 0.1 in).

Over all points (4 to 23 m away), MoGe-2 reads 8% short on facade and 0.5% long on electro, and Depth Anything 3 metric 10% to 15% short. With a tape, one MoGe-2 photo is off a median 2.5 to 2.9 in on 1 to 3 m spans.

**Limits.** Two institutional buildings, not houses, photographed with a DSLR that is sharper than a phone camera. The taped distance is simulated as exact. Facade's near slice holds only 2 of its 8 groups, too few to conclude from.

## 3. Pose priors: can AR poses fix the scale? (ETH3D)

[results/pose_priors.md](results/pose_priors.md), `make pose-priors`.

**Poses.** ETH3D's true poses, degraded per group of photos (`evals/ar_poses.py`). Each setting is an assumption:
- **exact:** the true poses.
- **advio_2018:** each group takes one ADVIO walk's measured ARKit scale against the GPS-rescaled truth (0.838, 0.943 or 0.951; ARCore itself reads about 4% short of GPS, so it is not the reference). It adds 5 cm and 0.2° of noise per camera, from ARKit's own 3 in spread over 3 ft and the 0.22° image-vs-pose disagreement on the replay.
- **modern_assumed:** 2% short, 1 cm and 0.1°, a guess for a current iPhone with no data behind it.

**Methods.**
- **(a) MapAnything** given the poses and intrinsics as priors, at 392 px with 2 and 4 photos (the memory limit); the same runs without poses are its baseline.
- **(b) Triangulation rescale.** MoGe-2 depth for each photo is rescaled to the points triangulated from SIFT matches across the group with those poses (`evals/triangulate.py`: one factor per photo, the median ratio over at least 20 points that reproject within 2 px plus the pose noise), then placed with the same poses and fused.
- **Control:** MoGe-2 placed with the same poses without the rescale.

**Results: electro, within 6 m, 1 to 3 m spans, no tape, 8 photos.** Median / p90 inches with 95% intervals. The intervals bootstrap over the seed groups (7 for surface interior, 6 for walls) and over 5 pose-noise draws for each AR-like setting; exact poses have no noise to draw.

| (b) MoGe-2 rescaled by triangulation | Surface interior | Vertical interior (walls) | Scale error |
| --- | --- | --- | --- |
| exact poses | 1.3 [1.0, 1.5] / 4.0 [3.3, 4.8] | 1.1 [0.8, 1.4] / 2.8 [2.0, 4.4] | −0.6% |
| modern_assumed (2% short, 1 cm, 0.1°) | 2.5 [2.1, 2.9] / 5.6 [4.6, 6.7] | 2.3 [1.7, 2.8] / 5.0 [3.8, 6.8] | −3.0% |
| advio_2018 (measured on the 2018 phone) | 6.2 [4.6, 8.6] / 14.6 [10.6, 18.7] | 4.9 [3.7, 6.5] / 10.8 [8.6, 13.1] | −7.3% |

Edges stay at 8 in or worse at p90 in every setting. The control, MoGe-2 placed with the same poses and no rescale, has a p90 of 12.5 in with exact poses. With 4 photos, (b)'s p90 more than doubles.

These rows assume perfect cross-view correspondence: each scan point is found in every photo that sees it through the true projection, as a perfect feature matcher would. An app without a matcher would instead reproject the tapped photo's own estimate into the others. Done that way, the wall p90 with 8 photos rises from 2.8 to 6.3 in with exact poses, from 4.3 to 6.4 in with modern_assumed and from 10.3 to 14.8 in with advio_2018, on one noise draw each. Medians move by 0.2 in or less.

(a) MapAnything given the poses, at 392 px with 4 photos, fixes most of its scale on electro (+17% becomes about +3%) but not on facade (still 12% to 16% short). It leaves 10% to 20% of pairs without a prediction, so its p90 fails. Its rows have a single noise draw: its weights were removed to free disk.

**What decides it.** Triangulation fixes each photo's own scale error, which is why 8 rescaled photos beat 8 unscaled ones by a factor of three. But the triangulated points take their scale from the poses, so the pose's scale error passes straight into every length: 2% short in, 3% short out. A taped distance on top makes it worse, not better (p90 7.6 in with exact poses): the reference pair carries its own reconstruction error, which outweighs the scale error that is left.

## 4. Which photos to keep (ETH3D)

[results/frames.md](results/frames.md), `make frames`. Each photo is scored alone (MoGe-2, one taped distance, surface interior) and described by what an app can measure while capturing: the median distance to the wall points in view, and the median angle between the viewing ray and the scanned surface. Both scenes pooled, median / p90 inches:

| Keep | Photos kept | 1-3 m spans | 3-10 m spans |
| --- | --- | --- | --- |
| every photo | 121 of 121 | 2.7 / 11.4 | 7.6 / 39.0 |
| wall within 6 m | 15 of 121 | 1.9 / 6.9 | 4.3 / 14.8 |
| wall within 8 m | 27 of 121 | 2.1 / 7.4 | 4.8 / 17.0 |
| wall within 12 m | 42 of 121 | 2.3 / 8.1 | 5.4 / 20.4 |
| wall seen within 40 degrees of head-on | 52 of 121 | 2.3 / 9.3 | 7.1 / 35.2 |
| wall seen more than 50 degrees off head-on | 40 of 121 | 2.8 / 11.7 | 7.1 / 32.8 |

No photo here is closer to head-on than 26 degrees, so a head-on shot is untested, and all 15 photos within 6 m are from electro.

## 5. A field session against the tape

`make field SESSION=session.zip TRUTH=survey.json MAP=map.json RULES=rules.json SCORING=../scoring` turns one Measure Lab session (PR #7's one-hour tape protocol) and its tape survey into one table of every method, scored by the scoring harness (PR #4, `experiments/scoring`). The map is the same file `score import-measure-lab` reads. The command runs these steps (`evals/field.py`):

1. It turns each keyframe upright and runs MoGe-2 on it. Session images are sideways sensor images, and the model expects upright photos. **Run `make field` with nothing else heavy on the machine:** MoGe-2 at its default resolution peaks at 4.07 GB, just over the shared machine's 4 GB per process. Depth maps are written as each keyframe finishes, so the peak does not grow with session length, and a 3.6 GB GPU cap stops a run that would grow instead of letting it swell. Storing its encoder in half precision to get under 4 GB failed: parts of the encoder run outside autocast and reject fp16 weights.
2. It gives every point the rig made from taps a second position: MoGe-2's depth at the tapped pixel, placed with that keyframe's AR pose. It then recomputes walls and every session measurement with Measure Lab's own formulas (`Wall.swift`, `Measurements.swift`).
3. It writes three scoring-harness results files:
   - `moge2`: the model's own scale;
   - `moge2-triangulated`: method (b) of section 3, each keyframe rescaled to features triangulated with the session's AR poses across it and its 7 nearest keyframes;
   - `moge2-tape`: one depth scale for the session, solved so the survey's scale reference comes out at its taped length. Each point moves along its ray from its own keyframe's camera and camera positions don't scale, so it solves along the rays rather than dividing lengths; a length ratio is exact only when both taps share a keyframe. The reference must be a straight point-to-point measurement.

   They state no uncertainty and make no decisions: none of them has a validated error bar.
4. It imports the rig's own row with `score import-measure-lab` and scores every row with `score`.
5. It writes `field_report.md` with the phone's AR scale error, the number section 3's verdict hinges on:
   - Only measurements the rig accepted count, as in PR #4's importer.
   - The scale is a least-squares fit over straight spans of 10 ft or more, weighted by length, with a 95% bound per span and overall. The bound combines the tape's ± with an assumed 2 in of tapping error per span, which the field test itself will check (`--tap-error-in`).
   - It needs an accepted span of about 30 ft (29 ft or more), and answers "within 2%" as yes, no or cannot tell, under the same strict rule as placements.
   - Each session writes to its own folder, cleared on a re-run, so `score` never picks up an earlier run's rows.

MapAnything is left out. In section 3, given poses, it was worse than (b) everywhere. It left 10% to 20% of pairs without a prediction and did not fix its scale on facade. It also cannot take a phone's full keyframe set within the 4 GB limit.

**Checked.** A hand-computed synthetic session (`tests/test_field.py`) gets all four rows through PR #4's own `score`, including its import of the rig's row, in one table:
- The rig row reads 2% short, as planted.
- MoGe-2 with depth 10% long gives every length 10% long.
- The tape row comes out exact.
- The triangulated row reports every value as failed: one keyframe has no neighbours to triangulate against.

**On the real ADVIO replay** ([results/field-replay/field_report.md](results/field-replay/field_report.md)), the pipeline runs through MoGe-2 and triangulation. All 79 keyframes get a scale, and MoGe-2 needs a median ×0.774 (0.66 to 1.03) to agree with the iPhone 6s's ARKit poses; ARKit itself read about 16% short on this walk. Nothing more comes out, because the replay has no taps, measurements, survey or map.

**Field checklist**, on top of the one-hour protocol, so every row has inputs:

- **Three long spans for the AR scale error.** Measure the 30 ft span twice in the rig, walking each way, and one more straight span of at least 20 ft, for example along the facing fence. Tape and map all three. With 2 in of tapping error per span, one 30 ft span bounds the scale to ±1.1% (95%); these three bound it to ±0.7%, enough to tell 1% from 2%.
- **A scale reference for the tape row.** Mark two painter's-tape crosses 1 to 3 m apart on the wall and tape the distance. Tap both crosses with On wall, measure them (straight), and name that measurement the survey's `scale_reference` in the map.
- **Every surveyed endpoint as a rig tap.** The learned rows only recompute measurements the rig made. Tap the window edges, the meter's bottom edge, the fence foot and the overhead, on frozen frames and on the near surface (the frame, not the glass).
- **Neighbours for triangulation.** At each tapped feature, walk about 2 m sideways, slowly, 2 to 6 m from the wall, keeping the feature and some textured surface in view. That gives at least 8 keyframes of it, facing within 60° of the same way. Don't point at the sky.
- **The fence and the wall together.** Take the fence-foot tap from where the wall's base is also in view.
- **Share the zip as Measure Lab makes it.** Put its sha256 in the survey's `captures`, and write down the phone model and iOS version.

## 6. A current iPhone's ARKit scale (MARViN)

[results/modern_arkit.md](results/modern_arkit.md), `make modern-arkit`.

**Which data, and why.** The only public data I found with a 2020-or-newer iPhone's own ARKit poses and a separate reference trajectory, downloadable today, is MARViN (Liu et al., IEEE VRW 2024). It has an iPhone 14 Pro Max (ARKit 6) walking outdoors around three sites, 45 to 255 m per walk, one image per second, with a COLMAP reconstruction of each site as the reference. Checked and not used:
- **LaMAR** (ETH and Microsoft) needs an access request.
- **ScanNet++** needs an application.
- **ARKitScenes** (iPad Pro, indoor) ships ARKit's trajectory but not its laser-registered camera poses.
- **ADVIO**'s phone is from 2016.

**Method.** The same windows as section 1: from every image, the walk continues until the reference has covered 3, 10, 20 or 30 ft. ARKit's straight-line displacement is compared with the reference's. A walk's scale is the median ratio over windows of 10 ft or more. Distances need no axis alignment, which matters because ARKit's poses here are in Unity's axes.

**The reference's limits.** COLMAP from one moving camera has no scale of its own, and the dataset does not say how its reconstructions were put into meters. They could have been scaled to ARKit itself, which would hide any ARKit scale error. The phone's GPS is the only independent check shipped. Over these walks GPS is 1 to 9 m off, and it puts the reference's scale between 0.92 and 1.07 even on its 11 cleanest walks, so it cannot confirm or refute 2%. The reference's own accuracy is not published.

**Results.** Scale error of ARKit against the reference, per walk:

| Site | Walks | Median walk | Range |
| --- | --- | --- | --- |
| atrium | 10 | +0.3% | −50.7% to +1.0% |
| bar | 13 | +1.2% | −0.4% to +2.1% |
| church | 12 | −1.7% | −2.2% to −1.0% |

Thirty of 35 walks are within 2%. Three atrium walks read 18% to 51% short; on them, ARKit and the reference disagree about whether the phone moved at all between images, so the reference is in doubt there. Distance errors pooled over all walks, median / p90 inches:

| Walked | As tracked | Without the three doubtful walks |
| --- | --- | --- |
| 10 ft | 2.7 / 16.4 | 2.4 / 7.1 |
| 20 ft | 4.5 / 34.8 | 4.2 / 11.9 |
| 30 ft | 5.9 / 45.8 | 5.5 / 16.2 |

The 3 ft row in the results file is below what this reference resolves (images 0.2 to 1.4 m apart, and reference jitter up to 0.4 m), so it is not repeated here.

**Position error**, the same windows with ARKit's displacement turned by the heading offset at each window's start. ARKit's quaternions are (w, x, y, z) in Unity's left-handed axes, and each walk is paired with the reference by the handedness that keeps the heading offset steady: it holds to 0.6° over a median walk (worst 3.1°). Median / p90 inches:

| Walked | As tracked | Without the three doubtful walks | Server allowance, 0.16 ft per ft |
| --- | --- | --- | --- |
| 10 ft | 3.3 / 18.7 | 3.1 / 8.6 | 19.2 |
| 20 ft | 5.4 / 37.5 | 5.1 / 13.4 | 38.4 |
| 30 ft | 7.2 / 50.0 | 6.9 / 18.5 | 57.6 |

**Verdict.**
- **Within 2%?** Probably, for this phone; not proven. Against the only reference available, this 2022 iPhone's ARKit holds its scale within 2% on 30 of 35 outdoor walks, and each site's walks agree with each other to within about 1 to 2.5%.
- **What it means for section 3.** A pose scale error of about 2% is the first thing walls need, and this is the first evidence from a current phone that ARKit meets it. It is not enough: at 2%, walls still come out at a p90 of 5.0 in [3.8, 6.8] (section 3). The 2018 phone's 5% to 17% does not describe current hardware.
- **What stops it being settled:**
  - the reference's scale cannot be checked independently to 2%;
  - one site sits at a steady −1.7%, which is the phone's error or the reference's;
  - the phone has LiDAR, which ARKit may use.

The tape test on the team's phone is still the number to trust.

## Replay session from a real walk

`~/house-scanning-data/replays/advio-20-0040-0075.zip` holds 35 s of ADVIO walk 20 (seconds 40 to 75, a path past a brick building) in Measure Lab session format v2, for the app's replay mode. It has 79 keyframes chosen by Measure Lab's rule (0.5 m or 15° since the last), plus `ground_truth.json` with ADVIO's pose for each keyframe. `make replay` rebuilds and checks it.

- **Images.** `frames.mov` stores unrotated 1280 × 720 sensor frames behind a portrait display tag. They are decoded by index, since seeking by time lands frames off, and undistorted with ADVIO's calibration.
- **Intrinsics.** `[1082.1, 1081.1, 641.29, 359.91]`, from the portrait OpenCV calibration rotated to landscape and shifted half a pixel (`evals/camera.py`).
- **Poses.** `arkit.csv` orientations are in the portrait device frame. The converter turns them a quarter turn about the viewing axis. Image-derived rotations agree with this reading to a median 0.22° (alternatives: 4.5° to 6.5°).
- **Check.** `check_replay` reads only the session files and measures matched features' distance from the epipolar lines the poses predict: median 3.1 px, against 61 px with the axes deliberately wrong.
- **Missing from ADVIO.** No tracking state (written as `normal` once ARKit reports a position), no capture time (`startedAt` is the publication date), no taps or measurements. The camera points along the path, not at a wall.
