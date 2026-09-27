import SwiftUI

@main
struct MeasureLabApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // The whole UI floats over a camera feed, so one dark appearance keeps panels legible.
                .preferredColorScheme(.dark)
        }
    }
}
