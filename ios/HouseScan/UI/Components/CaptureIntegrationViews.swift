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

/// Asks, on the result, whether this scan may go to the test server: what is sent, who gets it,
/// and that skipping changes nothing. The toggle starts off and Send works only once it is on. A
/// yes is remembered for this server, so later scans send while scanning.
struct CaptureConsentSheet: View {
    let answer: (Bool) -> Void
    @State private var agreed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send your scan to the test server?")
                .font(Typeface.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("What's sent").font(Typeface.caption).foregroundStyle(.secondary)
                Label("Photos of your wall and meter", systemImage: "photo")
                Label("Measurements of your wall and your marks", systemImage: "ruler")
                Label("3D data: the camera's path and the phone's motion", systemImage: "move.3d")
            }
            .font(Typeface.hint)
            Text("It goes to the House Scan team's test server. Sending is optional, and your result stays the same if you skip.")
                .font(Typeface.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Send my photos, measurements and 3D data to the test server", isOn: $agreed)
                .font(Typeface.hint)
                .accessibilityIdentifier("captureConsent.agree")
            Spacer(minLength: 0)
            Button { answer(true) } label: {
                Text("Send").font(Typeface.button).frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!agreed)
            .accessibilityIdentifier("captureConsent.send")
            Button { answer(false) } label: {
                Text("Skip").font(Typeface.button).frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("captureConsent.skip")
        }
        .padding(Metrics.edge + 8)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }
}

/// The integration build's two additions: the consent question on the result of a scan that can
/// be sent, and the sync line while a capture is being sent.
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
            .sheet(isPresented: Binding(get: { phase == .result && integration.needsConsent }, set: { _ in })) {
                CaptureConsentSheet { integration.answerConsent($0) }
            }
    }
}
