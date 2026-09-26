import SwiftUI

/// Placeholder until the engine lane lands: builds the engine from the launch arguments and
/// returns `ScanRootView` bound to it.
enum AppRuntime {
    @MainActor
    static func makeRoot() -> some View {
        CaptureScreen()
    }
}
