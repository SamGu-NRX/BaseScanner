import Foundation
import OSLog

/// Verification hooks from the launch arguments (contract C4).
///
/// - `-replay <folder>`: play a recorded measure-lab-session v2 folder instead of the camera.
/// - `-autopilot`: drive the intents automatically (UI tests, demos).
/// - `-serverURL <url>`: the placement server to upload to.
/// - `-sampleResult`: answer uploads with the bundled sample result, flagged as a sample.
/// - `-autopilotHold <seconds>`: how long the autopilot leaves each screen up (default 1.2 s).
///   UI tests raise it so each screen stays long enough to screenshot and audit.
struct LaunchOptions: Equatable {
    var replayFolder: URL?
    var autopilot = false
    var serverURL: URL?
    var sampleResult = false
    var autopilotHold: Double = 1.2

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let path = value(after: "-replay") {
            replayFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        autopilot = arguments.contains("-autopilot")
        serverURL = value(after: "-serverURL").flatMap(URL.init(string:))
        sampleResult = arguments.contains("-sampleResult")
        if let hold = value(after: "-autopilotHold").flatMap(Double.init), hold > 0 { autopilotHold = hold }
    }
}

/// Log channels. STATE lines are parsed by verification/hsverify/statelog.py, which needs them public.
enum RuntimeLog {
    static let state = Logger(subsystem: "dev.housescanning.housescan", category: "state")
    static let guidance = Logger(subsystem: "dev.housescanning.housescan", category: "guidance")
    static let engine = Logger(subsystem: "dev.housescanning.housescan", category: "engine")
    static let autopilot = Logger(subsystem: "dev.housescanning.housescan", category: "autopilot")
}
