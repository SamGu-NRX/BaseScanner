import LiveDotsCore
import SwiftUI

/// Everything drawn over the camera besides the dots: the coverage ring at the top and one line
/// of guidance at the bottom. The export renders this same view, so stills match the app.
struct PhoneChrome: View {
    var coverage: Float
    var instruction: Instruction

    var body: some View {
        VStack(spacing: 0) {
            CoverageRing(fraction: coverage)
                .padding(.top, 62)
            Spacer(minLength: 0)
            Text(instruction.text)
                // iOS's .title3 is 20 pt; macOS's is 15, so the size is spelled out to match the phone.
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 58)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
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
