import SwiftUI

/// The aiming ring at the center of the camera view. Mark measures the pixel under its center.
struct Reticle: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.black.opacity(0.5), lineWidth: 4)
            Circle()
                .stroke(Theme.accent, lineWidth: 2)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2, height: 2)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

/// Where the last tap on a frozen frame landed.
struct TapMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.black.opacity(0.6), lineWidth: 3)
            Circle()
                .stroke(Theme.accent, lineWidth: 1.5)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
