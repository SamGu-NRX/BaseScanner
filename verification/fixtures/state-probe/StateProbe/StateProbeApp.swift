import OSLog
import SwiftUI

/// Walks through a fixed list of states, logging each as `STATE=<name>` the way contract C4
/// asks the real app to. `quick` lasts 0.3 s so the runner's transient flag is exercised.
/// Launch arguments are echoed on screen so the runner's argument passing can be checked.
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

struct ProbeView: View {
    @State private var current = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(current).font(.largeTitle.bold())
            Text(CommandLine.arguments.dropFirst().joined(separator: " "))
                .font(.footnote.monospaced())
        }
        .padding()
        .task {
            for step in steps {
                current = step.name
                log.info("STATE=\(step.name, privacy: .public)")
                try? await Task.sleep(for: .seconds(step.seconds))
            }
        }
    }
}
