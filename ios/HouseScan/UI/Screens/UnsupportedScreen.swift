import SwiftUI
import UIKit

/// When the scan can't run: camera access is off, the phone can't track motion, or a recording
/// can't be read. Says what happened and the one thing to do about it.
struct UnsupportedScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

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
                if failure == .cameraDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: settings) {
                        Text("Open Settings")
                            .font(Typeface.button)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: Metrics.primaryButtonHeight)
                            .background(Palette.signal, in: .capsule)
                    }
                    .accessibilityIdentifier("action.openSettings")
                } else if failure != .arUnsupported {
                    Button("Start over") { actions.startOver() }
                        .buttonStyle(.quiet)
                        .accessibilityIdentifier("action.startOver")
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
