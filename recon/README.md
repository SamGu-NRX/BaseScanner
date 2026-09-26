# recon: photos into a 3D model

The reconstruction worker. It takes the app's scan bundle (keyframe photos, their AR poses and intrinsics, `scene.json`) and returns:

1. `model.glb`: a colored mesh of the scanned area, in the meter's frame (origin at the meter's foot, y up, meters), viewable in macOS Quick Look;
2. `geometry.json`: the fitted wall and ground for the rules engine, in feet, in the scene frame and in the meter's wall frame;
3. `coverage.json`: which wall, ground, facing and overhead cells were actually seen, by a depth test against the reconstruction;
4. `scene.json`: the scene updated with that geometry and coverage in the server's contract, posted to the placement server, with its answer in `result.json` and `site-plan.svg`.

```sh
cd recon
uv sync
make run BUNDLE=path/to/scan.zip OUT=path/to/out      # or a Measure Lab session, zip or folder
make test                                             # unit tests and lint, as CI runs them
make accept                                           # ETH3D acceptance (prepared data needed)
```

## Acceptance criteria, fixed before the first acceptance run

- **Coverage on ETH3D electro's wall**: wall the worker calls observed where at least 10 cm of the band was seen by no photo, against the laser scan's visibility, must be at most **0.5 ft**. This is the bar and metric of experiments/evals README section 7 (t3/evals), where the app's own coverage map claimed 1.1 ft.
- **Wall geometry on ETH3D electro**: reported in inches against the laser scan, with no pass bar set in advance. It covers the fitted wall plane's offset and angle, and the reconstruction's point at each pixel where a laser wall point is seen, as point-pair errors over 1 to 3 m spans, the evals' metric.
- **End to end**: the ADVIO replay and the app's Simulator bundle each reach a placement-server result.

## Results

`make accept` on ETH3D electro ([results/eth3d_electro.md](results/eth3d_electro.md)):

| Depth | Wall pair error, 1–3 m, median / p90 | Wall claimed | False-observed |
| --- | --- | --- | --- |
| Laser scan standing in for LiDAR | 0.6 / 2.1 in | 25.5 of 31.9 ft | 0.46 ft (passes) |
| MoGe-2 rescaled with the poses | 0.5 / 2.8 in | 14.8 of 15.8 ft | 0.39 ft (passes) |

The two paths chose different stretches of wall, so their geometry rows are not directly comparable. The ADVIO replay and the app's Simulator bundle each reach a server result (`manual_review`: the ADVIO camera looks along its path, so little wall is seen head-on). The Simulator bundle needs `ARGS=--move-meter`, because its replayed wall has no surface behind it.

The handoff to the server team, with everything measured and reusable, is [HANDOFF.md](HANDOFF.md).
