import SwiftUI
import UIKit

/// Shared look. One accent, tape-measure yellow, marks what the app measured; everything else
/// stays neutral so it reads over any camera image in daylight.
enum Theme {
    static let accent = Color(red: 1, green: 0.8, blue: 0)
    /// The same yellow for RealityKit materials, which take UIColor.
    static let accentUIColor = UIColor(red: 1, green: 0.8, blue: 0, alpha: 1)
    static let warning = Color.orange
    static let refused = Color(red: 1, green: 0.45, blue: 0.4)
    static let panelShape = RoundedRectangle(cornerRadius: 16)
    /// Minimum height for anything tappable; above Apple's 44 pt so it works with a glove or in a hurry.
    static let controlHeight: CGFloat = 52
}

extension LabEvent.Tone {
    var color: Color {
        switch self {
        case .accepted: Theme.accent
        case .warning: Theme.warning
        case .refused: Theme.refused
        }
    }

    var systemImage: String {
        switch self {
        case .accepted: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .refused: "xmark.octagon.fill"
        }
    }
}

/// Press feedback for the app's custom buttons: a slight shrink, dropped under Reduce Motion.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
