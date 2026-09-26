# House Scan for iOS

Native iPhone app for the AR capture walk. The homeowner marks the electric meter, the app takes a close-up of it, then keyframes are captured automatically while they walk the wall. The app asks for any missing stretch, uploads the scan and shows the placement result.

## How it is split

- `HouseScanKit/` is the capture logic as a plain Swift package (Foundation and simd only): camera and wall geometry, the coverage map, the auto-capture and close-up gates, walk guidance, the gap planner, scene.json export, the zip writer, result decoding and replay reading. Its thresholds are hypotheses, documented where they are defined.
- `HouseScan/Runtime/` is the engine: ARKit and replay frame sources, the state machine behind `ScanActions`, keyframe storage, upload and the autopilot.
- `HouseScan/UI/` holds the screens. They read `ScanViewState` and call `ScanActions`; `HouseScan/Contract/ScanContract.swift` is the boundary between the two.

## 3D map

`HouseScanKit/Sources/HouseScanKit/Map3D/` keeps a live occupancy map of the space around the meter. A ray from the camera marks the voxels it passes through as free and the voxel it stops in as surface. Voxels no ray reached stay unknown, so a wall behind a bush stays unseen until some view gets past the bush. The map uses 10 cm voxels in 8³ bricks, stored only once a ray reaches them. The default bounds hold at most 32 MB. `MapFrame` is the capture packet's meter frame (`packet/README.md`): origin at the meter anchor, +z the wall's outward normal, +y up, and the ground's height below the anchor as `groundY`. `DepthFrame` uses the packet's depth encoding, and a packet's mesh is one `MeshChunk` placed at `MapFrame.poseInWorld`.

`Runtime/Map3DFeed.swift` converts ARKit data into the map's inputs on the AR delegate queue. `Runtime/Map3DSession.swift` owns one map for the app. The delegate queue only converts and hands inputs over, keeping the newest pending frame. The session integrates on its own queue and publishes a `Map3DSnapshot` (coverage, measured walls, fog, next view) at most twice a second. `Runtime/Map3DCoverageSource.swift` is what the export reads: the measured wall chain with each piece's `source` and `plus_minus_ft` when it matches the walk (its meter piece within 0.3 m of the meter, its corners within 0.5 m of the tapped chain, reaching both ends), otherwise the tapped wall. Each wall span goes out with the height its face was seen to. `UI/Camera/Map3DOverlay.swift` draws the fog and the next-view cue. Integrate only frames with normal tracking.

The 3D map is the coverage model by default (`-coverage map3d`); `-coverage legacy` keeps the camera coverage map alone. Under map3d:

- scene.json's coverage, walls and wall sources come from the map. The walk's own facing (the walked path) and overhead (tilt-up views confirmed clear) are merged in, taking the larger reach, only when the tapped wall is written, since their s is that wall's.
- On a phone or replay with depth, the strip and the gap planner count a cell covered only where the map saw it (`CoverageMap.setMeasuredCovered`). Without depth the map is too sparse to walk by, and the camera sightings keep deciding.
- The result is placed along the wall the scene described, which can be the measured chain.
- A replay's frames go into the map only on the walk and in a gap request: for the close-up a replay plays its whole recording.

| Phone | Session setting | Feed |
| --- | --- | --- |
| LiDAR | `frameSemantics.insert(.sceneDepth)`, `sceneReconstruction = .meshWithClassification` | `depthFrame` → `Map3D.integrate`; `meshChunk` of each added or updated `ARMeshAnchor` → `Map3D.update`, removed → `removeMeshChunk` |
| No LiDAR | plane detection (already on) | `featureFrame` → `Map3D.integrate`; `planes` → `Map3D.update` |

Outputs, all against a `WallFrame` (the walk's, or one built from the map's own walls):

- `coverage(along:)`: wall, ground, facing and overhead spans for `SceneCoverage(_:leftEndMarked:rightEndMarked:)`.
  - A span is seen only where rays reached it. A voxel is free only where a ray crossed it completely and ended beyond it.
  - The wall is judged against where the facade was measured around each cell, not the chain's line. Its face counts within 7.5 cm, and a recessed face up to 0.5 m behind also counts.
  - Attached relief up to 0.5 m proud, such as a pilaster, counts as the facade, because nothing can be mounted behind it. It must reach headroom, and no gap may have been seen behind it.
  - Anything else standing in front hides the wall: a box, a shrub, or the meter itself, so the few cells behind the meter stay unseen.
  - Facing reaches shorter than the battery's depth are not reported.
- `measuredWalls()`: the outline near the meter as a chain of straight pieces with real corners.
  - Each piece is marked `mesh` or `plane` and carries `plusMinus`, its line's position error. The server takes both as `walls[].source` and `plus_minus_ft`.
  - Lines are found by an angle sweep over the densest band of wall evidence, so relief along part of a wall doesn't tilt them.
  - `wallFrame(meter:groundY:frame:)` turns the chain into a `WallFrame`.
- `fogOfWar(along:)`: 0.3 m cells of the region of interest that are still unknown, in the map frame, to draw from the meter anchor.
- `nextBestView(along:)`: the largest unseen region that borders seen space, plus where to stand and aim to see it.

Without LiDAR, only feature-point rays count as seen. A point on a detected plane takes that plane's normal. Detected planes and mesh chunks mark voxels by reference count and add no occupancy: updating or removing one takes its marks with it, and planes alone clear no fog. Coverage without LiDAR is therefore sparse until monocular depth arrives, and a replay without depth gives the map nothing. `DepthFrame.Kind.estimated` takes that depth with a per-pixel standard deviation, and it is never used for walls.

On an M4 Pro, one 256×192 LiDAR frame integrates in about 6 ms (release build, every second pixel), and reading coverage takes about 25 ms. `swift test -c release --filter Map3DPerformanceTests` prints the current numbers. The map assumes nothing moves: an object that appears in space seen empty earlier becomes surface where its face is measured, but its inside keeps the earlier free reading.

## Launch arguments

| Argument | Effect |
| --- | --- |
| `-replay <folder>` | Plays a measure-lab-session v2 folder instead of the camera. A replay without wall taps gets a wall assumed from its trajectory, logged as an assumption. Keyframes with a `depth` entry (`{file, confidenceFile, w, h}`, Float32 meters) play their LiDAR depth into coverage as a LiDAR phone would. |
| `-coverage map3d\|legacy` | Where coverage comes from (default `map3d`): see "3D map". Any other value stops the app. |
| `-autopilot` | Drives every step on a replay, answering the ground question with mulch. It holds some walk frames back to close one gap request before the upload: under map3d on a replay with depth, frames whose depth alone shows a gap the map keeps without them (`ReplayPlanning.heldBackWindow(frames:depths:wall:)`), otherwise frames the camera coverage map needs. On the LiDAR fixture no window qualifies under map3d: the bin's shadow is always the nearest gap, and the autopilot answers it "I can't get there". Under map3d it waits for the map to catch up before each step that reads coverage. After each upload it also drives the requests the server's answer raises, closing each with the replay's frames, until the result shows. A request the frames don't close gets "I can't get there", as a homeowner would answer. |
| `-serverURL <url>` | Uploads the scan to this server: `POST <url>/v1/placements` with scene.json as `application/json`. Without it the app uses `HOUSESCAN_SERVER_URL` from `Config/Shared.xcconfig` (https://house-scanning-server.vercel.app), carried in Info.plist as `HouseScanServerURL`. Photos stay on the phone unless someone uses Share scan, which shares the scan as a capture packet (see "Scan bundle"). |
| `-sampleResult` | Answers with the bundled sample result, which the result screen must label as a sample, even when a server is configured. The UI tests pass it so they run offline. It is also the fallback when `HOUSESCAN_SERVER_URL` is empty. |
| `-autopilotHold <s>` | How long the autopilot leaves each screen up (default 1.2 s). |
| `-uiDemo` | Runs the screens on a scripted fake engine instead of the capture engine, for design work and for auditing states a replay can't reach. The arguments it takes are listed in `HouseScan/UI/Preview/UIDemo.swift`; for example `-uiDemoGroundQuestion` opens the feature review with the ground question showing, and `-uiDemoPhase meterCloseUp -uiDemoMeterChoose` shows the meter number picker. |

Every screen change is logged as `STATE=<phase>` under subsystem `dev.housescanning.housescan`, category `state`.

## Layout

| Path | Contents |
| --- | --- |
| `project.yml` | XcodeGen spec, the source of truth for the project |
| `HouseScan.xcodeproj` | Generated from `project.yml` and committed |
| `HouseScan/` | Swift sources, a synchronized folder |
| `Config/Shared.xcconfig` | Settings for all configurations; includes `Local.xcconfig` if present |
| `Config/Local.xcconfig.example` | Template for per-person signing |
| `Config/Info.plist` | Camera prompt, `arkit` capability, portrait only, HTTP to local-network servers |
| `HouseScanKit/` | Capture logic package with its tests |
| `HouseScanUITests/` | Full-flow UI tests on a replay, and an accessibility audit of every screen state in demo mode. `Fixtures/` holds two synthetic replays, one with LiDAR depth; the tests read them from the source tree, and `project.yml` keeps them out of the test bundle. |
| `Tools/make-synthetic-replay.swift` | Renders the synthetic fixture |
| `Tools/check-app-scene.sh` | Checks a scan bundle's scene.json against the server schema |

## Requirements

- Xcode 26 or newer. The deployment target is iOS 26.0 and the code uses only iOS 26 SDK APIs.
- An iPhone that supports ARKit to run it. LiDAR is not required; with it the scan also records depth and a mesh.
- XcodeGen 2.46.0, only if you change `project.yml`.

## Commands

Build without signing, as CI does, from the repository root:

```sh
xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan -configuration Debug \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build
```

`make ios` runs the same build.

Test the capture logic, then run the whole flow in the Simulator on the synthetic replay:

```sh
swift test --package-path ios/HouseScanKit
xcodebuild -project ios/HouseScan.xcodeproj -scheme HouseScan \
  -destination "platform=iOS Simulator,name=iPhone 17" -only-testing:HouseScanUITests test
```

To run the flow on a local recording, set `TEST_RUNNER_HOUSESCAN_REPLAY=<session folder>` for that `xcodebuild` command. Keep such recordings and their screenshots out of git.

After editing `project.yml`, regenerate the project from the repository root and commit it:

```sh
make ios-project
```

CI regenerates the project with XcodeGen 2.46.0 and fails if the result differs from the committed project. Other XcodeGen versions can write a different file, so `make ios-project` refuses to run with any other version.

## Run on your iPhone

1. From the repository root, `cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig`.
2. In `Local.xcconfig`, set `DEVELOPMENT_TEAM` to your 10-character Team ID (developer.apple.com > Account > Membership details) and `BUNDLE_ID_PREFIX` to a reverse-DNS prefix of your own, such as `com.yourname`. The app id becomes `<prefix>.housescan`.
3. Open `ios/HouseScan.xcodeproj`, plug in the iPhone, pick it as the run destination and press Run. Signing is automatic, so Xcode creates the profile for your team.
4. The first time, the iPhone asks you to turn on Developer Mode (Settings > Privacy & Security > Developer Mode, then restart). With a free Apple account you also trust yourself in Settings > General > VPN & Device Management.

Git ignores `Local.xcconfig`. Leave the team field in Xcode's Signing & Capabilities tab empty. Setting it there writes your team into `project.pbxproj`, and the CI drift check then fails.

**Server.** By default the app sends scans to the hosted API, https://house-scanning-server.vercel.app (`HOUSESCAN_SERVER_URL` in `Config/Shared.xcconfig`). To use a server on your laptop instead, start it on the same Wi-Fi as the phone (`uv run uvicorn api:app --host 0.0.0.0 --port 8000`, see `server/README.md`), find the laptop's address with `ipconfig getifaddr en0`, and add `-serverURL http://<address>:8000` under Product > Scheme > Edit Scheme > Run > Arguments. Info.plist allows plain HTTP to local-network addresses; if iOS asks for Local Network access, allow it. `-sampleResult` answers with the bundled sample instead, with no network at all. Xcode saves these arguments into the shared scheme, so don't commit that change.

**Logs.** Open Console.app on the Mac, select the iPhone, press Start and search for `subsystem:dev.housescanning.housescan`. Every screen change logs as `STATE=<phase>`; the `engine` category records the capture's decisions, the scan bundle and upload failures. The same lines show in Xcode's console while it runs the app.

**Getting a scan off the phone.** The result screen, and the screens for a failed or refused upload, have a Share scan button. It shares the scan bundle (below); AirDrop it to your Mac. It holds photos of a real home, so keep it out of git.

## Scan bundle

`scan.zip` in the scan's folder is what Share scan sends: a capture packet, version 1.0, with `manifest.json` at the zip's root. The packet's specification is `packet/README.md` on the `t3/packet` branch, with `packet/manifest.schema.json` and a validator (`uv run python -m packet validate <scan.zip>`). The upload sends only scene.json; nothing uploads the packet.

Everything in the packet is in meters, seconds of device uptime (`ARFrame.timestamp`) and the meter frame (origin at the meter, +y up, +z out of the wall, +x along the wall to the right), except scene.json.

| File | Contents |
| --- | --- |
| `manifest.json` | The session (device model, iOS version, LiDAR and what the session ran with, capture times, distance walked, the meter frame in ARKit's world), every photo's time, pose, intrinsics, tracking, exposure, lens and sharpness, the streams, plane anchors, marks and the guidance log. Every other file is named in it with its size and sha256. |
| `photos/pNNNNN.jpg` | Every kept keyframe and the meter close-up, in time order, landscape and unrotated as the sensor produced them. |
| `depth/pNNNNN.f32`, `depth/pNNNNN.conf.u8` | Live LiDAR phones only. ARKit's scene depth for the photo, float32 meters along the camera's -z (0 = no reading), and its confidence (0 low, 1 medium, 2 high). |
| `streams/trajectory.csv` | The camera at every ARFrame (60 Hz), with its tracking state. On a replay, one row per recorded frame. |
| `streams/accelerometer.csv`, `gyroscope.csv`, `magnetometer.csv`, `device_motion.csv`, `barometer.csv` | Core Motion on the phone, 100 Hz except the barometer, from the meter search to the upload. Not recorded on a replay or in the Simulator. |
| `lidar/mesh.ply` | LiDAR phones only. ARKit's mesh in the meter frame with each face's classification. |
| `scene.json` | The scene the server checks (contract C1), unchanged: feet, ground at y = 0. Its `img` names are the scan folder's `k<NNNNN>.jpg`, not the packet's photo names. |

The app does not record location or heading, and writes `session.consent.location` as false. A replay's photos keep the recording's times; its depth is left out because it is not ARKit's own, and its capture has no wall-clock start. On a replay the guidance times follow the latest frame played, which stands still while the gap loop replays earlier frames.

`HouseScan/Runtime/ScanEngine+Packet.swift` assembles the packet, `Runtime/CaptureRecorder.swift` records the streams and `Runtime/GuidanceLog.swift` the requests.

## Conventions

- Add Swift files under `HouseScan/`. Xcode includes them without a project change. Edit `project.yml` only for settings, targets or files outside that folder.
- Swift 6 language mode with complete concurrency checking. UI and `ScanEngine` run on the main actor. ARKit delegate callbacks run on a private serial queue and send Sendable frame snapshots to the main actor (see `Runtime/LiveCapture.swift`).
- Never commit captures, photos or measurements of a real home. See the repository CONTRIBUTING.md.
