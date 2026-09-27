import SwiftUI

@main
struct HouseScanApp: App {
    @UIApplicationDelegateAdaptor(HouseScanAppDelegate.self) private var appDelegate

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
