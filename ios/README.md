# House Scan for iOS

Native iPhone app for the AR capture walk. The homeowner marks the electric meter, the app takes a close-up of it, then keyframes are captured automatically while they walk the wall. The app asks for any missing stretch, uploads the scan and shows the placement result.

## How it is split

- `HouseScanKit/` is the capture logic as a plain Swift package (Foundation and simd only): camera and wall geometry, the coverage map, the auto-capture and close-up gates, walk guidance, the gap planner, scene.json export, the zip writer, result decoding and replay reading. Its thresholds are hypotheses, documented where they are defined.
- `HouseScan/Runtime/` is the engine: ARKit and replay frame sources, the state machine behind `ScanActions`, keyframe storage, upload and the autopilot.
- `HouseScan/UI/` holds the screens. They read `ScanViewState` and call `ScanActions`; `HouseScan/Contract/ScanContract.swift` is the boundary between the two.

## 3D map

`HouseScanKit/Sources/HouseScanKit/Map3D/` keeps a live occupancy map of the space around the meter. A ray from the camera marks the voxels it passes through as free and the voxel it stops in as surface. Voxels no ray reached stay unknown, so a wall behind a bush stays unseen until some view gets past the bush. The map uses 10 cm voxels in 8³ bricks, stored only once a ray reaches them, in the meter-anchored, gravity-aligned `MapFrame`. The default bounds hold at most 32 MB.

`Runtime/Map3DFeed.swift` converts ARKit data into the map's inputs on the AR delegate queue. Nothing calls it yet. Integrate only frames with normal tracking.

| Phone | Session setting | Feed |
| --- | --- | --- |
| LiDAR | `frameSemantics.insert(.sceneDepth)`, `sceneReconstruction = .meshWithClassification` | `depthFrame` → `Map3D.integrate`; `meshChunks` → `Map3D.update` |
| No LiDAR | plane detection (already on) | `featureFrame` → `Map3D.integrate`; `planes` → `Map3D.update` |

Outputs, all against a `WallFrame` (the walk's, or one built from the map's own walls):

- `coverage(along:)`: wall, ground, facing and overhead spans for `SceneCoverage(_:leftEndMarked:rightEndMarked:)`. A span is seen only where rays reached it.
- `measuredWalls()`: the outline near the meter as a chain of straight pieces with real corners, each marked `mesh` or `plane`. `wallFrame(meter:groundY:frame:)` turns it into a `WallFrame`. scene.json's walls have no `source` field, so the source doesn't reach the server.
- `fogOfWar(along:)`: 0.3 m cells of the region of interest that are still unknown, in the map frame, to draw from the meter anchor.
- `nextBestView(along:)`: the largest unseen region that borders seen space, plus where to stand and aim to see it.

Without LiDAR, only occluders that carry tracked feature points hide what is behind them. `DepthFrame.Kind.estimated` takes monocular depth with a per-pixel standard deviation. That depth is never used for walls.

On an M4 Pro, one 256×192 LiDAR frame integrates in about 6 ms (release build, every second pixel). `swift test -c release --filter Map3DPerformanceTests` prints the current numbers.

## Launch arguments

| Argument | Effect |
| --- | --- |
| `-replay <folder>` | Plays a measure-lab-session v2 folder instead of the camera. A replay without wall taps gets a wall assumed from its trajectory, logged as an assumption. |
| `-autopilot` | Drives every step on a replay, including one gap request closed by frames it held back from the walk. |
| `-serverURL <url>` | Uploads the scan to this server: `POST <url>/v1/placements` with scene.json as `application/json`. Without it the app uses `HOUSESCAN_SERVER_URL` from `Config/Shared.xcconfig` (https://house-scanning-server.vercel.app), carried in Info.plist as `HouseScanServerURL`. Keyframe photos stay on the phone; the scan folder keeps a `scan.zip` of scene.json and the photos for replay and debugging. |
| `-sampleResult` | Answers with the bundled sample result, which the result screen must label as a sample, even when a server is configured. The UI tests pass it so they run offline. It is also the fallback when `HOUSESCAN_SERVER_URL` is empty. |
| `-autopilotHold <s>` | How long the autopilot leaves each screen up (default 1.2 s). |
| `-uiDemo` | Runs the screens on a scripted fake engine instead of the capture engine, for design work and for auditing states a replay can't reach. The arguments it takes are listed in `HouseScan/UI/Preview/UIDemo.swift`. |

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
| `HouseScanUITests/` | Full-flow UI test on a replay, its synthetic fixture, and an accessibility audit of every screen state in demo mode |
| `Tools/make-synthetic-replay.swift` | Renders the synthetic fixture |
| `Tools/check-app-scene.sh` | Checks a scan bundle's scene.json against the server schema |

## Requirements

- Xcode 26 or newer. The deployment target is iOS 26.0 and the code uses only iOS 26 SDK APIs.
- An iPhone that supports ARKit to run it. LiDAR is not required.
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

## Signing and running on a device

1. `cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig`
2. Set `DEVELOPMENT_TEAM` to your Team ID and `BUNDLE_ID_PREFIX` to a prefix your team can register. The app id becomes `<prefix>.housescan`.
3. Open `HouseScan.xcodeproj`, pick your iPhone, and run.

Git ignores `Local.xcconfig`. Leave the team field in Xcode's Signing & Capabilities tab empty. Setting it there writes your team into `project.pbxproj`, and the CI drift check then fails.

## Conventions

- Add Swift files under `HouseScan/`. Xcode includes them without a project change. Edit `project.yml` only for settings, targets or files outside that folder.
- Swift 6 language mode with complete concurrency checking. UI and `ScanEngine` run on the main actor. ARKit delegate callbacks run on a private serial queue and send Sendable frame snapshots to the main actor (see `Runtime/LiveCapture.swift`).
- Never commit captures, photos or measurements of a real home. See the repository CONTRIBUTING.md.
