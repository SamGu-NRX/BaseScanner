# Implementation plan

> Day-1 plan from 2026-09-25, kept for its reasoning and citations. Where it conflicts with [00-overview.md](00-overview.md) or a component README, those win.

The main trick is to unroll the house's walls into one straight line, measured in feet from the meter. Almost
every rule then becomes a check on a 1-D number line, and the placement code gets simple.

## Overall setup

```
iPhone (Swift, ARKit)  ──upload .zip──▶  Python server (FastAPI)  ──result──▶  iPhone AR preview
  collects measurements + photos           1. read the upload, build the wall line          + 2D site plan
                                           2. find objects, cast them onto the wall
                                           3. rule checks → pick a spot
                                           4. recognition prompts on the close-ups
```

The phone only collects data; all the logic runs on the server. Placement code can then be tested against saved
captures without anyone walking a house.

Repo layout:

```
/ios        Xcode project
/server     ingest.py  geometry.py  detect.py  solver.py  rules.yaml  plan_svg.py  prompts/
/fixtures   saved captures (fake-01 hand-built in hour 1; real ones gitignored)
/eval       tape-measure ground truth
/docs       these docs
/private    materials not for publication (gitignored)
```

## Lane A: Capture app

AR setup:

```swift
let config = ARWorldTrackingConfiguration()
config.planeDetection = [.horizontal, .vertical]
config.worldAlignment = .gravity                    // NOT .gravityAndHeading (compass unreliable near a house)
if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
    config.sceneReconstruction = .meshWithClassification   // LiDAR phones only
}
if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
    config.frameSemantics.insert(.sceneDepth)
}
arView.automaticallyConfigureSession = false        // otherwise RealityKit turns classification off
arView.session.run(config)
```

Capture flow (P0). Use taps rather than automatic wall detection, so the demo can't break:
1. **"Tap the meter."** Raycast from the tap to a vertical surface and add an `ARAnchor`. That's the zero point.
2. **"Walk left until the wall ends, then tap the end."** Then right. Tap each corner. The taps define the wall line.
3. **Save frames while walking** (~every 0.5 m or 15°): `capturedImage` saved unrotated, `camera.transform`,
   `camera.intrinsics`, optional `sceneDepth.depthMap` (256×192; the server scales K down to match).
   `captureHighResolutionFrame` gives sharper stills and still includes the pose.
4. **Tap-to-mark buttons:** gas meter, door, garage door, window, AC, driveway edge.
5. **Guided close-ups** for the recognition checks. Photo checks run on the phone: sharpness (Laplacian variance), and Apple
   Vision `RecognizeTextRequest` + `VNDetectBarcodesRequest` on the meter.
6. **Mesh export:** for each `ARMeshAnchor`, multiply every vertex by `meshAnchor.transform` (vertices are local to the anchor),
   **copying them out** of ARKit's `MTLBuffer` rather than writing back into it. Indices are uInt32. Write the PLY by hand
   so each face can keep its classification (wall/door/window).
7. Zip `scene.json` + JPEGs + `mesh.ply` and upload with a **foreground** `URLSession`.
8. Take GPS + one compass reading with `CLLocationManager` (trust it only if `headingAccuracy` ≤ 20°).

## Lane B: Geometry and detection (server)

**The wall line (`geometry.py`).** Chain the tapped points (left end → corners → meter → corners → right end) into
a line along the ground. Every point on the house gets one coordinate `s`: feet from the meter, negative to the left.
Each segment also stores its outward direction and ground height.

**Casting a box onto the wall:**

```python
def pixel_ray(u, v, K, cam_to_world):
    # ARKit camera: +x right, +y up, looks down -z; image v grows downward (Rerun calls this RUB)
    d = np.array([(u - K[0,2]) / K[0,0], -(v - K[1,2]) / K[1,1], -1.0])
    d = cam_to_world[:3,:3] @ d
    return cam_to_world[:3,3], d / np.linalg.norm(d)

def hit_plane(o, d, p0, n):
    denom = d @ n
    if abs(denom) < 1e-6: return None
    t = ((p0 - o) @ n) / denom
    return o + t*d if t > 0 else None
```

- **Things on the wall** (windows, doors, boxes): cast rays from the box's left and right edges into the wall plane → the `s` range + height above ground.
- **Things on the ground** (AC unit, gas meter): cast the mask's bottom-center into the ground plane, then snap to the nearest wall point.
- **Merging duplicates:** merge same-type detections whose `s` ranges overlap, and take a majority vote on attributes.
- ⚠️ `capturedImage` is landscape (the way the sensor reads it) and `intrinsics` match it. Rotate one and you must rotate the other.
  Gemini returns `[ymin, xmin, ymax, xmax]` on 0–1000, so convert to pixels of the **unrotated** image.
- **Test this in hour 2:** tap a point, cast it back into a saved frame, and check it lands on the right pixel.

**Mesh measurements (Open3D `RaycastingScene`, float32 rays, a miss = `inf`).** Every 2″ along the wall:
- Passage width: a ray straight out from the wall at 1.5 ft height.
- Headroom: a ray straight up from 1 ft out from the wall.
- The mesh has holes, so cast a small fan of rays and take a robust minimum. A miss beyond ~5 m (the LiDAR limit) means **unknown**, not "open".

## Lane C: Placement code (`solver.py`)

Every measurement carries an error estimate: ±0.3 ft for AR taps, ±0.5 ft for the mesh, ±1.5 ft for anything placed from
a model's photo detection. A check answers **PASS** if the margin is larger than the error, **FAIL** if it's clearly
violated, and **UNSURE** otherwise.

```python
W = rules.battery.width_ft  # 31/12
for s in np.arange(scene.s_min, scene.s_max - W, 1/6):              # 2-inch steps
    spot = Spot(s, s + W, depth=rules.battery.depth_ft)
    checks = [c(scene, spot, rules) for c in CHECKS]               # gas, drive, pool, openings, box_above,
    route  = harness_route(scene, spot, rules)                     # vent, ac, front, overhead, ground, street_facing
```

- **Distance checks** (gas meter, pool, driveway): the spot is a 2D rectangle against the wall; use shapely `distance`.
- **Checks along the wall** (openings, AC, box above, vent): numpy overlap `max(a0,b0) < min(a1,b1)`. The ComEd rule widens each opening by 3 ft on both sides.
- **Cable route:** the path from `s=0` to the spot along the unrolled line. It fails if it crosses a door or garage interval or a stretch with no wall.
  Its length is |s| plus a little per corner. Past a configurable "confident reach" it's UNSURE; over the max it's FAIL.
- **Decision:**
  - **pass:** some spot passes every check. Pick the shortest run, preferring side walls.
  - **manual_review:** some spot has no FAIL but at least one UNSURE. Report those reasons.
  - **reject:** both wall ends were reached and every spot FAILs.
  - If the wall wasn't walked to its end → manual_review + missing views.
- A brute-force sweep is enough: ~1,200 positions × tens of checks runs in under a second. No OR-Tools or z3.

## Lane D: Output, prompts, testing

- **AR preview:** the server returns the spot **relative to the meter's anchor**. The app attaches a `ModelEntity`
  (`MeshResource.generateBox`, 31″ × 22″ × 39.5″) to that anchor, plus thin cylinders for the cable. Keep the AR session running
  while the server works; relocalizing later with an `ARWorldMap` is P2.
- **2D site plan:** drawsvg; blue meter area, purple cable run, red battery spot and its clearance.
- **Recognition prompts:** load them from `private/` at runtime. `server/prompts/` is gitignored. Never commit prompt text; this repo is public.
- **Testing:** tape-measure 10–15 distances on one real house. Compare AR, Depth Anything 3 on plain photos, and the
  vision model's guesses. The error table is the pitch slide.
- **Debugging:** Rerun. Log camera positions (`Pinhole`, `camera_xyz=RUB`), frames, mesh (static), wall line, detections and solver rays.

## Schedule (~24 h; stretch it for longer)

| Hours | Everyone |
|---|---|
| 0–2 | Lock `scene.json`. Hand-build `fixtures/fake-01`. Pick the rules numbers |
| 2–10 | Each lane builds against the fake capture: A tap flow + upload, B ray casting + detection, C solver + rules, D AR preview + SVG |
| 10–14 | **First full run on a real wall**, even with tap-only marking |
| 14–20 | Model detection in place of taps where it holds up, mesh measurements, error tuning, prompts on the close-ups |
| 20–24 | Tape-measure test, demo rehearsal on one house, pitch |

## Risks and fallbacks

| Risk | Fallback |
|---|---|
| Detection places objects badly | Tap-to-mark is P0 |
| Image orientation / box coordinates wrong | Round-trip test in hour 2 |
| No LiDAR phone | Planes-only mode: passage width and headroom become UNSURE. Borrow a Pro for the demo |
| AR drift | ~2 cm/s; attach results to the meter's anchor; show the tape-measure numbers |
| Driveway rule | Tapped driveway edge; automatic detection is future work |
| Sunlight washes out LiDAR | Scan the real wall at midday in hours 0–4 |
