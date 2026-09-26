# Stack research: libraries, open-source projects, how they fit

This came from five parallel research agents on 2026-09-25 using live web searches. Anything marked
**UNVERIFIED** couldn't be confirmed. Licenses are what each repo or model card said on that date, so re-check them before shipping a product.

## Data flow, with the tool at each step

```
PHONE (Swift)
  ARKit: gravity alignment, wall + ground detection, LiDAR mesh, depth ← Apple "Visualizing and interacting with a reconstructed scene"
  Frame recorder (position + lens data per frame)             ← fork Stray Scanner (MIT)
  Which frames to keep                                        ← lift from arkit-3dgs-scanner (Apache-2.0)
  Mesh → .ply                                                 ← write by hand
  Meter close-up checked on the phone                         ← Apple Vision RecognizeTextRequest + VNDetectBarcodesRequest
  GPS + one compass reading away from the meter
        │ zip → foreground upload
SERVER (Python, FastAPI)
  Read the capture ─────────── Open3D (read .ply, RaycastingScene, segment_plane) + numpy
  Map context ──────────────── Census geocoder → Overture building outline (DuckDB) → osmnx nearest road
                               → street-facing wall; pools/driveways from OSM + samgeo on StratMap/NAIP
  Object detection ─────────── Gemini boxes → SAM 2 tightens them → supervision merges them → cast onto the wall
  Recognition ──────────────── recognition prompts on Gemini; zxing-cpp double-checks the barcode
  Placement code ───────────── shapely + numpy sweep, rules.yaml (each rule cites its code)
  Output ───────────────────── JSON + drawsvg 2D site plan
  Debugging ────────────────── Rerun (its ARKitScenes example logs exactly our data)
  Pitch baseline ───────────── Depth Anything 3 metric (Apache-2.0) on plain photos
        │ result, positioned relative to the meter
PHONE: RealityKit box attached to the meter's anchor + cable line
```

## Why each piece matters

| Piece | Rule(s) it serves | Why this tool, and what we're skipping |
|---|---|---|
| ARKit + LiDAR mesh | Passage width, headroom, gaps between openings, cable length | Real measurements (~±6–8 cm on walls, ~5 m range) instead of estimates by eye. Skip photogrammetry. |
| Guided walk to both ends | "please send more photos" follow-ups | Makes "unseen space" impossible |
| One continuous session | same wall? / panel behind meter | Shared coordinates; nothing pieced together from unordered photos |
| Stray Scanner fork | everything downstream | The only maintained MIT recorder of position + lens data + depth. No open-source app also exports the mesh |
| Open3D | passage width, headroom, wall fitting | One library for .ply + planes + batch rays |
| Gemini boxes | windows, doors, garage, AC, gas meter, vents | Best zero-shot box accuracy found; native 0–1000 box output |
| SAM 2 | every rule that uses an object's position | Vision-model boxes are loose; a mask's bottom edge is the right point to cast |
| Apple Vision on the phone + zxing | meter number, CL320 | Instant retake; serial-number OCR is the weak spot (63% vs 97%) |
| Overture + osmnx | which wall faces the street (flag for homeowner approval of the look) | The compass alone can't tell |
| samgeo on StratMap/NAIP | pool, driveway | OSM tags them on < 5% of homes; imagery ML is allowed to run on |
| rules.yaml + citations | all rules | Each "no" cites its source: NEC / IRC / Austin Energy / Texas Gas Service, Base's public help page, or a labeled demo placeholder |
| Rerun | debugging | Capture + solver reasoning in one timeline |
| Depth Anything 3 | pitch | The "AR beats photos" comparison |

## Phone capture (iOS)

**Use:**
- Apple sample **"Visualizing and interacting with a reconstructed scene"**: RealityKit + `.meshWithClassification`, mesh raycasts, `ARMeshGeometry` extensions. Plane detection flattens the mesh where planes are found, so walls come out clean.
- Apple sample **"Displaying a point cloud using scene depth"**: sceneDepth + confidence + intrinsics → points.
- The battery model is just `MeshResource.generateBox`. Skip Object Capture.

**Lift code from:**

| Repo | License | Last commit | Notes |
|---|---|---|---|
| [strayrobots/scanner](https://github.com/strayrobots/scanner) | MIT | 2026-04 | HEVC RGB, 16-bit depth PNG (mm), confidence, `odometry.csv` (position + quaternion + fx fy cx cy), IMU. No mesh. **Fork this** |
| [xiongyiheng/ARKit-Scanner](https://github.com/xiongyiheng/ARKit-Scanner) | Apache-2.0 | 2026-07 | ScanNet++'s capture app; good upload-to-server reference |
| [KuoFengYuan/arkit-3dgs-scanner](https://github.com/KuoFengYuan/arkit-3dgs-scanner) | Apache-2.0 | 2026-09 | Keyframe picker by movement/rotation, COLMAP export |
| [tkuehnl/iPadLIDARScanExport](https://github.com/tkuehnl/iPadLIDARScanExport) | UNVERIFIED | 2020 | ARMeshAnchor → world → OBJ approach; read it, don't copy (it writes back into ARKit's buffer) |
| [jc211/NeRFCapture](https://github.com/jc211/NeRFCapture) | MIT | 2023 | Small, readable, stale |
| [TokyoYoshida/ExampleOfiOSLiDAR](https://github.com/TokyoYoshida/ExampleOfiOSLiDAR) | MIT | 2021 | Snippets |

**Skip:**
- **ios_logger:** no license, 2020.
- **ARKit-Data-Logger:** poses only.
- **SwiftUI-LiDAR:** no poses.
- **Nerfstudio iOS:** no app of its own; its importers are for closed apps.
- **RoomPlan:** indoor rooms only.

**Gotchas:**
- `capturedImage` is in the sensor's landscape orientation, and intrinsics are in its pixels.
- Depth is 256×192, so scale K to match.
- LiDAR: stand 1–3 m from the wall (~5 m max, ≥ ~0.5 m min).
- `.gravityAndHeading` needs a location permission, doesn't re-align north after the session starts, and suffers magnetometer interference.
- **App Clips:**
  - Size: 15 MB on iOS 16; 100 MB on iOS 17+ if digital-invocation only.
  - ARKit isn't on the list of frameworks App Clips can't use.
  - **No background URLSession.**
  - Location is "When In Use" only, and it resets.
  - Whether sceneReconstruction works inside a clip is UNVERIFIED.
- **Android:** only ARKit supports AR Foundation meshing. ARCore Depth is weak on blank walls and has no mesh. Not for v1.

## Geometry server

**Use:**

| Library | Version / license | What for |
|---|---|---|
| [Open3D](https://pypi.org/project/open3d/) | 0.20.0, MIT | `segment_plane`, `detect_planar_patches`, `o3d.t.geometry.RaycastingScene.cast_rays` |
| [shapely](https://pypi.org/project/shapely/) | 2.1.x, BSD-3 | polygon distances; vectorised functions release the GIL |
| numpy | — | 1-D intervals. No interval library needed |
| [Rerun `rerun-sdk`](https://pypi.org/project/rerun-sdk/) | 0.38, MIT/Apache | [ARKitScenes example](https://rerun.io/examples/spatial-computing/arkit_scenes) logs poses + intrinsics + RGB + depth + mesh + 3D boxes |
| [drawsvg](https://pypi.org/project/drawsvg/) | 2.4.x, MIT | site plan; PNG export needs Cairo |

**Consider:**
- **trimesh 5.1 + embreex 4.4** (MIT/BSD): nicer mesh API, e.g. `section()` for the wall-base line.
- **polyscope:** an interactive viewer.

**Skip:**

| Project | Why |
|---|---|
| SpatialLM | CC-BY-NC encoder, indoor, needs CUDA |
| Meta SceneScript | CC BY-NC, Aria input; its FAQ says outdoor results are unpredictable |
| RoomFormer | indoor floorplans |
| pymeshlab | GPL-3 |
| pyransac3d | inactive |
| svgwrite | inactive |
| COLMAP / hloc / nerfstudio / gsplat | COLMAP's own tutorial says to avoid texture-less walls; no scale; slow |

**Gotchas:**
- The ARKit mesh isn't watertight, so `contains_points` is meaningless.
- Open3D rays must be float32.
- ARKit camera coordinates are RUB (x right, y up, looking down −z), unlike OpenCV (UNVERIFIED from docs; the round-trip test settles it).

## Object detection and recognition

**Use:**
1. **Gemini API boxes:**
   - Format: `box_2d: [ymin, xmin, ymax, xmax]` on 0–1000; segmentation adds a `mask` polygon.
   - Set the thinking level to minimal for segmentation.
   - Accuracy: RF100-VL zero-shot mAP is 13.3 for Gemini 2.5 Pro vs 1.5 for GPT-5. Gemini 3 Pro with better prompts reached 26.4 on a subset.
   - Docs examples use `gemini-3.8-flash` (model ID UNVERIFIED).
2. **[SAM 2](https://github.com/facebookresearch/sam2)** (Apache-2.0), prompted with each box, to get a tight mask + ground-contact point. [Grounded-SAM-2](https://github.com/IDEA-Research/Grounded-SAM-2) already wires this up.
3. **[Qwen3-VL](https://github.com/QwenLM/Qwen3-VL)** (Apache-2.0; 2B–235B) as a local second opinion. Its coordinate scale is 0–1000 or 0–1 depending on which doc you read, so test it.
4. **[supervision](https://supervision.roboflow.com/)** (MIT) for NMS/NMM, `InferenceSlicer` and drawing.
5. **OCR:** Apple Vision `RecognizeTextRequest` + `VNDetectBarcodesRequest` on the phone. On the server, the vision model reads the text, cross-checked with a `CL\s?(200|320)` regex and [zxing-cpp](https://github.com/zxing-cpp/zxing-cpp) (Apache-2.0).
6. **Driveways:** Gemini segmentation + SAM 2 for the hackathon. Mapillary-Vistas Mask2Former has a driveway class, but its weights are non-commercial.

**Detector baselines:**

| Model | License | Notes |
|---|---|---|
| Grounding DINO | Apache-2.0 | |
| OWLv2 | Apache-2.0 | |
| Florence-2 | MIT | 0.77B; also does OCR |
| RF-DETR | Apache-2.0 for Nano to Large | fine-tune target for autodistill |

My judgement on these: fine on window, door, garage door and fence; weaker on gas meter and AC; poor on window well.

**Depth from a single photo** (the no-AR baseline):

| Model | License | Notes |
|---|---|---|
| [Depth Anything 3](https://github.com/ByteDance-Seed/Depth-Anything-3) `DA3METRIC-LARGE` | Apache-2.0 (Giant/Nested are NC) | Needs focal length in pixels: `depth = focal*out/300`. ETH3D δ1 0.917 |
| [MoGe-2](https://github.com/microsoft/MoGe) | code MIT; weights UNVERIFIED | δ1 0.908, ~60 ms, also gives normals |
| Depth Pro | Apple personal-use grant | commercial use unclear |
| UniDepthV2 | CC BY-NC | skip |
| Metric3D v2 | license conflicts between files | skip |

**Datasets:**
- Roboflow Universe gas meters ([402 images](https://universe.roboflow.com/proba-vwwtl/gas-meter-recognition), [1.4k images](https://universe.roboflow.com/gas-meter-zbuni/gas-meter-g7kh6)).
- Electric meters ([wattwise](https://universe.roboflow.com/wattwise/electric-meter-wzeeg-zk5fd), [1,943 images for reading dials](https://universe.roboflow.com/abhinav-kumar-do8z1/utility-meter-reading-dataset-for-automatic-reading-yolo-z0e1h)).
- Small AC sets (whether they show outdoor condensers is UNVERIFIED).
- Open Images V7 has Window and Door.
- Facade datasets (CMP, ECP, eTRIMS) are European and a poor fit.
- **No public data for window wells or breaker panels.** Label your own. [autodistill](https://github.com/autodistill/autodistill) (Apache-2.0) can auto-label.

**Skip:**

| Option | Why |
|---|---|
| GPT for boxes | 1.5 mAP |
| Claude for boxes | its docs call the coordinates approximate and ask for absolute pixels |
| Grounding DINO 1.5 / DINO-X | API only |
| YOLO-World / YOLOE / Ultralytics | GPL / AGPL |
| Molmo 2 | non-commercial training data |
| SAM 3 | custom license, CUDA 12.6+ |

**Gotchas:**
- Gemini returns [y, x]. Apply EXIF rotation before inference **and** before casting.
- Depth Anything 3 needs the focal length in pixels.
- Zinsco breakers can read "Sylvania" or "Magnetrip", and FPE ones "Stab-Lok". Put those strings in the prompt.

## Maps and aerial photos

**Use:**
- **[Overture Maps](https://docs.overturemaps.org/getting-data/duckdb/)** via DuckDB: `read_parquet('s3://overturemaps-us-west-2/release/<rel>/theme=buildings/type=building/*')` + a bbox. Roads carry `subclass=driveway|parking_aisle|alley`. Buildings and transportation are **ODbL**.
- **[osmnx](https://osmnx.readthedocs.io/)**: `ox.graph_from_point(pt, dist=150, network_type="drive")`, then `ox.distance.nearest_edges(..., return_dist=True)` on a projected graph.
- **NAIP** (public domain) via the Planetary Computer STAC `naip`. Pflugerville TX: 2022 at 0.6 m. Naperville IL: 2023 at 0.3 m. At 0.6 m a 3–5 ft driveway buffer is only ~2 pixels.
- **[TxGIO StratMap / CAPCOG](https://geographic.texas.gov/stratmap/index.html)** orthoimagery: 6″ inside Austin, 12″ elsewhere, public domain. The best free imagery ML can run on in Texas.
- **[segment-geospatial (samgeo)](https://samgeo.gishub.org/examples/text_swimming_pools/)**: text-prompted SAM ("swimming pool", "driveway"), no training.
- **Census Geocoder** (`onelineaddress`, `Public_AR_Current`): free, no key. Nominatim fallback (1 request/s, identifying User-Agent, no bulk use).
- **Google Solar API: a maybe.** Its §20.1 allows use "to determine the feasibility of installing energy systems". The dataLayers DSM and mask are 0.1 m. Whether running inference on it conflicts with §3.2.3(c) is UNVERIFIED, so ask before relying on it.

**Licensing traps:**

| Source | Trap |
|---|---|
| **Google Maps ToS §3.2.3(c)(vii)** | Bans using Google Maps content "to train, test, validate or fine-tune" ML models, and bans tracing building outlines from satellite imagery |
| **Mapbox §1.5(ii)** | Bans using it to "train, operate or improve" ML ("operate" includes running inference) |
| **Esri World Imagery** | Restricted (UNVERIFIED) |
| **ODbL share-alike** | Applies if you publish a database derived from it; internal use with attribution is fine |
| **Microsoft Global ML Footprints** | CDLA-Permissive-2.0 (the older US repo is ODbL) |
| **Mapillary** | CC BY-SA |

**Recipe:**
1. Geocode the address.
2. Get the Overture building within ±60 m (the one containing the point, or the nearest). Project to UTM 14N (Texas) or 16N (Illinois).
3. Get the osmnx drive network, leaving out `service=driveway` edges.
4. For each outline edge, score (cosine between its outward direction and the vector to the nearest road) × 1/distance. The best is the street-facing wall; flag two edges on corner lots.
5. Driveways = OSM/Overture driveway lines buffered 1.5 m, `amenity=parking` polygons and samgeo masks.
6. Pools = `leisure=swimming_pool` plus samgeo.

OSM coverage (Overpass, 2026-09-25):

| Area | Houses | Driveways | Pools |
|---|---|---|---|
| Pflugerville | 14,675 | 149 | 102 |
| Round Rock | 9,223 | 476 | 170 |
| Austin | 302k buildings | 6,029 | 3,339 |

**AR ↔ map registration:** a 2D rigid fit. Snap the AR walls to 90°, sweep yaw (±20° around the compass reading if its accuracy is ≤ 20°, otherwise all 4 quadrants), and fit translation by least squares against the outline edges. `ARGeoTrackingConfiguration` coverage in Austin is UNVERIFIED.

**Skip:**
- Google Static / Tiles / Street View and Mapbox/Esri imagery for ML.
- Nearmap: paid, no hackathon tier.
- EagleView: a 30-day sandbox exists, so maybe one email, but don't block on it.
- TorchGeo training: no time.
- Old pool CNNs: zero-shot SAM beats them.

## Test first (hours 0–4)

| Test | If it fails |
|---|---|
| LiDAR mesh of a real siding wall at midday sun | Planes only; passage width and headroom become UNSURE |
| Tap → cast into a saved frame → correct pixel | Fix image orientation before building detection |
| Gemini boxes on ~30 real photos (gas meter, AC, window well) | Tap-to-mark carries the demo |
| Compass accuracy at the meter | Use the building outline + road alone |

## Fine for the hackathon, check before it becomes a product

- **Not for commercial use:** Mapillary-Vistas models, Molmo 2 and Depth Anything V2's larger models.
- **Grey areas:** Depth Pro (Apple's personal-use license) and inference on Google Solar imagery.
- **ODbL share-alike:** if you publish a derived database.
- **GPL/AGPL detectors:** YOLO-World, YOLOE, Ultralytics.
