import SwiftUI

/// A ring that blooms outward and fades where the homeowner touched: immediate proof the tap
/// landed, independent of how long the engine takes to answer.
struct TapRipple: View {
    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        var point: CGPoint
    }

    @Binding var ripples: [Ripple]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(ripples) { ripple in
                RippleRing(reduceMotion: reduceMotion)
                    .position(ripple.point)
                    .task {
                        try? await Task.sleep(for: .milliseconds(650))
                        ripples.removeAll { $0.id == ripple.id }
                    }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RippleRing: View {
    var reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 4)
            .frame(width: 70, height: 70)
            .scaleEffect(reduceMotion ? 1 : (expanded ? 1.35 : 0.7))
            .opacity(expanded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) { expanded = true }
            }
    }
}
