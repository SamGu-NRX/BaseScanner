# Live dots

**Question.** Do dots built from recorded depth read as sitting on the wall's edges and surfaces, denser on edges and absent where unseen, at 60 fps with 6,000 dots? It passes if the painted outlines and the bin's silhouette carry edge dots while under 5% of plain-brick voxels do, no dot lands on unseen wall, births ease in without a pop, and 6,000 dots render well inside 16.7 ms. The rules, sizes and colours are in the header of `Sources/LiveDotsCore/DotField.swift`.

**Run.** Needs Xcode 27 and, for video, ffmpeg.

```
./fetch-fixtures.sh
swift run LiveDots
swift test
./make-video.sh [output folder]
```

`./make-video.sh` and `LiveDots --still` produced `results/`; its stills are downscaled to 800 px.

`--scheme hologram|constellation|ember`, or the Look picker, switches between three looks for comparison: the current one, edges only joined by hairlines, and new dots born amber that cool to white over 6 s.

The fixture is the synthetic wall from #10. The no-LiDAR mode is simulated from its depth: feature points use a 0.1 gradient, since ARKit finds them on brick texture too, and live while seen in 2 of the last 6 keyframes, where the real app would use 3 of 10 at frame rate.

**Result.** It passes. At 0.2, 100% of outline voxels and 1% of brick voxels become edges, and nothing draws behind the bin. On an M4 Pro, 6,000 dots with halos take 0.54 ms of GPU per 1170 × 2532 frame.

**What it changes.** Building this into `Map3DOverlay` (#21) needs a surface-sample iterator with per-frame deltas and a 5 cm point set beside the 10 cm map.
