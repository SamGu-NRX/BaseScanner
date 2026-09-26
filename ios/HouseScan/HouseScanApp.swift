import SwiftUI

@main
struct HouseScanApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                UIDemo.makeRoot()
            } else {
                AppRuntime.makeRoot()
            }
        }
    }
}
