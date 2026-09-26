import SwiftUI

/// Photo count with a small acknowledgment per capture: the icon flashes and the number rolls.
/// The homeowner never presses a shutter, so this is how they learn the phone is taking photos.
struct PhotoCounter: View {
    var count: Int
    var lastCaptureID: Int?

    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(flash ? Palette.covered : Palette.chalk)
                .scaleEffect(flash && !reduceMotion ? 1.18 : 1)
            Text("\(count)")
                .font(Typeface.caption.monospacedDigit())
                .foregroundStyle(Palette.chalk)
                .contentTransition(.numericText(value: Double(count)))
        }
        .padding(.horizontal, 12)
        .frame(minWidth: Metrics.minTarget, minHeight: 36)
        .background(ScrimShape.capsule)
        .animation(.easeOut(duration: 0.18), value: count)
        .onChange(of: lastCaptureID) { _, newValue in
            guard newValue != nil else { return }
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            withAnimation(.easeOut(duration: 0.35).delay(0.12)) { flash = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 photo taken" : "\(count) photos taken")
        .accessibilityIdentifier("photoCount")
    }
}

/// "Replay" or "Autopilot": tells a watcher that the camera or the taps are not live.
struct ModeBadge: View {
    var isReplay: Bool
    var isAutopilot: Bool

    var body: some View {
        if let text {
            Text(text)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.caution, in: .capsule)
                .accessibilityLabel(text)
                .accessibilityIdentifier("modeBadge")
        }
    }

    private var text: String? {
        switch (isReplay, isAutopilot) {
        case (true, true): "Replay · Autopilot"
        case (true, false): "Replay"
        case (false, true): "Autopilot"
        case (false, false): nil
        }
    }
}
