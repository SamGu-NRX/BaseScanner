# Plane consistency

## Question

Without LiDAR, can the photos themselves show that something stands in front of the wall? A photo keeps credit for a wall sample only when another photo agrees with it through the wall plane. It runs on the 19.3 ft wall of evals §7, where coverage claims 1.1 ft hidden behind scaffold footings. [METHODS.md](METHODS.md) has the matching rule.

## Pass criteria, fixed before the run (397507f)

- **False-observed.** Wall claimed where at least 10 cm of band was seen by no photo: at most 0.5 ft, as in §7.
- **Missed.** Band that two photos 0.25 m apart saw, left unclaimed: at most 3.3 ft, which is what the LiDAR depth test with no relief allowance misses.
- Both must hold with `modern_assumed` poses. Missed length is split into no qualifying pair, too plain, and disagreed.

## Result

Both fail ([tables](results/plane_consistency.md)). Without the filter the setup reproduces §7 exactly. With it, the worst `modern_assumed` draw claims 1.1 ft that no photo saw, because pairs agree on the footings inside the 0.4 m relief the pilasters need. It also misses 9.2 ft, 5.1 of it wall too plain to correlate.

**Run:** `uv run python run.py`: 2 min, 0.9 GB. Needs the evals checkout at 190ed33 and ETH3D electro.

**What it changes:** photo agreement doesn't replace a depth test on phones without LiDAR. Coverage from those phones stays unconfirmed, as §7b recommends.
