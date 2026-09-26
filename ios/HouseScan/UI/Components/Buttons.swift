import SwiftUI

/// The one big action on a screen: solid blue, white bold text, full width. Solid rather than
/// glass because it has to stay legible over a sunlit wall; white on Signal is about 5:1.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.button)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: Metrics.primaryButtonHeight)
            .padding(.horizontal, 20)
            .background(Palette.signal.opacity(isEnabled ? 1 : 0.45), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Second choice next to a primary action: a dark, heavy material so it reads over any camera
/// image without competing with the blue.
struct SecondaryButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? Typeface.button : Typeface.hint.weight(.semibold))
            .foregroundStyle(Palette.chalk)
            .multilineTextAlignment(.center)
            .frame(minHeight: prominent ? Metrics.primaryButtonHeight : 50)
            .padding(.horizontal, 20)
            .background(ScrimShape.capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Buttons on the light text screens: tinted outline style for the second choice.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.button)
            .foregroundStyle(Palette.signal)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(Palette.signal.opacity(configuration.isPressed ? 0.16 : 0.1), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryProminent: SecondaryButtonStyle { SecondaryButtonStyle(prominent: true) }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}
