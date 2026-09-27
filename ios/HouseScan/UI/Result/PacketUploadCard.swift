import HouseScanKit
import SwiftUI

/// The result's offer to send the scan to Base's survey team, and, once sent, its progress. It
/// sits below the answer and never holds the result up: the homeowner opens the consent screen
/// from it when they want to, and can go on to the AR view or start over while it sends.
struct PacketUploadCard: View {
    let status: PacketUploadStatus
    let actions: any ScanActions

    /// Set while the consent screen is open, with the packet it describes.
    @State private var consent: ConsentOffer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        // A crossfade between states; the card's own height change stays instant, so nothing
        // below it slides.
        .animation(reduceMotion ? nil : Motion.text, value: kind)
        .sheet(item: $consent) { offer in
            PacketConsentScreen(summary: offer.summary) { given in
                actions.sendPacket(given)
            } onSkip: {
                actions.skipPacket()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packet.card")
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .unavailable:
            EmptyView()
        case .offered(let summary):
            title(PacketUploadCopy.offerTitle)
            detail(PacketUploadCopy.offerBody)
            reviewButton(summary)
        case .skipped(let summary):
            detail(PacketUploadCopy.skippedBody)
            reviewButton(summary)
        case .preparing:
            title(PacketUploadCopy.sendingTitle)
            ProgressView(value: 0)
                .tint(Palette.signalFill)
                .accessibilityHidden(true)
            detail(PacketUploadCopy.preparing)
        case .sending(let progress):
            title(PacketUploadCopy.sendingTitle)
            bar(progress)
            counts(progress)
            detail(PacketUploadCopy.keepUsing)
        case .waiting(let progress):
            title(PacketUploadCopy.waitingTitle)
            bar(progress)
            counts(progress)
            detail(PacketUploadCopy.waitingBody)
        case .sent:
            title(PacketUploadCopy.sentTitle)
            detail(PacketUploadCopy.sentBody)
        case .failed(let progress):
            title(PacketUploadCopy.failedTitle)
            if let progress { counts(progress) }
            detail(PacketUploadCopy.failedBody)
            Button(PacketUploadCopy.retry) { actions.retryPacket() }
                .buttonStyle(.quiet)
                .accessibilityIdentifier("action.packetRetry")
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Typeface.hint.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("packet.title")
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reviewButton(_ summary: PacketUploadSummary) -> some View {
        Button(PacketUploadCopy.review) { consent = ConsentOffer(summary: summary) }
            .buttonStyle(.quiet)
            .padding(.top, 4)
            .accessibilityIdentifier("action.packetReview")
    }

    private func bar(_ progress: PacketUploadProgress) -> some View {
        ProgressView(value: progress.fraction)
            .tint(Palette.signalFill)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress.fraction)
            // The counts below say the same in words.
            .accessibilityHidden(true)
    }

    private func counts(_ progress: PacketUploadProgress) -> some View {
        Text(PacketUploadCopy.progress(progress))
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(PacketUploadCopy.spokenProgress(progress))
            .accessibilityIdentifier("packet.progress")
    }

    /// The state without its numbers, so progress ticks don't restart the crossfade.
    private var kind: Int {
        switch status {
        case .unavailable: 0
        case .offered: 1
        case .skipped: 2
        case .preparing: 3
        case .sending: 4
        case .waiting: 5
        case .sent: 6
        case .failed: 7
        }
    }

    private var symbol: String {
        switch status {
        case .unavailable, .offered, .skipped: "shippingbox"
        case .preparing, .sending: "arrow.up.circle"
        case .waiting: "pause.circle"
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .sent: Palette.passInk
        case .waiting, .failed: Palette.reviewInk
        case .unavailable, .offered, .skipped, .preparing, .sending: Palette.signalText
        }
    }
}

private struct ConsentOffer: Identifiable {
    let id = UUID()
    var summary: PacketUploadSummary
}
