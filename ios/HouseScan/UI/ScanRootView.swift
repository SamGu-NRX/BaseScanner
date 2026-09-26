import SwiftUI

/// Placeholder until the UI lane lands: the root of every screen, switched on `state.phase`.
/// Each screen's root view carries the accessibility identifier `screen.<phase.rawValue>`.
struct ScanRootView: View {
    let state: ScanViewState
    let actions: any ScanActions

    var body: some View {
        Text(state.phase.rawValue)
            .accessibilityIdentifier("screen.\(state.phase.rawValue)")
    }
}
