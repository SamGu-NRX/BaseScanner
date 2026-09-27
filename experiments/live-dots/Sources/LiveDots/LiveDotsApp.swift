import AppKit
import SwiftUI

struct LiveDotsApp: App {
    /// Set by main.swift before launch.
    static var fixtureArgument: String?

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("Live dots") {
            ContentView(fixtureArgument: Self.fixtureArgument)
        }
        .windowResizability(.contentSize)
    }
}

/// A SwiftPM executable has no bundle, so macOS would start it as a background process with no
/// Dock icon and no key window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
