# House Scan for iOS

Native iPhone app for the AR capture walk. It currently runs an ARKit world-tracking session and shows whether tracking works. It does not capture, save or upload anything yet.

## What the app does now

- Opens a full-screen camera view running `ARWorldTrackingConfiguration` with horizontal and vertical plane detection.
- Shows the tracking state in plain words ("Move your phone slowly", "Slow down") and how many horizontal and vertical surfaces ARKit has found.
- Records whether the device supports LiDAR scene depth (`CaptureSessionModel.lidarAvailable`) without turning depth on. The app runs on any iPhone that supports ARKit world tracking.
- Shows a message instead of the camera when world tracking is unsupported, for example in the Simulator, and a Settings link when camera access is off.
- Pauses the AR session when the camera view goes away.

## Layout

| Path | Contents |
| --- | --- |
| `project.yml` | XcodeGen spec, the source of truth for the project |
| `HouseScan.xcodeproj` | Generated from `project.yml` and committed |
| `HouseScan/` | Swift sources, a synchronized folder |
| `Config/Shared.xcconfig` | Settings for all configurations; includes `Local.xcconfig` if present |
| `Config/Local.xcconfig.example` | Template for per-person signing |
| `Config/Info.plist` | Camera prompt, `arkit` capability, portrait only |

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
- Swift 6 language mode with complete concurrency checking. UI and `CaptureSessionModel` run on the main actor. ARKit delegate callbacks run on a private serial queue and send Sendable values to the main actor (see `SessionDelegate.swift`).
- Never commit captures, photos or measurements of a real home. See the repository CONTRIBUTING.md.
