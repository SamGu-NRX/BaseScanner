import SwiftUI

/// Every screen driven by a scripted fake engine, launched with `-uiDemo`.
///
/// Launch arguments (all optional), for screenshots and for trying one screen at a time:
/// - `-uiDemoPhase <phase>`: start at a phase with plausible state (`ScanPhase` raw value).
/// - `-uiDemoFreeze`: don't run the timed scripts, so the screen holds still.
/// - `-uiDemoMarking <FeatureKind raw value>`: open the walk in marking mode.
/// - `-uiDemoRefusal`: the marking shows a refusal.
/// - `-uiDemoCoaching <slowDown|needsTexture|tooDark|holdSteady|relocalizing|trackingLost>`.
/// - `-uiDemoCloseUpFailed`: the close-up has failed twice, so the way out shows.
/// - `-uiDemoMeterChoose`: the close-up asks which of three made-up readings is the meter number.
/// - `-uiDemoOffline`: uploads fail offline.
/// - `-uiDemoRejected`: the server refuses the first upload; "Back to review" then sends it again.
/// - `-uiDemoFailure <cameraDenied|arUnsupported|sessionFailed|replayUnreadable>`: open on the
///   unsupported screen.
/// - `-uiDemoPass`: the sample result is a pass with approved rules.
/// - `-uiDemoNoFeed`: no camera picture, to look at the chrome alone.
/// - `-uiDemoEndQuestion`: the walk asks what is at the left end of the wall.
/// - `-uiDemoSample`: no server is configured, so the upload screen says the result is a sample.
enum UIDemo {
    @MainActor
    static func makeRoot() -> some View {
        DemoHost()
    }
}

private struct DemoHost: View {
    @State private var engine = DemoEngine(arguments: ProcessInfo.processInfo.arguments)

    var body: some View {
        ScanRootView(state: engine.state, actions: engine)
    }
}
