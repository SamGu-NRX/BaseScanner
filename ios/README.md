# House Scan for iOS

Native iPhone app for the AR capture walk. The homeowner marks the electric meter, the app takes a close-up of it, then keyframes are captured automatically while they walk the wall. The app asks for any missing stretch, uploads the scan and shows the placement result.

## How it is split

- `HouseScanKit/` is the capture logic as a plain Swift package (Foundation and simd only): camera and wall geometry, the coverage map, the auto-capture and close-up gates, walk guidance, the gap planner, scene.json export, the zip writer, result decoding and replay reading. Its thresholds are hypotheses, documented where they are defined.
- `HouseScan/Runtime/` is the engine: ARKit and replay frame sources, the state machine behind `ScanActions`, keyframe storage, upload and the autopilot.
- `HouseScan/UI/` holds the screens. They read `ScanViewState` and call `ScanActions`; `HouseScan/Contract/ScanContract.swift` is the boundary between the two.

## Launch arguments

| Argument | Effect |
| --- | --- |
| `-replay <folder>` | Plays a measure-lab-session v2 folder instead of the camera. A replay without wall taps gets a wall assumed from its trajectory, logged as an assumption. Keyframes with a `depth` entry (`{file, confidenceFile, w, h}`, Float32 meters) play their LiDAR depth into coverage as a LiDAR phone would. |
| `-autopilot` | Drives every step on a replay. It holds some walk frames back to close one gap request before the upload. After each upload it also drives the requests the server's answer raises, closing each with the replay's frames, until the result shows. A request the frames don't close gets "I can't get there", as a homeowner would answer. |
| `-serverURL <url>` | Uploads the scan to this server: `POST <url>/v1/placements` with scene.json as `application/json`. Without it the app uses `HOUSESCAN_SERVER_URL` from `Config/Shared.xcconfig` (https://house-scanning-server.vercel.app), carried in Info.plist as `HouseScanServerURL`. Keyframe photos stay on the phone unless someone uses Share scan; the scan folder keeps a `scan.zip` of scene.json and the photos for replay and debugging. |
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

`scan.zip` in the scan's folder is what Share scan sends. The upload sends only scene.json.

| File | Contents |
| --- | --- |
| `scene.json` | The scene the server checks (contract C1): feet, gravity-aligned, ground at the wall at y = 0. Each keyframe's pose and intrinsics are in it, and `img` names its photo. |
| `k<NNNNN>.jpg` | Keyframe photos, landscape and unrotated as the sensor produced them, matching the intrinsics in scene.json. |
| `meter_close.jpg` | The meter close-up, when one was taken (scene.json `stills`). |
| `depth/<id>.u16` | LiDAR phones only. The keyframe's depth: uint16 little-endian millimeters, row-major, 0 = no reading. |
| `depth/<id>.conf.u8` | LiDAR phones only. One byte per depth pixel: 0 low, 1 medium, 2 high confidence. |
| `depth/index.json` | LiDAR phones only. `{"units": "mm", "frames": [...]}`, one entry per depth frame: `keyframe`, `file`, `confidence_file` (null without confidence), `w`, `h` and `intrinsics` [fx, fy, cx, cy] in depth pixels. A depth frame has the pose of the scene.json keyframe with the same id. |
| `mesh.ply` | LiDAR phones only. ARKit's reconstructed mesh, binary little-endian PLY: `float x y z` per vertex, then faces as `list uchar uint vertex_indices`. It uses scene.json's frame and units: feet, gravity-aligned, ground at y = 0. |

`HouseScanKit/Sources/HouseScanKit/Scene/BundleFiles.swift` writes the depth files and mesh.ply.

## Conventions

- Add Swift files under `HouseScan/`. Xcode includes them without a project change. Edit `project.yml` only for settings, targets or files outside that folder.
- Swift 6 language mode with complete concurrency checking. UI and `ScanEngine` run on the main actor. ARKit delegate callbacks run on a private serial queue and send Sendable frame snapshots to the main actor (see `Runtime/LiveCapture.swift`).
- Never commit captures, photos or measurements of a real home. See the repository CONTRIBUTING.md.
