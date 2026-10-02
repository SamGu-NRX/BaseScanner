import SwiftUI

@main
struct HouseScanApp: App {
    /// Runs once per process, before any window exists: share copies made before this moment
    /// belong to an earlier run, whose share sheet can't still be reading them. Not a view's
    /// `.task`, which runs again for each window or reappearance and would take a later cutoff,
    /// one that could cover a copy this run is sharing.
    init() {
        let launch = Date(), staging = SavedScansLocation.staging
        Task.detached(priority: .utility) { staging.removeCopies(madeBefore: launch) }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                    UIDemo.makeRoot()
                } else {
                    AppRuntime.makeRoot()
                }
            }
            // Compiles the live fog's shaders in the background long before the walk needs them.
            .task { LiveFogSupport.shared.prepare() }
        }
    }
}
