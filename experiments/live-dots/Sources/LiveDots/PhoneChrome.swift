import LiveDotsCore
import SwiftUI

/// Everything drawn over the camera besides the dots and fog: the recognised boxes, the ring at
/// the top and one line of guidance at the bottom. The export renders this same view per frame,
/// so stills and videos match the app.
struct PhoneChrome: View {
    var state: KeyframeState
    var keyframe: Keyframe
    var boxes: [BoxState]
    /// Playback seconds; the fades and the hold ring are evaluated here.
    var time: Float

    var body: some View {
        ZStack {
            BoxOverlay(keyframe: keyframe, boxes: boxes, time: time)
            VStack(spacing: 0) {
                CoverageRing(fraction: ringFraction)
                    .padding(.top, 62)
                Spacer(minLength: 0)
                Text(state.instruction.text)
                    // iOS's .title3 is 20 pt; macOS's is 15, so the size is spelled out to match the phone.
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, state.instruction == .tiltDown ? 14 : 58)
                if state.instruction == .tiltDown {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                        .padding(.bottom, 20)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if state.instruction == .walkLeft || state.instruction == .walkRight {
                DistanceBadge(offset: keyframe.cameraPosition.x)
                    .padding(16)
            }
        }
        .allowsHitTesting(false)
    }

    /// While the meter locks, the ring fills over the 1 s hold; otherwise it shows walk coverage.
    private var ringFraction: Float {
        guard state.instruction == .holdStill else { return state.coverage }
        return min(max((time - Schedule.start(of: Schedule.holdIndex)) / Schedule.holdDuration, 0), 1)
    }
}

/// A 28 pt hairline ring that fills clockwise from the top with the covered fraction of the zone
/// around the meter. It jumps to each new value: coverage changes only at keyframes, and a sweep
/// would suggest progress between them that did not happen.
struct CoverageRing: View {
    var fraction: Float

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.hologram.opacity(0.28), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(Palette.hologram, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
        .frame(width: 28, height: 28)
        .shadow(color: .black.opacity(0.35), radius: 3)
        .transaction { $0.animation = nil }
        .accessibilityElement()
        .accessibilityLabel("Wall coverage around the meter")
        .accessibilityValue(Text(Double(fraction), format: .percent.precision(.fractionLength(0))))
    }
}

/// How far along the wall the camera is from the meter, bottom right during the walk, after
/// Starlink's compass badge. 44 pt round; "At meter" is wider than 44 pt at 13 pt, so the badge
/// is a capsule at least 44 pt across rather than a circle that clips it.
struct DistanceBadge: View {
    /// Camera x minus the meter's x, in metres; negative is left of the meter.
    var offset: Float

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .background(.black.opacity(0.45), in: .capsule)
            .accessibilityLabel(accessibilityText)
    }

    private var feet: Int { Int((abs(offset) * 3.28084).rounded()) }

    private var label: String {
        if abs(offset) < 0.3048 { return "At meter" }
        return "\(feet) ft \(offset < 0 ? "←" : "→")"
    }

    private var accessibilityText: String {
        if abs(offset) < 0.3048 { return "At the meter" }
        return "\(feet) feet \(offset < 0 ? "left" : "right") of the meter"
    }
}
