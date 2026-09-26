import SwiftUI

/// The meter close-up taken at the start, shown while the phone finds its place again, so
/// "Point at the meter like this." has a picture to match (checklist T7).
struct SavedMeterPhoto: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: 168, height: 168)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Your photo of the meter from the start of the scan")
            .accessibilityIdentifier("relocalize.meterPhoto")
    }
}
