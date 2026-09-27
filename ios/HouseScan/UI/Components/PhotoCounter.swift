import SwiftUI

/// Photo count with a small acknowledgment per capture: the icon flashes and the number changes.
/// The homeowner never presses a shutter, so this is how they learn the phone is taking photos.
///
/// The number swaps without animation. A rolling digit passes through half-faded frames, and
/// the accessibility audit caught those as contrast failures ("22", "72" on the real replay).
struct PhotoCounter: View {
    var count: Int
    var lastCaptureID: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.fill")
                .font(.subheadline.weight(.bold))
                .phaseAnimator([false, true, false], trigger: lastCaptureID) { icon, lit in
                    icon
                        .foregroundStyle(lit ? Palette.covered : Palette.chalk)
                        .scaleEffect(lit && !reduceMotion ? 1.18 : 1)
                } animation: { lit in
                    lit ? .easeOut(duration: 0.08) : .easeOut(duration: 0.35)
                }
            Text("\(count)")
                .font(Typeface.caption.monospacedDigit())
                .foregroundStyle(Palette.chalk)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: Metrics.minTarget, minHeight: 36)
        .background(ScrimShape.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 photo taken" : "\(count) photos taken")
        .accessibilityIdentifier("photoCount")
    }
}

/// "Replay" or "Autopilot": tells a watcher that the camera or the taps are not live. A small
/// quiet pill rather than an amber one: amber means "look at this" on the camera screens, and a
/// test mode shouldn't compete with the instruction. Ink at 0.7 keeps Chalk text about 6.9:1 on
/// the light Canvas; at 0.55 it measured about 4.2:1, under the 4.5:1 small text needs.
struct ModeBadge: View {
    var isReplay: Bool
    var isAutopilot: Bool

    var body: some View {
        if let text {
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.chalk)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.ink.opacity(0.7), in: .capsule)
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
