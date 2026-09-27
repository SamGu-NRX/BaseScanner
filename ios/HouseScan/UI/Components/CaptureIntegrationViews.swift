import HouseScanKit
import SwiftUI

/// One line under the status bar in the integration build: what the capture API has
/// acknowledged, as counts and the server's own status, never a made-up percentage. Hidden when
/// the build has no capture API or the homeowner said no.
struct CaptureSyncLine: View {
    let status: CaptureUploadStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(text)
                .contentTransition(.numericText())
        }
        .font(.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("captureSyncLine")
        .allowsHitTesting(false)
    }

    private var symbol: String {
        switch status.phase {
        case .creating, .uploading: status.retryingAt == nil ? "arrow.up.circle" : "arrow.clockwise.circle"
        case .processing: "server.rack"
        case .finished: "checkmark.circle"
        case .failed, .abandoned: "exclamationmark.circle"
        }
    }

    private var text: String {
        let received = "\(status.committed) of \(status.retained) received"
        switch status.phase {
        case .creating: return "Test upload: connecting"
        case .uploading: return status.retryingAt == nil ? "Test upload: \(received)" : "Test upload: \(received), retrying"
        case .processing:
            let server = status.backendStatus.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "processing"
            return status.committed < status.retained ? "Test upload: \(received), server \(server)" : "Test upload: server \(server)"
        case .finished: return "Test upload: server test result received"
        case .failed: return "Test upload stopped"
        case .abandoned: return "Test upload ended"
        }
    }
}

/// Asks once, in the integration build only, whether this phone may send its scans to the test
/// server. Nothing is sent before the answer, and nothing after a no.
struct CaptureConsentSheet: View {
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send this scan to the test server?")
                .font(Typeface.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text("This build tests a new upload. While you scan, photos of the wall and meter, the camera's path and the phone's motion go to a test server run by the House Scan team. Your result on this phone is the same either way.")
                .font(Typeface.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { answer(true) } label: {
                Text("Send while I scan").font(Typeface.button).frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("captureConsent.send")
            Button { answer(false) } label: {
                Text("Don't send").font(Typeface.button).frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("captureConsent.skip")
        }
        .padding(Metrics.edge + 8)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

/// The integration build's two additions over any screen: the consent question once the scan
/// has started, and the sync line while a capture is being sent.
struct CaptureIntegrationOverlay: ViewModifier {
    let integration: CaptureIntegration
    let phase: ScanPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let status = integration.status {
                    CaptureSyncLine(status: status)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : Motion.text, value: integration.status)
            // Only an answer closes it; the binding ignores a dismissal.
            .sheet(isPresented: Binding(get: { integration.needsConsent && phase != .onboarding }, set: { _ in })) {
                CaptureConsentSheet { integration.answerConsent($0) }
            }
    }
}
