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
///   the screen, so a slow audit can never miss a screen. After the result shows, the autopilot
///   also writes the scan's scene.json there, for the test to check.
/// - `-autopilotCantGetThere`: the autopilot ends the walk with "Can't get there" instead of
///   marking the ends (`Autopilot.endWalkByCantGetThere`).
/// - `-autopilotSomethingThere`: the autopilot answers the first spot check "Something's there"
///   instead of "It's clear", so the scan is checked again without that area.
/// - `-autopilotShowResult`: the autopilot taps "Show my result" on the first request the
///   server's answer raises, so no further request is raised (issue #39).
struct LaunchOptions: Equatable {
    var replayFolder: URL?
    var autopilot = false
    var serverURL: URL?
    var sampleResult = false
    var autopilotHold: Double = 1.2
    var autopilotGate: URL?
    var autopilotCantGetThere = false
    var autopilotSomethingThere = false
    var autopilotShowResult = false

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
        autopilotCantGetThere = arguments.contains("-autopilotCantGetThere")
        autopilotSomethingThere = arguments.contains("-autopilotSomethingThere")
        autopilotShowResult = arguments.contains("-autopilotShowResult")
        serverURL = (value(after: "-serverURL") ?? defaultServerURL).flatMap(Self.serverURL)
        sampleResult = arguments.contains("-sampleResult")
        if let gate = value(after: "-autopilotGate") { autopilotGate = URL(fileURLWithPath: gate, isDirectory: true) }
        if let hold = value(after: "-autopilotHold").flatMap(Double.init), hold > 0 { autopilotHold = hold }
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
