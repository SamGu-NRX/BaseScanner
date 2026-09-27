import SwiftUI

/// Builds the engine from the launch arguments and returns `ScanRootView` bound to it.
@MainActor
enum AppRuntime {
    /// One engine per process: the scene body can be re-evaluated, the scan must not restart.
    static let engine = ScanEngine(options: LaunchOptions())

    static func makeRoot() -> some View {
        RuntimeRoot(engine: engine)
    }
}

private struct RuntimeRoot: View {
    let engine: ScanEngine
    @State private var started = false

    var body: some View {
        ScanRootView(state: engine.state, actions: engine)
            .modifier(CaptureIntegrationOverlay(integration: engine.integration, phase: engine.state.phase))
            .task {
                guard !started else { return }
                started = true
                engine.start()
                if engine.options.autopilot {
                    await Autopilot(engine: engine).run()
                }
            }
    }
}
