import Foundation
import OSLog

/// Verification hooks from the launch arguments (contract C4).
///
/// - `-replay <folder>`: play a recorded measure-lab-session v2 folder instead of the camera.
/// - `-autopilot`: drive the intents automatically (UI tests, demos).
/// - `-serverURL <url>`: the placement server to upload to. Without it the app uses the build's
///   default, Info.plist `HouseScanServerURL` (set from `HOUSESCAN_SERVER_URL` in
///   Config/Shared.xcconfig); with neither, uploads answer with the bundled sample.
/// - `-sampleResult`: answer uploads with the bundled sample result, flagged as a sample, even
///   when a server is configured. UI tests pass it to stay offline and deterministic.
/// - `-autopilotHold <seconds>`: how long the autopilot leaves each screen up (default 1.2 s).
///   UI tests raise it so each screen stays long enough to screenshot and audit.
/// - `-autopilotGate <folder>`: before the flow leaves a screen, wait until a file named after
///   that phase exists in the folder. UI tests write it once they have screenshotted and audited
///   the screen, so a slow audit can never miss a screen.
/// - `-coverage map3d|legacy`: where coverage comes from (default `map3d`). `map3d` is the 3D
///   occupancy map (`Map3DSession`): scene.json's coverage and walls, the fog overlay, and on a
///   phone with depth the strip's and planners' covered cells. `legacy` is the camera-sighting
///   `CoverageMap` alone. Any other value stops the app: a mistyped flag must not run the other model.
struct LaunchOptions: Equatable {
    enum CoverageModel: String {
        case map3d
        case legacy
    }

    var replayFolder: URL?
    var autopilot = false
    var serverURL: URL?
    var sampleResult = false
    var autopilotHold: Double = 1.2
    var autopilotGate: URL?
    var coverage: CoverageModel = .map3d

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaultServerURL: String? = Bundle.main.object(forInfoDictionaryKey: "HouseScanServerURL") as? String
    ) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let path = value(after: "-replay") {
            replayFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        autopilot = arguments.contains("-autopilot")
        serverURL = (value(after: "-serverURL") ?? defaultServerURL).flatMap(Self.serverURL)
        sampleResult = arguments.contains("-sampleResult")
        if let gate = value(after: "-autopilotGate") { autopilotGate = URL(fileURLWithPath: gate, isDirectory: true) }
        if let hold = value(after: "-autopilotHold").flatMap(Double.init), hold > 0 { autopilotHold = hold }
        if let model = value(after: "-coverage") {
            guard let parsed = CoverageModel(rawValue: model) else { preconditionFailure("-coverage takes map3d or legacy, not \(model)") }
            coverage = parsed
        }
    }

    /// An http(s) URL with a host, or nil. An empty build setting leaves the plist value empty,
    /// and an unexpanded "$(HOUSESCAN_SERVER_URL)" has no scheme; both mean "no server".
    private static func serverURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else { return nil }
        return url
    }
}

/// Log channels. STATE lines are parsed by verification/hsverify/statelog.py, which needs them public.
enum RuntimeLog {
    static let state = Logger(subsystem: "dev.housescanning.housescan", category: "state")
    static let guidance = Logger(subsystem: "dev.housescanning.housescan", category: "guidance")
    static let engine = Logger(subsystem: "dev.housescanning.housescan", category: "engine")
    static let autopilot = Logger(subsystem: "dev.housescanning.housescan", category: "autopilot")
    /// Tracking, relocalization and every capture-gate decision, for reading a real session back.
    /// Only enum-valued reasons, frame ids and counts are public; never meter numbers or images.
    static let capture = Logger(subsystem: "dev.housescanning.housescan", category: "capture")
}
