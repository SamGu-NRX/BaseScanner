import OSLog
import SwiftUI

/// Walks through a fixed list of states, logging each as `STATE=<name>` the way contract C4
/// asks the real app to. `quick` lasts 0.3 s so the runner's transient flag is exercised.
/// Launch arguments are echoed on screen so the runner's argument passing can be checked.
/// With `-replay <folder>`, it also logs whether the app can read `<folder>/session.json`
/// from the host path, which is how the real app receives a replay in the Simulator.
@main
struct StateProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

private let log = Logger(subsystem: "dev.housescanning.housescan", category: "state")
private let steps: [(name: String, seconds: Double)] = [
    ("probe_start", 2), ("quick", 0.3), ("probe_middle", 2), ("probe_done", 2),
]

private func replayFolder() -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "-replay"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

struct ProbeView: View {
    @State private var current = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(current).font(.largeTitle.bold())
            Text(CommandLine.arguments.dropFirst().joined(separator: " "))
                .font(.footnote.monospaced())
            if current == "probe_middle" {
                // Negative control for the accessibility audit: an icon-only button with no
                // label and a 12 pt target. The audit must report it.
                Button {} label: { Image(systemName: "gearshape").font(.system(size: 9)) }
                    .frame(width: 12, height: 12)
            }
        }
        .padding()
        .task {
            if let replay = replayFolder() {
                let url = URL(fileURLWithPath: replay).appendingPathComponent("session.json")
                let readable = (try? Data(contentsOf: url)).map { !$0.isEmpty } ?? false
                log.info("STATE=\(readable ? "replay_readable" : "replay_unreadable", privacy: .public)")
            }
            for step in steps {
                current = step.name
                log.info("STATE=\(step.name, privacy: .public)")
                try? await Task.sleep(for: .seconds(step.seconds))
            }
        }
    }
}
