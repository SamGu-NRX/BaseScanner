# Evals on real data

## Questions

1. How far is ARKit's tracking off after walking 3, 10, 20 and 30 ft outdoors? The untested default for an AR tap is plus or minus 0.3 ft (3.6 in; `docs/00`, Conventions the code relies on).
2. How accurately can phone photos reconstruct a real building wall, with the model's own scale or with one taped distance, from one photo or several?
3. Can the phone's AR poses fix the learned models' scale, well enough for about 4 in at p90 on 1 to 3 m spans, the error that decides a 3 ft clearance?
4. Which photos are worth keeping?
5. On a real field session with a tape survey, how do the phone's AR taps and the learned-depth methods compare, and what is the phone's AR scale error?
6. How large is a current iPhone's ARKit scale error, from public data?
7. Does the app's coverage map claim wall and ground that no photo saw?

Every dataset evaluation uses real captures. Two checks add synthetic inputs, and are labelled where they appear: section 3's pose-prior rows degrade ETH3D's true poses with simulated AR-like error, and `make field-dryrun` scores a synthetic session to prove the field command. The unit tests of the metric code also use synthetic cases.

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

9. **Does the app's coverage map claim surface no photo saw? Yes, on the one wall tested: 1.1 ft of 19.3 ft claimed (6%), against a bar of 0.5 ft.** All of it sits behind equipment standing in front of the wall (a scaffold's footings and cables), because the coverage code checks range, angle and image bounds but not occlusion (`CoverageMap.swift` lines 241 to 248 at beede15). The ground band and facade could not be tested: ETH3D's photographers stood too far from the walls for the app to credit any ground, or any of facade (section 7). Requiring views farther apart or at wider angles does not fix it without discarding good wall (6 to 8.5 ft here). A depth test against true depth does, which needs LiDAR (section 7b).

10. **The app's 3D map (Map3D), LiDAR path, ideal depth: no wall claimed that no photo saw, where `CoverageMap` claimed 1.1 ft.** It misses 8.9 ft, 5.5 ft of it behind pilasters that stand out past its 10 cm face window. Its wall line runs 1.76° off and 4.8 in out at the meter. The non-LiDAR path, ground and overhead are untested, and its one facing claim sits below the truth's resolution (section 7c).

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
make field SESSION=... TRUTH=... MAP=...   # a field session, section 5; PR #4's harness is checked out at a pinned commit
make modern-arkit  # MARViN pose files (about 3 MB) -> results/modern_arkit.md, section 6
make coverage      # after recon-data; the app's coverage code at a pinned commit -> results/coverage.md, section 7
make coverage-options  # after coverage -> results/coverage_options.md, section 7b
make map3d         # after coverage; the app's Map3D at a pinned commit -> results/map3d.md, section 7c
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

**In the field:** [field/FIELD_SHEET.md](field/FIELD_SHEET.md) lists what to bring, mark, tape and tap, in order, with the Measure Lab numbers the map expects. `field/survey.template.json` and `field/map.template.json` name every item, so the team fills in only tape readings, typed as the tape shows them (`30 0 1/8`). `make field` converts them to feet and fills in the zip's sha256 and session id. `make field-dryrun` builds a synthetic session in the sheet's order, fills the templates, and runs `make field` with them. It recovers the planted 1.5% AR scale error (−1.50% ± 0.68%) and gets all four rows through PR #4's `score`.

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
- **Walk-to-walk floor.** A reference scaled to ARKit would carry one scale per site, so the spread between one site's trusted walks survives it. That spread is 0.28% [0.12, 0.36] at atrium, 0.75% [0.46, 0.94] at bar and 0.34% [0.19, 0.44] at church (1 SD, 95% interval), so a single walk's scale error is at least about 0.3% to 0.8%.
- **What it means for section 3.** A pose scale error of about 2% is the first thing walls need, and this is the first evidence from a current phone that ARKit meets it. It is not enough: at 2%, walls still come out at a p90 of 5.0 in [3.8, 6.8] (section 3). The 2018 phone's 5% to 17% does not describe current hardware.
- **What stops it being settled:**
  - the reference's scale cannot be checked independently to 2%;
  - one site sits at a steady −1.7%, which is the phone's error or the reference's;
  - the phone has LiDAR, which ARKit may use.

The tape test on the team's phone is still the number to trust.

## 7. Does the app's coverage map claim surface no photo saw? (ETH3D)

[results/coverage.md](results/coverage.md), `make coverage`.

**Why.** Every placement check rests on "unseen is not clear": the server passes a check only over the wall and ground the app exports as observed. That export is `CoverageMap.coveredIntervals` (`ios/HouseScanKit`), whose own comment says occlusion is not modelled. Nobody had tested it against what the photos actually saw.

**Method.**
- **The app's code, unmodified.** `ios/HouseScanKit` at commit beede15 of `t3/ios-mvf`, checked out read-only outside the repo and run by `coverage_driver/` with its default `CoverageConfig`. Every ETH3D photo is a kept keyframe with normal tracking, fed in capture order.
- **The wall, as taps would give it.** Per scene, the straight stretch of wall that the most photos see within the app's 6 m. The meter sits mid-stretch, 1.5 m up. The outward normal comes from a plane fit to the scan, the ground height from the scan at the wall's foot, and the marked ends are the stretch's ends. The world is levelled on the ground plane under the cameras, because ARKit's y is up. Poses and intrinsics go in unrotated, in ARKit's camera axes.
- **Truth.** Columns 2 cm wide along the wall, each band sampled every 5 cm up the wall or out across the ground. A photo saw a sample when all of these hold:
  - it lands inside the full image;
  - it is within the app's 6 m;
  - the camera is on the room side of the wall;
  - nothing nearer hides it. "Nearer" means more than max(10 cm, 4% of depth) in front in the laser scan's depth, with ETH3D's occlusion splats included; ETH3D's masks of objects missing from the scan (people, vegetation) also count as hiding.

  Grazing angle is not part of the truth: an oblique photo still saw the surface, and the app's 65° limit shows up only as missed length.

**Pass criteria, fixed before the run.**
- **False-observed length**: wall claimed as observed where at least 10 cm of the band (2 samples) was seen by no photo. Must be at most 0.5 ft, one 6-in cell, per scene and band; that is what "about zero" means here. It is also reported as a share of claimed length, and split by the cause at the photos the app credited: occlusion, range, frame edge. Grazing angle cannot cause it under this truth. A stricter variant counts band seen from fewer than two positions 0.25 m apart, the app's own bar for "covered"; it is reported, not graded.
- **Missed length**: band every sample of which two photos 0.25 m apart saw, which the app did not credit. No pass bar, since it costs the homeowner extra photos, not a wrong answer. It is split by why the app turned those photos down: frame edge (including its 3% margin and the band's top or bottom out of view), range, grazing angle, or only one position.
- **Validity checks**: my replica of the app's view gates (used only to name causes) must reproduce the app's own sightings, and the wall plane must fit the scan within a few centimetres.

**Results.** Lengths in feet along the wall.

| Scene | Band | Claimed | False-observed (share) | Pass | False-observed, 2-position truth | Missed |
| --- | --- | --- | --- | --- | --- | --- |
| electro | wall | 19.3 | 1.1 (6%), all occlusion | no | 1.3 (7%) | 0.0 |
| electro | ground | 0.0 | 0.0 | untested | 0.0 | 18.1, all grazing angle |
| facade | both | nothing: no wall within 6 m of any photo | | untested | | |

- **Where the 1.1 ft is.** 1.05 ft is the bottom 20 cm of the wall at the stretch's left end, behind a scaffold's wooden footings and a cable bundle standing in front of the wall. The app credits it because the photos that frame it are within range and angle; no photo sees behind the footings. The other 0.07 ft is one 2 cm column at a pilaster's edge, within the scan's resolution.
- **Ground: untested.** The app claimed no ground on electro. The ETH3D photographers stood 2.0 to 7.6 m from the wall (median 4.9 m). A camera 1.5 m up must be within 3.2 m for the ground at the wall's foot to be inside the app's 65°, so every ground view was turned down: 18.1 ft seen from two positions and not credited. At the app's intended 2.6 m standoff the ground would be claimed, so these photos cannot say whether that claim would be right.
- **Facade: untested.** The building stands beyond the app's 6 m from every photo: 99% of its wall-height scan points are 6.5 m or more from the nearest photo, with a median of 11.6 m. Within range are only stair flanks, sculptures and tree trunks, none a straight wall that a photo sees 1 m of. The app claims nothing there.
- **Validity.** The replica of the app's view gates reproduces all 337 of its sightings exactly. The flat parts of the wall fit the plane to 1.8 cm RMS. Two pilasters stand 0.36 m proud of it (3.8 ft of the 19.3), so the truth samples their front faces; with the plane alone they read as 2.8 ft of false occlusion. No claimed sample was credited only where the scan is empty. Peak memory 1.3 GB.

**Verdict.**
- **Does coverage claim unseen wall? Yes: 1.1 ft of 19.3 on electro (6%), where "about zero" allowed 0.5 ft. It fails.** All of it is occlusion, and that is the rule, not bad luck. At commit beede15, `CoverageMap.swift` lines 241 to 248 (`sees`, inside `visibleRows`) accept a sample on range, angle and image bounds alone; nothing checks whether something stands between camera and wall. The type's own comment (lines 57 to 59) says so, and adds that "the server re-checks what matters from the images". The server's contract says the opposite: it passes a check over whatever the app reports as observed. The loss is small here only because 17 photos from many angles see around most of the scaffold. A bush, a bin or an AC unit in front of a wall is claimed as observed whenever the phone stands in front of it.
- **What would fix it (for S3):**
  - Give `CameraFrame` an optional per-frame depth map: ARKit's `sceneDepth` on LiDAR phones, or depth rendered from ARKit's mesh.
  - In `sees`, reject a sample when that depth at its pixel is nearer than the sample by more than max(10 cm, 4%), the tolerance used here.
  - Sample more rows, or check depth along each row-to-row segment. With `rowsPerBand = 3` (lines 43 to 47) the rows are 0.99 m apart, so something mounted between them passes even a depth check at the rows.
  - Phones without depth can't make this check on the device. Until one side changes, either the server re-checks occlusion from the images, as the comment assumes, or the export must not be read as "seen and clear".
- **Missed wall: none.** Everything two photos saw, the app credited.
- **Limits.** One scene, one 19 ft wall, 17 contributing DSLR photos, not a walking phone capture. The truth ignores anything within max(10 cm, 4% of depth) of the wall (downspouts, conduit), which can only have hidden more false-observed length, not less.

### 7b. Options for occlusion (ETH3D electro)

[results/coverage_options.md](results/coverage_options.md), `make coverage-options`.

**Question.** Which rule change stops coverage from claiming unseen wall, and at what cost in extra photos? The same harness, wall and truth as section 7. Each option is modelled in `coverage_driver/`, around the app's code at beede15, which stays unedited:
- **Position baseline b**: `CoverageConfig.coveringBaseline` (`CoverageMap.swift` line 49, used at line 181), swept at 0.25 (today), 0.5, 1 and 2 m. No LiDAR needed.
- **Angle diversity θ**: the predicate in `record` (lines 180 and 181) also requires the two views' directions to the row's centre to differ by at least θ, swept at 0°, 15°, 30° and 45°. It is crossed with b. No LiDAR needed. At θ = 0 and b = 0.25 the driver's copy of `record` must reproduce the app's own answer exactly.
- **Depth test (LiDAR)**: `sees` (lines 241 to 248) also rejects a row sample that the laser scan, standing in for LiDAR depth, shows hidden. The same test and tolerance as the truth, and ETH3D's masks count, because LiDAR sees people and trees too. Three settings:
  - true depth out to the app's 6 m, 3 rows (the ceiling);
  - the same with 9 rows (`rowsPerBand`, lines 43 to 47);
  - 9 rows with no depth beyond 5 m, the iPhone LiDAR's stated range.

**Pre-registered, before any run.** An option passes when false-observed length on electro's wall is at most 0.5 ft, as in section 7. Missed length is measured against the same truth for every option: band seen from two positions at least 0.25 m apart. The recommendation is the passing option with the least missed length, preferring one that needs no LiDAR when two are within 1 ft of each other.

**Results** on electro's 19.3 ft wall, in feet: false-observed (pass at 0.5 or less) and missed (band two photos saw that the option doesn't claim). The full grid is in the results file.

| Option | Needs LiDAR | False-observed | Pass | Missed |
| --- | --- | --- | --- | --- |
| The app today (b = 0.25 m, θ = 0°) | no | 1.1 | no | 0.0 |
| Views ≥ 2 m apart, any angle up to 45° | no | 1.1 | no | 0.0 |
| Views ≥ 5 m apart* | no | 0.0 | yes | 6.0 |
| Views ≥ 60° apart* | no | 0.0 | yes | 8.5 |
| Depth test, true depth to 6 m, 3 or 9 rows | yes | 0.0 | yes | 3.3 |
| Depth test, 9 rows, no depth past 5 m | yes | 0.0 | yes | 7.8 |
| Depth test, 9 rows, 0.4 m of wall relief allowed* | yes | 0.1 | yes | 0.0 |

\* Added after the pre-registered grid (b 0.25 to 2 m, θ 0 to 45°) changed nothing.

- **Spacing or angle between views: no.** Nothing in the pre-registered grid moved the 1.1 ft. The footings hide the wall's base from every direction the photos were taken from, and seeing a cell from far-apart or differently angled views says nothing about whether something stands in front of it. The patch goes only when the rule refuses cells for want of spread: at 5 m apart (6.0 ft lost) or 60° apart (8.5 ft lost, 47% of what was seen). It is removed along with good wall, not singled out. At 75°, nothing is claimed.
- **Depth test: yes, at a price the rule's shape sets.** With true depth it claims nothing unseen. The 3.3 ft it misses is the two pilasters. A tapped wall is a plane, so a pilaster 0.36 m proud of it reads as something in front of the wall, and a real LiDAR test would do the same. Allowing 0.4 m of relief keeps them (0 missed) and still rejects the footings (0.1 ft). At 0.5 m the footings get through (1.0 ft). That margin was found on this one wall and says nothing about bushes closer than 0.4 m. Nine rows instead of three changed nothing here, because the hidden patch touches the bottom row. It would matter for something mounted between rows.
- **LiDAR's reach costs coverage.** iPhone LiDAR reads to about 5 m; photos 5 to 6 m out then earn nothing, which misses 7.8 ft on these DSLR photos. At the app's 2.6 m standoff that limit would rarely bind.
- **Ground band: still untested.** Every option keeps the 65° gate, so none claims ground from these photos. None of the datasets on disk can test it: ADVIO and MARViN have no surface truth, and facade's photos stand even farther back. ETH3D's other outdoor scenes carry the same laser truth, at 0.3 to 0.7 GB each with images (courtyard, delivery_area, meadow, playground, terrace). Whether their photographers stood within 3.2 m of a wall can only be read after downloading, so I did not.

**Recommendation.** Stay with "unseen is not clear" and make occlusion someone's job, because no rule about how the phone moved can stand in for it:
- **LiDAR phones:** a depth test in `sees` (`CoverageMap.swift` lines 241 to 248), with rows closer than 0.99 m and an allowance for wall relief. The allowance needs field data before a number ships.
- **Phones without LiDAR:** the app cannot know what hides the wall. Either the homeowner confirms nothing stands in front of each claimed stretch (for example, by marking obstacles on a still), or checks that need clear ground treat claims from those phones as unconfirmed.

Tightening the baseline or angle would only ask for more photos: 6 to 8.5 extra feet of wall here, with no guarantee that the hidden patch goes.

### 7c. The app's 3D map (Map3D) against the same truth (ETH3D electro)

[results/map3d.md](results/map3d.md), `make map3d`.

**Question.** The app's live 3D map (`ios/HouseScanKit/Sources/HouseScanKit/Map3D`, t3/ios-map3d at 66cdcba, draft PR #21) is to replace `CoverageMap` on every phone. Does it claim wall, ground, facing or overhead space no photo saw?

**Method.**
- **The app's code, unmodified**, checked out read-only and driven by `map3d_driver/`: `Map3D.integrate(DepthFrame)` per photo, then `coverage(along:)` and `measuredWalls()`, default `Map3DConfig`.
- **The same wall as section 7:** the map frame and the `WallFrame` coverage is read along are section 7's (meter, outward normal, ground height).
- **LiDAR path:** one depth frame per photo, 256 x 192, rendered from the laser scan at the photo's pose (nearest scan depth along -z; 0 where nothing was scanned or ETH3D masks an object the scanner missed), with no confidence.
- **Non-LiDAR path: not tested.** It needs ARKit's feature points and detected planes. COLMAP's tracks on 24-megapixel DSLR photos are far denser and more exact than ARKit's feature points, and ARKit's plane detector can't be reproduced from them without guessing.
- **Truth.** Wall and ground: section 7's laser-scan visibility, on the same wall face and ground band (1.2 m, the depth `CoverageMap` claims). Map3D's ground counts as claimed where its reach is at least 1.2 m. Facing and overhead space: a point counts as seen empty when some photo within 5 m frames it and the laser scan's depth at its pixel lies beyond it by more than the section 7 tolerance, max(10 cm, 4%), so the ray passed through it.

**Pre-registered, before any run.**
- **False-observed** (claimed columns where at least 10 cm of what the band claims was seen by no photo) must be at most **0.5 ft** per band, as in section 7, where `CoverageMap` claimed 1.1 ft of wall.
- **Missed** (wall and ground band seen from two positions 0.25 m apart but not claimed) is reported without a bar.
- **Wall chain:** the measured wall piece through the meter against the laser's wall line (angle, offset at the meter, length), reported without a bar.

**Results** (ideal depth: exact, dense, no sensor noise). Feet along the wall.

| Band | Claimed | False-observed | Pass | Missed |
| --- | --- | --- | --- | --- |
| Wall, `CoverageMap` (section 7's 19.3 ft stretch) | 19.3 | 1.1 | no | 0.0 |
| Wall, Map3D, same stretch | 11.1 | 0.0 | yes | 6.9 (6.1 with a 5 m truth) |
| Wall, Map3D, everything it claims (s −9.7 to +21 ft) | 19.4 | 0.0 | yes | 8.9 of 25.2 seen, 5.5 of it on pilaster faces |
| Ground | 0.0 | 0.0 | untested | 18.1 |
| Facing | 0.5 | 0.5 (see below) | unresolved | n/a |
| Overhead | 0.0 | 0.0 | untested | n/a |

- **Wall: Map3D claims no wall that no photo saw, where `CoverageMap` claimed 1.1 ft.** The 1.1 ft behind the scaffold's footings is left unclaimed, as the depth test of section 7b predicted.
- **The cost is missed wall.** 5.5 ft of the 8.9 ft missed is behind pilasters 0.36 m proud of the wall line. Map3D counts the face only within 0.10 m in front of the line (`faceFront`, `Map3DConfig.swift` line 85 at 66cdcba, used in `Map3DCoverage.swift` lines 73 to 86), so a pilaster hides the wall behind it. That is conservative, not an over-claim. It asks for views that cannot exist, so the gap loop could ask forever for a pilaster-backed stretch.
- **Ground and overhead: untested.** Map3D claims no ground: reach 0 everywhere, the same grazing-view limit as section 7.
- **Facing: unresolved.** Map3D's one claim is a single 6 in cell seen clear 0.1 m out from a door face. By the pre-registered metric it reads 0.52 ft, just over the bar. The truth, however, cannot resolve space that close to a surface: it needs the laser surface to lie beyond a point by 4% of the distance, 12 to 20 cm here. So the claim is neither confirmed nor refuted, and a 0.1 m reach settles no check (the server needs more than 4.83 ft).
- **Wall chain:** one piece through the meter, 28.4 ft long, where the laser's wall face (pilasters included) runs 30.8 ft. The left end is 0.3 ft short and the right 2.2 ft short. The line is 1.76° off the laser face and 4.8 in outside it at the meter, more than the server's 3.6 in default meter error. The cause is not established.
- **Not measured:** the non-LiDAR path, real LiDAR noise and dropouts, and coverage along Map3D's own chain instead of section 7's wall line. An independent review of the method also flagged a rule to check: `VoxelGrid.swift` lines 376 to 378 and 409 to 412 at 66cdcba take the nearest view distance and the best view angle from possibly different views, so a surface can pass the 5 m and 65° tests with no single view meeting both. It caused no false-observed wall here.

## Replay session from a real walk

`~/house-scanning-data/replays/advio-20-0040-0075.zip` holds 35 s of ADVIO walk 20 (seconds 40 to 75, a path past a brick building) in Measure Lab session format v2, for the app's replay mode. It has 79 keyframes chosen by Measure Lab's rule (0.5 m or 15° since the last), plus `ground_truth.json` with ADVIO's pose for each keyframe. `make replay` rebuilds and checks it.

- **Images.** `frames.mov` stores unrotated 1280 × 720 sensor frames behind a portrait display tag. They are decoded by index, since seeking by time lands frames off, and undistorted with ADVIO's calibration.
- **Intrinsics.** `[1082.1, 1081.1, 641.29, 359.91]`, from the portrait OpenCV calibration rotated to landscape and shifted half a pixel (`evals/camera.py`).
- **Poses.** `arkit.csv` orientations are in the portrait device frame. The converter turns them a quarter turn about the viewing axis. Image-derived rotations agree with this reading to a median 0.22° (alternatives: 4.5° to 6.5°).
- **Check.** `check_replay` reads only the session files and measures matched features' distance from the epipolar lines the poses predict: median 3.1 px, against 61 px with the axes deliberately wrong.
- **Missing from ADVIO.** No tracking state (written as `normal` once ARKit reports a position), no capture time (`startedAt` is the publication date), no taps or measurements. The camera points along the path, not at a wall.
