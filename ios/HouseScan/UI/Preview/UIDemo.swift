import SwiftUI

/// Placeholder until the UI lane lands: screens driven by scripted fake state, launched with `-uiDemo`.
enum UIDemo {
    @MainActor
    static func makeRoot() -> some View {
        Text("UI demo")
    }
}
