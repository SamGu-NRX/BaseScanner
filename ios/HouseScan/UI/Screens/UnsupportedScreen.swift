import SwiftUI
import UIKit

/// When the scan can't run: camera access is off, the phone can't track motion, the camera
/// stopped, or a recording can't be read. Says what happened and the one thing to do about it:
/// Settings for camera access, a fresh start for a stopped camera or a bad recording. A phone
/// that can't measure has nothing to retry, so it gets advice and no button.
struct UnsupportedScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @Environment(\.openURL) private var openURL

    var body: some View {
        let failure = state.failure ?? .arUnsupported
        let copy = ScanCopy.failure(failure)
        CenteredScroll {
            VStack(spacing: 24) {
                Image(systemName: symbol(failure))
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Palette.signal)
                    .frame(width: 124, height: 124)
                    .background(Palette.signal.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(copy.title)
                        .font(Typeface.screenTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let detail = copy.detail {
                        Text(detail)
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                switch failure {
                case .cameraDenied:
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { openURL(settings) }
                            .buttonStyle(.primary)
                            .accessibilityHint("Opens House Scan's page in Settings, where you can turn on Camera.")
                            .accessibilityIdentifier("action.openSettings")
                    }
                case .sessionFailed, .replayUnreadable:
                    Button("Start over") { actions.startOver() }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("action.startOver")
                case .arUnsupported:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
        .overlay(alignment: .topLeading) {
            ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
                .padding(.horizontal, 24)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }

    private func symbol(_ failure: ScanFailure) -> String {
        switch failure {
        case .cameraDenied: "camera.fill"
        case .arUnsupported: "iphone.slash"
        case .sessionFailed: "exclamationmark.triangle.fill"
        case .replayUnreadable: "doc.badge.ellipsis"
        }
    }
}
