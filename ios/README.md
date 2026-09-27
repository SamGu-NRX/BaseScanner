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
| `-autopilot` | Drives every step on a replay, answering the ground question with mulch. It holds some walk frames back to close one gap request before the upload. After each upload it also drives the requests the server's answer raises, closing each with the replay's frames, until the result shows. A request the frames don't close gets "I can't get there", as a homeowner would answer. |
| `-serverURL <url>` | Uploads the scan to this server: `POST <url>/v1/placements` with scene.json as `application/json`. Without it the app uses `HOUSESCAN_SERVER_URL` from `Config/Shared.xcconfig` (https://house-scanning-server.vercel.app), carried in Info.plist as `HouseScanServerURL`. Photos stay on the phone unless someone uses Share scan, which shares the scan as a capture packet (see "Scan bundle"), or the homeowner sends the packet (see "Sending the packet"). |
| `-packetUploadURL <url>` | Turns on the packet upload's consent screen and progress card, for testing only: no server API is selected, so nothing is sent (see "Sending the packet"). Without it the app uses `HOUSESCAN_PACKET_UPLOAD_URL` from `Config/Shared.xcconfig`, empty by default, carried in Info.plist as `HouseScanPacketUploadURL`, with an optional key in `HOUSESCAN_PACKET_UPLOAD_KEY`. With no URL the result offers nothing. With `-uiDemo` the demo fakes the transfer, and `-uiDemoPacket <state>` opens the card in a given state. |
| `-packetIntake localTest` | Debug builds only: with `-packetUploadURL`, sends through the test-only adapter to `Tools/packet-intake-test-stub.py`. |
| `-sampleResult` | Answers with the bundled sample result, which the result screen must label as a sample, even when a server is configured. The UI tests pass it so they run offline. It is also the fallback when `HOUSESCAN_SERVER_URL` is empty. |
| `-autopilotHold <s>` | How long the autopilot leaves each screen up (default 1.2 s). |
| `-autopilotCantGetThere` | With `-autopilot`, ends the walk the way device run 1 did. It answers "Can't get there" to the walk's first request, the ground in front of the meter, before the replay has shown it. Then, instead of marking the ends, it plays again the frame where the walk went farthest on each side and answers "Can't get there" when the walk asks to go on that way, so the end lands where the phone stands. `FullFlowUITests.testCantGetThereEndsWhereThePhoneIs` runs it. |
| `-autopilotGate <folder>` | Used by the UI tests. Before leaving a screen, the app waits for a file named after that phase in this folder. Once the result shows, the autopilot writes the scan's scene.json there. |
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
| `Tools/packet-intake-test-stub.py` | A local, test-only stand-in for a packet intake, for the end-to-end upload test |

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

`scan.zip` in the scan's folder is what Share scan sends: a capture packet, version 1.1, with `manifest.json` at the zip's root. The packet's specification is `packet/README.md` on the `t3/packet` branch, with `packet/manifest.schema.json` and a validator (`uv run python -m packet validate <scan.zip>`). The placement upload sends only scene.json. The packet leaves the phone only through Share scan or when the homeowner sends it (next section).

Everything in the packet is in meters, seconds of device uptime (`ARFrame.timestamp`) and the meter frame (origin at the meter, +y up, +z out of the wall, +x along the wall to the right), except scene.json.

| File | Contents |
| --- | --- |
| `manifest.json` | The session (device model, iOS version, LiDAR and what the session ran with, including whether the mesh was classified, capture times, distance walked, the meter frame in ARKit's world), every photo's time, pose, intrinsics, tracking, exposure, lens and sharpness, the depth frames, the streams, plane anchors, marks and the guidance log. Every other file is named in it with its size and sha256. |
| `photos/pNNNNN.jpg` | Every kept keyframe and the meter close-up, in time order, landscape and unrotated as the sensor produced them. |
| `depth/pNNNNN.f32`, `depth/pNNNNN.conf.u8` | Live LiDAR phones only. ARKit's scene depth for the photo, float32 meters along the camera's -z (0 = no reading), and its confidence (0 low, 1 medium, 2 high). ARKit depth without its confidence is left out. |
| `depth_frames/dNNNNN.f32`, `.conf.u8` | LiDAR depth between photos, with no image: 2 a second at most, frames with normal tracking only, at most 300 in a scan (`DepthFrameBudget`). Each has the pose and time of an ARFrame on the trajectory and intrinsics for the depth map's own 256 × 192 grid. The recorder writes each to disk as it arrives. On a replay that recorded depth, the same budget picks from the recording's frames, and the frames carry no `source`. |
| `streams/trajectory.csv` | The camera at every ARFrame (60 Hz), with its tracking state. On a replay, one row per recorded frame. |
| `streams/accelerometer.csv`, `gyroscope.csv`, `magnetometer.csv`, `device_motion.csv`, `barometer.csv` | Core Motion on the phone, 100 Hz except the barometer, from the meter search to the upload. Not recorded on a replay or in the Simulator. |
| `lidar/mesh.ply` | LiDAR phones only. ARKit's mesh in the meter frame with each face's classification, all 0 when `session.device.mesh_classification_enabled` is false. |
| `scene.json` | The scene the server checks (contract C1), unchanged: feet, ground at y = 0. Its `img` names are the scan folder's `k<NNNNN>.jpg`, not the packet's photo names. |

`planes` in the manifest lists ARKit's plane anchors, which every ARKit phone detects. Each plane's pose sits at the centre of its extent, turned by `planeExtent.rotationOnYAxis`, and `boundary_m` is the anchor's boundary polygon in that frame. A plane whose boundary leaves its extent keeps its extent and loses the boundary. A replay has no plane anchors.

`DepthPacket.estimated(meters:sigma:width:height:)` is the entry point for depth a model infers from the image on a phone without LiDAR. It carries a per-pixel standard deviation and no confidence, and goes on a photo or a depth frame. Nothing in the app produces it yet.

The app does not record location or heading, and leaves `session.consent` out. A replay's photos keep the recording's times; their depth is left out because it is not ARKit's own, and its capture has no wall-clock start. On a replay the guidance times follow the latest frame played, which stands still while the gap loop replays earlier frames.

`HouseScan/Runtime/ScanEngine+Packet.swift` assembles the packet, `Runtime/CaptureRecorder.swift` records the streams and depth frames, and `Runtime/GuidanceLog.swift` the requests.

## Sending the packet

After the result, the homeowner can send the capture packet to Base's survey team. It is opt-in: a card on the result opens a consent screen that says what is sent and who gets it, with a toggle that starts off; Send works only once it is on, and Skip is always there. The result never waits for it.

**No server API is selected yet.** Which API the phone sends to is still being decided between teams, so the app talks to the server only through `PacketIntake` (begin or resume a session with a target per file, commit uploaded files, finish), and no adapter for a real server exists. `HOUSESCAN_PACKET_UPLOAD_URL` or `-packetUploadURL` turns on the consent screen and the progress card for testing; Send then logs that no intake is selected and shows that the scan didn't send. Nothing leaves the phone.

- `HouseScanKit/Sources/HouseScanKit/Upload/` holds `PacketIntake`, the file list read from `manifest.json` (every file hashed and checked against it before anything is sent), the saved state, the retry policy, the consent wording and `PacketUploader`, which runs a packet through any intake. Its tests use a mock intake that signs URLs to a `URLProtocol` mock.
- `HouseScan/Runtime/PacketUpload/` uploads each file with `uploadTask(with:fromFile:)` on a background session, so files keep going while the app is suspended. Every file is handed to the session at once, since a suspended app can't start new transfers. `PacketIntakes.swift` is where an adapter for the chosen API goes.
- On Send, the scan folder's `packet/` moves to `packet-sending/`, so a later bundle can't change what is being sent, and `packet-upload.json` beside it records the session, which files are stored and the tries per file, after every change. A scan folder holding that file outlives launches.
- At launch the app picks up every unfinished upload: it begins again with the saved session id, joins transfers the background session is still running, and sends only what the intake doesn't list as stored. When the system wakes the app for finished transfers, `application(_:handleEventsForBackgroundURLSession:completionHandler:)` reconnects the session.
- A failed call or upload is retried after 2 s, doubling to at most 60 s, 6 tries each; 401, 403 or an expired target begin again for fresh targets, 4 times in a row at most; the server can say files are missing 3 times. These numbers are guesses, not measured.
- The consent's `textID` names the exact words on the consent screen (`PacketConsentWording`); a test fails if the words change and the id doesn't.
- Start over cancels the scan's transfers and deletes it. Once the intake says the packet is complete, the copy and the state file go.
- For an end-to-end check in the Simulator, Debug builds have a test-only adapter, `-packetIntake localTest`, for `python3 ios/Tools/packet-intake-test-stub.py --port 8791 --put-delay 0.4`. It mirrors `PacketIntake` and stands for no real server. `PacketUploadUITests.testSendsToTheStubAndResumesAfterRelaunch` runs it when `TEST_RUNNER_HOUSESCAN_PACKET_STUB_URL=http://127.0.0.1:8791` is set.

## Conventions

- Add Swift files under `HouseScan/`. Xcode includes them without a project change. Edit `project.yml` only for settings, targets or files outside that folder.
- Swift 6 language mode with complete concurrency checking. UI and `ScanEngine` run on the main actor. ARKit delegate callbacks run on a private serial queue and send Sendable frame snapshots to the main actor (see `Runtime/LiveCapture.swift`).
- Never commit captures, photos or measurements of a real home. See the repository CONTRIBUTING.md.
