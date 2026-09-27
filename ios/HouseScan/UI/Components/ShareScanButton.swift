import SwiftUI

/// "Share scan": hands the scan bundle (`ScanViewState.shareableScan`) to the share sheet, so a
/// scan can get off the phone by AirDrop, Mail or Files. The keyframe photos leave the phone only
/// this way, so the line under the button says what goes. Always a quiet button: the screen's
/// one prominent action stays the way on.
struct ShareScanButton: View {
    let url: URL

    var body: some View {
        VStack(spacing: 8) {
            ShareLink(item: url, subject: Text("House Scan")) {
                Label(ScanCopy.shareScan, systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.quiet)
            .accessibilityIdentifier("action.shareScan")
            Text(ScanCopy.shareScanContents)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }
}
