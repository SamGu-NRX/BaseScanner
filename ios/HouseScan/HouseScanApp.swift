import SwiftUI

@main
struct HouseScanApp: App {
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
