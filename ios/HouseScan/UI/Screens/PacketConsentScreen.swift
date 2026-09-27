import HouseScanKit
import SwiftUI

/// Asks whether to send the scan to Base's survey team: what goes, who gets it, and that it's
/// optional, then an agreement toggle that starts off. Send works only once the toggle is on.
/// Skip sits in the sheet's top corner, where iOS puts the way out of a sheet, so it shows at
/// every text size; swiping the sheet away decides nothing.
///
/// The list of what's sent is set like a packing slip, with the photo count beside the photos
/// and the total under a perforated rule: the homeowner is handing over a package, and this is
/// its contents. The words are `PacketConsentWording.current`, whose id goes with the consent.
struct PacketConsentScreen: View {
    let summary: PacketUploadSummary
    let onSend: (PacketUploadConsent) -> Void
    let onSkip: () -> Void

    @State private var form = PacketConsentForm()
    @Environment(\.dismiss) private var dismiss
    private let wording = PacketConsentWording.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                slip
                VStack(alignment: .leading, spacing: 14) {
                    fact("person.2", wording.recipient)
                    fact("hand.raised", wording.optional)
                }
                agreement
                Button(wording.send) {
                    guard let consent = form.consent(wording, at: Date()) else { return }
                    onSend(consent)
                    dismiss()
                }
                .buttonStyle(.primary)
                .disabled(!form.canSend)
                .animation(.easeOut(duration: 0.15), value: form.canSend)
                .accessibilityHint(form.canSend ? "" : "Turn on the switch above first.")
                .accessibilityIdentifier("action.packetSend")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.canvas.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.canvas)
        .sensoryFeedback(.selection, trigger: form.agreed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.packetConsent")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.signalText)
                    .accessibilityHidden(true)
                Spacer()
                Button(wording.skip) {
                    onSkip()
                    dismiss()
                }
                .font(Typeface.hint.weight(.semibold))
                .foregroundStyle(Palette.signalText)
                .frame(minWidth: Metrics.minTarget, minHeight: Metrics.minTarget)
                .contentShape(.rect)
                .accessibilityHint("Nothing is sent. Your result stays the same.")
                .accessibilityIdentifier("action.packetSkip")
            }
            Text(wording.title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(wording.intro)
                .font(Typeface.hint)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var slip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(wording.sentHeading)
                .font(Typeface.caption)
                .foregroundStyle(Palette.muted)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            item("photo.on.rectangle", wording.photos, count: PacketUploadCopy.photos(summary.photos))
            Divider().padding(.leading, 52)
            item("ruler", wording.measurements)
            Divider().padding(.leading, 52)
            item("cube", wording.threeD)
            Perforation()
                .stroke(Palette.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .accessibilityHidden(true)
            Text(PacketUploadCopy.total(summary.bytes))
                .font(Typeface.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(16)
        }
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("packet.contents")
    }

    private func item(_ symbol: String, _ text: String, count: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.signalText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(Typeface.hint)
                    .fixedSize(horizontal: false, vertical: true)
                if let count {
                    Text(count)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.muted)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(Typeface.hint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private var agreement: some View {
        Toggle(isOn: $form.agreed) {
            Text(wording.agreement)
                .font(Typeface.hint.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Palette.signalFill)
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("packet.consentToggle")
    }
}

/// A horizontal line through the middle of its frame, dashed by the stroke.
private struct Perforation: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
