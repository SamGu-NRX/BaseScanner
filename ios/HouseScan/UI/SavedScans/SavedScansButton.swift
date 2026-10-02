import SwiftUI

/// The way into Saved scans, in the onboarding's top bar. Quiet like the Skip beside it: the
/// onboarding's one prominent action stays starting a new scan.
///
/// The button only asks for the sheet; the screen holds it (`savedScansSheet(isPresented:)`). The
/// top bar swaps layouts at accessibility text sizes, which makes a new button, and a sheet owned
/// by the button closed whenever the text size changed under it.
struct SavedScansButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(SavedScansCopy.entry, systemImage: "tray.full")
                .font(Typeface.hint.weight(.semibold))
                .foregroundStyle(Palette.signalText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: Metrics.minTarget, minHeight: Metrics.minTarget)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("action.savedScans")
    }
}

extension View {
    /// Saved scans, presented from a view that stays put while the text size changes.
    func savedScansSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            SavedScansSheet(catalog: SavedScansLocation.catalog(), staging: SavedScansLocation.staging)
        }
    }
}
