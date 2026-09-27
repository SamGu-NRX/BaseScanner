# Plane consistency: methods and full results

The README is the front door. This file keeps the method as it was pre-registered in 397507f, and the full result as the run reported it.

## Question

Without LiDAR, can the photos themselves show that something stands in front of the wall? Today coverage credits a wall sample to any photo that frames it within range and angle, so on ETH3D electro it claims 1.1 ft of wall hidden behind scaffold footings (evals §7). On phones without LiDAR, the only known fix, needing views 5 m or 60° apart, also throws away 6 to 8.5 ft of good wall (§7b).

A photo keeps credit for a sample only when another photo agrees with it. The two are compared through the wall plane: each patch is warped onto the plane, the plane is slid 0 to 0.4 m toward the camera to allow for wall relief, and a match needs normalized cross-correlation (NCC) of at least 0.6 on 11 × 11 px patches.

A pair can speak for a sample only when it has at least 3 px of parallax between the wall and a surface 0.5 m in front of it. A sample no pair can test, or one too plain to correlate, is not claimed.

The wall, its samples, the app's view gates and the truth are those of evals §7, imported from `t3/evals` at `190ed33`. It runs with the `exact` and `modern_assumed` poses.

## Pass criteria, fixed before the run

- **False-observed.** Wall claimed where at least 10 cm of band was seen by no photo: at most 0.5 ft, as in §7.
- **Missed.** Band that two photos 0.25 m apart saw, left unclaimed: at most 3.3 ft, which is what the LiDAR depth test with no relief allowance misses.
- Both must hold with `modern_assumed` poses. Missed length is split into no qualifying pair, too plain, and disagreed.

## Result

Both fail ([results](results/plane_consistency.md)). Unfiltered, the setup reproduces §7: 19.3, 1.1, 0.0 ft.

- **False-observed.** Worst draw 1.1 ft, exact 0.7. Pairs with 12 to 43 px of parallax agree on the footings at δ = 0.3 or 0.4 m, so the relief that keeps the pilasters keeps the footings too.
- **Missed.** Worst draw 9.2 ft: 5.1 too plain, 4.1 disagreed, 0 without a pair. At 1024 px most of the wall is nearly featureless. Too plain means a standard deviation under 0.91 grey levels, where noise of 0.57 holds even a perfect match below NCC 0.6.

**Run:** `uv run python run.py`, 2 min, 0.9 GB. Needs the evals checkout at 190ed33 (`EVALS_DIR`) and ETH3D electro. `modern_assumed` is redrawn over all 45 photos, since `ar_poses/*.json` holds only groups of 2 to 8.

**What it changes:** photo agreement doesn't replace a depth test on phones without LiDAR. Claims from those phones stay unconfirmed, as §7b recommends.
