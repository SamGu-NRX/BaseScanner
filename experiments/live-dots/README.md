# Live dots

**Question.** Do dots built from recorded depth read as sitting on the wall's edges and surfaces, denser on edges and absent where unseen, at 60 fps with 6,000 dots? It passes if the painted meter, door and window outlines and the bin's silhouette carry edge dots while under 5% of plain-brick voxels do, no dot lands on wall the camera never saw, births ease in without a pop, and a 6,000-dot frame renders well inside 16.7 ms. The rules are in the header of `Sources/LiveDotsCore/DotField.swift`.

**Run.** Needs Xcode 27 and, for video, ffmpeg.

```
./fetch-fixtures.sh
swift run LiveDots
swift test
./make-video.sh [output folder]
```

The fixture is the synthetic wall from #10, and the no-LiDAR mode is simulated from its depth. Playback steps through keyframes at 4 per second.

**Result.** It passes. At the chosen 0.2 gradient, 100% of outline voxels and 1% of brick voxels become edges. The view holds 650 to 950 dots per keyframe, and nothing behind the bin. On an M4 Pro, 6,000 dots take 0.07 ms of GPU per 1170 × 2532 frame.

**What it changes.** Building this into `Map3DOverlay` (#21) needs a surface-sample iterator with per-frame deltas and a 5 cm point set beside the 10 cm map.
