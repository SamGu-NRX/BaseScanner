import HouseScanKit
import SwiftUI
import UIKit

#if HOUSESCAN_INTEGRATION
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
        .accessibilityHint("Shows the capture ID and the server's answer")
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

/// Asks, before a scan in the integration build, whether this scan may go to the test server
/// while it is taken: what is sent, who gets it, and that skipping changes nothing. The toggle
/// starts off and Send works only once it is on. The answer covers this scan only.
struct CaptureConsentSheet: View {
    let answer: (Bool) -> Void
    @State private var agreed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this scan to the House Scan team?")
                .font(Typeface.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("What's sent while you scan").font(Typeface.caption).foregroundStyle(.secondary)
                Label("Photos of your wall and meter", systemImage: "photo")
                Label("Measurements of your wall and your marks", systemImage: "ruler")
                Label("3D data: the camera's path and the phone's motion", systemImage: "move.3d")
            }
            .font(Typeface.hint)
            // Consent text wraps; a line cut short would hide part of what is sent.
            .fixedSize(horizontal: false, vertical: true)
            Text("It goes to the House Scan team's test server, for this scan only. Skipping changes nothing about your result.")
                .font(Typeface.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I agree to send this scan", isOn: $agreed)
                .font(Typeface.hint)
                .accessibilityIdentifier("captureConsent.agree")
            Spacer(minLength: 0)
            Button { answer(true) } label: {
                Text("Send").font(Typeface.button).frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!agreed)
            // The whole button dims while it can't be pressed, so its label never sits at low
            // contrast on a still-colored fill.
            .opacity(agreed ? 1 : 0.45)
            .accessibilityIdentifier("captureConsent.send")
            Button { answer(false) } label: {
                Text("Skip").font(Typeface.button).frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("captureConsent.skip")
        }
        .padding(Metrics.edge + 8)
        // Medium, so the camera stays in view behind the question about the scan it is about to take.
        .presentationDetents([.medium])
        // Opaque enough that the camera screen's own buttons don't show through behind Skip.
        .presentationBackground(.thickMaterial)
        .interactiveDismissDisabled()
    }
}

#endif

/// The capture API side of the scan, for the operator: the capture ID to join the viewer to, what
/// was received, and the server's own answer, labelled as the test server's and never as the
/// placement result the result card shows.
struct CaptureIntegrationDetails: View {
    let status: CaptureUploadStatus
    let result: CaptureResult.Record?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("This scan on the capture API") {
                    if let id = status.captureID {
                        HStack {
                            Text(id).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button(copied ? "Copied" : "Copy") {
                                UIPasteboard.general.string = id
                                copied = true
                            }
                            .accessibilityIdentifier("integration.copyCaptureID")
                        }
                    } else {
                        Text("Not created yet")
                    }
                    LabeledContent("Received", value: "\(status.committed) of \(status.retained) files")
                    LabeledContent("Server status", value: status.backendStatus.map(Self.words) ?? "Not reported")
                    if let event = status.lastEvent { LabeledContent("Last event", value: event) }
                }
                Section {
                    resultRows
                } header: {
                    Text("Test server's answer")
                } footer: {
                    Text("From the House Scan team's test server. Its analysis is not verified, so this is not a real assessment. The result card shows the placement server's answer, not this one.")
                }
            }
            .navigationTitle("Capture API test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .accessibilityIdentifier("integration.details")
    }

    @ViewBuilder
    private var resultRows: some View {
        if let result {
            let summary = CaptureResultSummary(result, world: result.association, meterAnchor: nil)
            LabeledContent("Decision", value: Self.state(summary.state))
            if let message = summary.message {
                Text(message).accessibilityIdentifier("integration.resultMessage")
            }
            ForEach(Array(summary.prompts.enumerated()), id: \.offset) { _, prompt in
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title).font(.headline)
                    Text(prompt.body)
                }
            }
            if let criteria = summary.criteria {
                ForEach(criteria, id: \.id) { criterion in
                    LabeledContent(criterion.id, value: Self.criterion(criterion.outcome))
                }
            }
            LabeledContent("AR", value: summary.arUnavailable.map(Self.arReason) ?? "Available")
        } else {
            Text(status.sealed ? "Waiting for the server" : "The scan is still being sent")
        }
    }

    static func words(_ text: String) -> String { text.replacingOccurrences(of: "_", with: " ") }

    static func state(_ state: CaptureResultSummary.State) -> String {
        switch state {
        case .working(let status): "Still working (\(Self.status(status)))"
        case .decided(let kind):
            switch kind {
            case .eligible: "Eligible"
            case .needsMorePhotos: "Needs more photos"
            case .notEligible: "Not eligible"
            case .manualReview: "Manual review"
            case .unknown(let raw): "Unknown: \(raw)"
            }
        }
    }

    static func status(_ status: CaptureResult.Status) -> String {
        if case .unknown(let raw) = status { return raw }
        return words(String(describing: status))
    }

    static func criterion(_ outcome: CaptureResult.CriterionOutcome) -> String {
        switch outcome {
        case .pass: "Pass"
        case .fail: "Fail"
        case .unsure: "Unsure"
        case .unknown(let raw): raw
        }
    }

    static func arReason(_ reason: CaptureResult.Unavailable) -> String {
        switch reason {
        case .noOutcome: "No decision yet"
        case .notEligible: "No spot to show"
        case .statusNotComplete: "The run is not complete"
        case .analysisUnverified: "Off: the analysis is not verified"
        case .mismatch: "Off: this answer belongs to another scan"
        case .noPlacement: "The server sent no spot"
        case .notInARKitWorld: "The server's scene is not in this phone's AR world"
        case .malformedBox: "The server's box could not be read"
        case .invalidMeterAnchor: "Off: no meter anchor for this scan"
        }
    }
}

/// The integration build's two additions: the consent question when a scan that can be sent
/// starts (before the meter is marked), and the sync line while a capture is being sent.
struct CaptureIntegrationOverlay: ViewModifier {
    let integration: CaptureIntegration
    let phase: ScanPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetails = false

    func body(content: Content) -> some View {
        #if HOUSESCAN_INTEGRATION
        content
            // Trailing: the replay and sample badges sit top-leading.
            .overlay(alignment: .topTrailing) {
                if let status = integration.status {
                    Button { showsDetails = true } label: { CaptureSyncLine(status: status) }
                        .buttonStyle(.plain)
                        .frame(minHeight: Metrics.minTarget)
                        .padding(.trailing, Metrics.edge)
                        .transition(.opacity)
                }
            }
            .sheet(isPresented: $showsDetails) {
                if let status = integration.status {
                    CaptureIntegrationDetails(status: status, result: integration.result)
                }
            }
            .animation(reduceMotion ? nil : Motion.text, value: integration.status)
            // Only an answer closes it; the binding ignores a dismissal.
            .sheet(isPresented: Binding(get: { phase == .findMeter && integration.needsConsent }, set: { _ in })) {
                CaptureConsentSheet { integration.answerConsent($0) }
            }
        #else
        content
        #endif
    }
}
