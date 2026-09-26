# Edge geometry

## Question

Clearances start at edges: a window jamb, the side of an AC unit. Learned depth is 8 in or worse there. How much of that error lands along the wall, where the rules measure, and how does it depend on the angle a photo sees the edge from? Can an edge be placed better without reading depth at it?

The data is ETH3D electro and facade: photos within 6 m, and the evals' depth-edge points taken on their near side, so they are object edges rather than the wall behind them. The points are split into in-plane edges, within 5 cm of a wall plane, and proud edges. "Along the wall" means the horizontal component of the error within that wall plane. The view angle is measured between the ray and the wall's normal.

- **M0, depth at the pixel.** MoGe-2 depth, with each photo's scale set from the laser scan so that only the edge's own error remains.
- **M1, ray to the wall plane.** The plane is fitted to the same photo's depth on wall interior pixels.
- **M2, tap, snap and median.** A tap is jittered by σ = 10 px, snapped to the strongest vertical image edge within 25 px, and intersected with the wall plane. The median is taken over every photo that sees the point.
- **M3, two photos.** The edge is matched along the epipolar line by patch correlation and triangulated.

- **M1-anchor, the app's way.** The app intersects every feature tap with one plane, built from its single raycast at the meter (`ScanEngine+Actions.swift` on `t3/ios-mvf`). M1-anchor fits that plane to a 0.3 m patch around a wall point 1 to 3 m from the edge. The fit's yaw error ψ should move the edge by about s·ψ·tan(view angle), which is the suspected cause of #30.

M2 and M3 run with `exact` and `modern_assumed` poses.

## Pass criteria, fixed before the run

- **P1, angle.** M0's along-wall p90 at 0–15° is at most half its p90 beyond 30°.
- **P2.** M1's along-wall p90 on in-plane edges is at most 4 in. Reported beside it, not graded: M1-anchor, and its error against s·ψ·tan(view angle).
- **P3.** With `modern_assumed` poses, M2's along-wall p90 on in-plane edges is at most 2 in.
- **P4.** With `modern_assumed` poses, M3's 3-D p90 is at most 2 in, and at least 70% of points match.
- **Kill.** If M0 is already within 4 in along the wall at every angle, edges don't limit along-wall clearances.

## Result

Not run yet.
