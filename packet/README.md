# The capture packet

The contract between the iPhone app and the server. The app guides the homeowner, takes the
photos and records what the phone knows. The server builds a 3D model from them and evaluates
the placement rules. One packet is one scan session: a folder, or a zip of one, holding
`manifest.json`, the photos and the sensor files. This document is the specification.
[`manifest.schema.json`](manifest.schema.json) checks the manifest's shape, and
`python -m packet validate` checks everything below.

Version 1.0. The **App** column in each table says what `t3/ios-mvf` at `a39d0a5` records:
**now** (exported today), **partial** (computed in the app but not exported, or exported in
another form) or **planned**. [What the app records today](#what-the-app-records-today) lists
the gaps.

## Layout

```
manifest.json          what everything is (this document)
photos/p00001.jpg      full-resolution photos, one per kept frame
depth/p00001.f32       depth aligned to that photo (LiDAR phones)
depth/p00001.conf.u8   its confidence
streams/*.csv          trajectory, IMU, barometer, location, heading
lidar/mesh.ply         ARKit mesh with per-face classification (LiDAR phones)
scene.json             the app's placement request (C1), unchanged
```

Only `manifest.json` has a fixed name. Every other file is named by a manifest entry,
`{"path", "bytes", "sha256"}`. The path is relative to the manifest, uses `/`, and never starts
with `/` or contains `..`. A reader must refuse a zip whose entries leave the packet. A zip may
hold the packet at its root or inside one top-level folder.

## Units, frames and clocks

These hold for every field unless its row says otherwise.

- **Units.** Meters and seconds. Angles are degrees where a person reads them (headings,
  latitude and longitude) and radians per second for the gyroscope. The accelerometer is in
  m/s² (Core Motion reports g: multiply by 9.80665), the magnetometer in microtesla and
  pressure in kPa.
- **Clock.** Seconds of device uptime: the clock of `ARFrame.timestamp`, `CMLogItem.timestamp`
  and `ProcessInfo.systemUptime`. `session.capture.started_at` (ISO 8601, UTC) and
  `started_at_uptime` are the same instant, so a wall-clock time such as `CLLocation.timestamp`
  converts as `uptime = started_at_uptime + (date - started_at)`.
- **World frame.** ARKit's world frame with `worldAlignment = .gravity`: right-handed, +y up
  (against gravity), origin and heading wherever the session started. Nothing in the packet is
  in this frame except `session.meter_anchor.pose_in_world`, and heading is never used.
- **Meter frame.** Every pose and point in the packet is in the meter frame. Its origin is the
  meter anchor, the point the homeowner tapped on the meter. +y is up (the world's +y), and +z
  is the wall's outward normal, horizontal, toward where the homeowner stands. +x = y × z runs
  along the wall to the right as seen facing it: the same direction as `scene.json`'s `s`.
  `session.meter_anchor.pose_in_world` maps meter-frame points into the world frame. Results
  are placed relative to the meter because ARKit's world origin is arbitrary per session, and
  the meter is the one point every later visit can find again.
- **Camera frame.** ARKit's: +x right and +y up in the stored image, and the camera looks along
  −z. For OpenCV's camera axes (y down, looking along +z), multiply by diag(1, −1, −1).
- **Poses.** Rigid 4 × 4 transforms, written as 16 numbers column by column (`simd_float4x4`
  layout, as in Measure Lab v2 and `scene.json`). A photo's pose maps camera coordinates into
  the meter frame.
- **Images and intrinsics.** The camera image is landscape and the intrinsics match it. A photo
  is stored exactly as the sensor delivers it: landscape (width > height), never rotated to the
  phone's orientation, EXIF orientation absent or 1. `intrinsics` are `[fx, fy, cx, cy]` in
  pixels of that stored image, where (0, 0) is the top-left corner of the top-left pixel (pixel
  centres at half-integers). A resized image scales all four by the same factor. Rotating an
  image would mean rotating the intrinsics with it, so neither is rotated.
- **Depth alignment.** A depth map covers the same field of view as its photo, at lower
  resolution and the same aspect ratio (within 1%). Depth pixel (row r, column c) covers photo
  pixels x ∈ [c·W/w, (c+1)·W/w), y ∈ [r·H/h, (r+1)·H/h). Values are float32 little-endian
  meters along the camera's −z axis (not the distance along the ray), row by row from the top,
  and 0 means no measurement. Confidence is one byte per depth pixel, ARKit's
  `ARConfidenceLevel`: 0 low, 1 medium, 2 high.

## Session

| Field | Meaning | App |
| --- | --- | --- |
| `packet_version` | `"1.0"`; see [Versioning](#versioning) | planned |
| `session.id` | Unique per scan | planned |
| `session.producer` | `kind` (`app` or `converter`), `name`, `version`, optional `commit` | planned |
| `session.device.model` | Hardware identifier, e.g. `iPhone16,1` (`utsname.machine`), never the phone's name | planned |
| `session.device.ios_version` | `UIDevice.systemVersion` | planned |
| `session.device.lidar` | `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` | planned |
| `session.device.scene_depth_enabled`, `mesh_enabled` | What the session actually ran with | planned |
| `session.capture.started_at`, `started_at_uptime`, `ended_at_uptime` | Wall clock and uptime at the first frame, uptime at the last | planned |
| `session.capture.distance_walked_m` | Horizontal length of the trajectory (meter frame x and z). Must match `streams.trajectory` within 1% | planned |
| `session.world_alignment` | Always `"gravity"` | partial: the app runs with `.gravity` but does not write it |
| `session.meter_anchor.pose_in_world` | The meter frame in the world frame | partial: `scene.json` has the meter's position (feet, ground at y = 0), not its orientation |
| `session.meter_anchor.ground_y_m` | The ground's height at the meter on the meter frame's y (negative) | partial: implied by `scene.json`'s y = 0 |
| `session.consent.location` | The homeowner agreed to share location and heading. Must be true if either stream is present | planned |

## Photos

One entry per kept frame, in time order. Required: `id`, `image`, `width`, `height`, `t`, `pose`,
`intrinsics`.

| Field | Meaning | App |
| --- | --- | --- |
| `image` | JPEG of the full frame: at least ARKit's `capturedImage` at its native size (1920 × 1440 on current iPhones). On iOS 16 and later, prefer `captureHighResolutionFrame`'s still (4032 × 3024) with its own intrinsics. Never a thumbnail | now: `capturedImage` at native size, quality 0.8 |
| `width`, `height` | Pixels of the stored JPEG | now |
| `t` | `ARFrame.timestamp` | partial: recorded, not exported |
| `pose` | Camera to meter frame, from `ARFrame.camera.transform` | partial: exported camera-to-world in feet |
| `intrinsics` | `ARFrame.camera.intrinsics` for the stored image | now |
| `tracking.state`, `tracking.reason` | `normal`, `limited` or `not_available`, with the limited reason | partial: recorded, not exported |
| `exposure.duration_s`, `exposure.iso`, `exposure.offset_ev` | `ARCamera.exposureDuration` and `exposureOffset` (iOS 15); ISO from the high-resolution still's metadata | planned |
| `lens.focal_length_mm`, `lens.f_number`, `lens.camera` | From the still's EXIF; `camera` is `wide`, `ultra_wide` or `telephoto` | planned |
| `sharpness` | `{"method": "laplacian_variance_luma_640", "value"}`, defined below | partial: the app scores sharpness another way and does not export it |
| `depth` | `map`, optional `confidence`, `width`, `height`, `source` (`arkit_scene_depth`, `arkit_smoothed_scene_depth`, or `rendered_from_laser_scan` in samples) | planned (S6, LiDAR) |

**Sharpness** is the variance of the 4-neighbour Laplacian of the image's luma, after scaling the
long side to 640 px with bilinear filtering (images already smaller are used as they are). One
fixed method makes scores comparable across phones and resolutions. `packet/write.py` has the
reference implementation.

## Streams

CSV files with a header row. The first column is always `t`, strictly increasing. Each has a
manifest entry `{"path", "bytes", "sha256", "rows", "nominal_rate_hz"}`, and its columns are
fixed:

| Stream | Columns | Source | App |
| --- | --- | --- | --- |
| `trajectory` | `t, tracking, px, py, pz, qx, qy, qz, qw` | Every ARFrame (60 Hz): camera-to-meter position and unit quaternion, tracking state | planned: the app keeps pose-only frames at 30 Hz for its overlay and discards them |
| `accelerometer` | `t, x, y, z` (m/s²) | `CMAccelerometerData` | planned |
| `gyroscope` | `t, x, y, z` (rad/s) | `CMGyroData` | planned |
| `magnetometer` | `t, x, y, z` (µT, uncalibrated) | `CMMagnetometerData` | planned |
| `device_motion` | `t, qx, qy, qz, qw, gravity_x, gravity_y, gravity_z, user_accel_x, user_accel_y, user_accel_z, rotation_rate_x, rotation_rate_y, rotation_rate_z, heading_deg` | `CMDeviceMotion` (gravity and user acceleration in g, as Core Motion reports them) | planned |
| `barometer` | `t, pressure_kpa, relative_altitude_m` | `CMAltimeter` | planned |
| `location` | `t, latitude, longitude, altitude_m, horizontal_accuracy_m, vertical_accuracy_m` | `CLLocation`, with consent only | planned |
| `heading` | `t, magnetic_deg, true_deg, accuracy_deg` | `CLHeading`, with consent only | planned |

IMU axes are Core Motion's device frame: +x to the right and +y toward the top of a phone held in
portrait, +z out of the screen. A photo from a tracked frame must sit on the trajectory: the
trajectory has a sample within 1/60 s of the photo's `t`, at the same position to 1 cm.

## LiDAR extras

On a LiDAR phone with scene reconstruction on, `lidar.mesh` is ARKit's mesh (`ARMeshAnchor`s
merged, in the meter frame), as a binary PLY with exactly this header:

```
ply
format binary_little_endian 1.0
element vertex N
property float x
property float y
property float z
element face M
property list uchar int vertex_indices
property uchar classification
end_header
```

Every face is a triangle. `classification` is `ARMeshClassification`'s raw value: 0 none, 1 wall,
2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door. `comment` lines may follow `ply`.

`lidar.planes` lists `ARPlaneAnchor`s: `id`, `alignment` (`horizontal` or `vertical`),
`classification`, `pose` (plane to meter frame; the plane is its local x-z plane and its normal
is +y), and `extent_m` ([x, z]). App: planned. The app reads plane anchors for its coverage and
taps but does not export them.

## Marks, guidance and the scene

`marks` are what the homeowner marked, in the meter frame. `kind` is `meter`, `wall_end`,
`gas_meter`, `ac`, `door`, `window`, `garage_door`, `drive_edge` or `fence`. `points` holds one
point for a meter, wall end, gas meter or AC unit, and two for an opening (bottom-left and
top-right corners), a drive edge or a fence. Each mark also has optional `t`, `photo_ids` and
`attrs.operable`. A wall end adds `side` (`left`, `right`) and `end_kind` (`limit` when something
blocks it, `unexplored` for a corner or no answer). App: partial. `scene.json` carries these as
objects and wall ends in C1's feet and `s` coordinates, without times or photo links.

`guidance` logs every request the homeowner was shown, and whether it was met:

- `kind`: `walk`, `tilt_to_ground`, `step_back`, `mark_end`, `closeup`, `gap_band` or
  `gap_past_end`;
- `origin`: `phone` or `server`;
- `message`, and for a band request `band` and `span_m` (meter frame x);
- `t_shown` and `t_resolved`;
- `outcome`: `met`, `skipped`, `cannot_reach`, `superseded` or `unresolved`.

The log is how the server learns what the homeowner could not reach, which `scene.json` cannot
say today (bug triage B-08). App: planned; guidance is transient UI state.

`scene` is the app's `scene.json`, unchanged, with its `schema_version`. It stays the input to
placement; the packet carries it so reconstruction and placement see the same capture. App: now.

`provenance` (`dataset`, `license`, `source`, `notes`) says where a converted sample came from and
what it lacks. The app does not write it.

## Versioning

`packet_version` is `MAJOR.MINOR`. A reader accepts any packet with its own major version and
ignores fields it does not know. A writer bumps the minor version for additions (a new optional
field, stream or enum value a reader may skip) and the major version for anything an old reader
would misread: a renamed or removed field, a changed unit, frame or column order. The validator
accepts `1.x`.

## Transport

This is a recommendation; Hunter's team decides. A packet does not fit in one request. The
hosted API refuses bodies over 4.5 MB (Vercel's limit). The app's Simulator export of 77 photos
at 1280 × 720 is already 16.5 MB. At an estimated 0.5 MB per 1920 × 1440 photo and 3 MB per
high-resolution still, 80 photos come to about 40 MB, or 250 MB with stills. These are estimates:
no device capture has been measured.

1. The phone writes the packet on disk as it captures, so a crash or a lost connection loses
   nothing already taken.
2. `POST /v1/packets` with `manifest.json` only (tens of KB). The server validates the manifest
   and answers with a packet id and one presigned upload URL per file in object storage (S3,
   R2 or Vercel Blob), keyed by sha256.
3. The phone uploads each file with a background `URLSession` upload task, which iOS continues
   after the app is suspended. Files over about 8 MB use multipart upload. Because files are
   named by their hash, a retry skips any file the server already holds.
4. `POST /v1/packets/{id}/complete`. The server checks every size and hash (this validator),
   then queues reconstruction.
5. Placement stays a separate small request. `POST /v1/placements` with `scene.json` (KB) can
   answer at once, and a later answer can use the reconstruction.

## Relation to existing formats

- **`scene.json` (C1)** is unchanged and travels inside the packet. It stays in feet and in
  ARKit's world moved so the ground is y = 0. The rest of the packet is in meters and in the
  meter frame.
- **Measure Lab session v2** (the replay format) shares the packet's units, camera axes,
  column-major poses and depth encoding. It differs in frame (world, not meter), file names, a
  per-keyframe `depth` object `{file, confidenceFile, w, h}`, and a `tracking[]` timeline where
  the packet has a trajectory stream.
- **`recon/recon/capture.py`** on `t3/recon` reads `scene.json` bundles (feet, scaled to meters
  on load) and Measure Lab v2. Reading a packet needs a third branch: photo poses are already
  in meters, and the wall direction and normal are the meter frame's x and z axes.

## What the app records today

At `t3/ios-mvf` `a39d0a5`, the app's export (`scan.zip`) is `scene.json` plus one JPEG per kept
keyframe. The upload sends `scene.json` alone. To write a 1.0 packet the app needs, in rough
order of cost:

1. **Already in memory, not exported:** each photo's timestamp and tracking state, the meter
   anchor's orientation, and mark times.
2. **One read at session start:** device model, iOS version, app version, LiDAR support, the
   wall-clock start.
3. **Convert:** poses to meters in the meter frame, and marks from C1's `s`/height to meter-frame
   points.
4. **Record and write:** the 60 Hz trajectory (today discarded after the overlay uses it),
   exposure and ISO per photo, sharpness by the fixed method, distance walked, and the guidance
   log.
5. **New sensors:** Core Motion (accelerometer, gyroscope, magnetometer, device motion,
   altimeter); location and heading behind a consent prompt.
6. **LiDAR (S6):** `sceneDepth` with confidence per photo, the mesh with classification, plane
   anchors.
7. **Transport:** the manifest-then-files upload above.

## Tools

From `packet/`:

```
uv run python -m packet validate <folder or zip>        # exit 0 when valid; --json for a report
uv run python -m packet.samples.synthetic --out fixtures/synthetic
uv run python -m packet.samples.app_export --sim-report <report> --replay <session> --out <dir>
uv run python -m packet.samples.advio --replay <session> --advio <advio-20> --out <dir>
uv run python -m packet.samples.eth3d --eth3d <electro> --out <dir>
uv run pytest -q && uv run ruff check . && uv run ruff format --check .
```

`fixtures/synthetic` is the only packet in git: three invented photos with every optional
section. The dataset samples are written to `~/house-scanning-data/packets/` and never
committed. ADVIO is CC BY-NC 4.0, ETH3D CC BY-NC-SA 4.0, and the app sample carries ADVIO frames.

| Sample | Source | Contents | What it shows |
| --- | --- | --- | --- |
| `app-export-a39d0a5` | The app's `scan.zip` from a Simulator run on the ADVIO replay | 77 photos (1280 × 720), marks, `scene.json` | Exactly what the app records today. Times are recovered by matching each photo to its replay frame |
| `advio-20-0040-0075` | ADVIO sequence 20, 40 to 75 s, iPhone 6s | 79 photos (1280 × 720), 60 Hz trajectory, accelerometer, gyroscope, magnetometer, barometer, location | Real phone IMU on the same clock as ARKit poses |
| `eth3d-electro` | ETH3D electro, 8 DSLR photos within about 6 m of the walls | 8 photos (6198 × 4132, originals) with laser-rendered depth | Depth aligned to full-resolution photos. ETH3D's own 3-D points reproject through the packet's poses to a median 0.65 to 1.01 px, and the depth agrees with them to a median 0.2 to 0.6% |

The validator checks:

- the schema;
- every file's presence, size and sha256;
- that every pose is a rotation plus a translation;
- that intrinsics fit each image (landscape, principal point inside it, square pixels within 5%,
  a horizontal field of view between 20° and 150°);
- that JPEG sizes and EXIF orientation match the manifest;
- that times strictly increase and fall inside the capture;
- the stream columns, unit quaternions and tracking values;
- that photos sit on the trajectory, and that distance walked matches it;
- that depth has its photo's aspect and the right byte count, with finite, non-negative values
  and confidence of at most 2;
- the mesh layout, face indices and classes;
- mark and guidance consistency;
- consent for location and heading.
