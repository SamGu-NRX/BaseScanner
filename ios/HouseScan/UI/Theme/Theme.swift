import SwiftUI

/// Colors, type and motion shared by every screen.
///
/// Colors live in `Assets.xcassets` so they have one definition each. The coverage colors follow
/// the HLD's display table (docs/05 section 2): gray not seen, amber seen, green covered.
enum Palette {
    /// Scrims and text on light surfaces.
    static let ink = Color("Ink")
    /// Text on dark scrims over the camera.
    static let chalk = Color("Chalk")
    /// Primary actions, the walking path and the aiming ring: blue always means "go here, do this".
    static let signal = Color("Signal")
    static let unseen = Color("CoverageUnseen")
    static let seen = Color("CoverageSeen")
    static let covered = Color("CoverageCovered")
    /// "I can't get there": neither fog nor evidence, so it gets its own slate and a hatch.
    static let skipped = Color("CoverageSkipped")
    static let caution = Color("Caution")
    static let danger = Color("Danger")
    static let surface = Color("Surface")
    static let canvas = Color("Canvas")

    static func cell(_ state: CellState) -> Color {
        switch state {
        case .unseen: unseen
        case .seen: seen
        case .covered: covered
        case .skipped: skipped
        }
    }

    /// Darker outcome colors for text and icons on the light result screen, where the bright
    /// coverage colors fall below 4.5:1.
    static let passInk = Color(red: 0.08, green: 0.50, blue: 0.26)
    static let reviewInk = Color(red: 0.56, green: 0.36, blue: 0.0)
    static let failInk = Color(red: 0.76, green: 0.16, blue: 0.12)

    static func outcome(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .pass: covered
        case .unsure: caution
        case .fail: danger
        }
    }

    static func outcomeInk(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .pass: passInk
        case .unsure: reviewInk
        case .fail: failInk
        }
    }
}

enum Typeface {
    /// The one instruction on a camera screen. Rounded, heavy and large so it reads at arm's
    /// length in sun; the camera screens cap Dynamic Type (see `cameraTypeCap`) so it never
    /// covers the wall it is talking about.
    static let instruction = Font.system(.title2, design: .rounded, weight: .bold)
    static let hint = Font.system(.body, design: .rounded, weight: .medium)
    static let screenTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let sectionTitle = Font.system(.title3, design: .rounded, weight: .semibold)
    static let button = Font.system(.headline, design: .rounded, weight: .bold)
    static let caption = Font.system(.footnote, design: .rounded, weight: .semibold)
}

enum Metrics {
    /// Apple's minimum touch target; primary buttons over the camera are taller than this
    /// because the homeowner holds the phone in one hand, often while walking.
    static let minTarget: CGFloat = 44
    static let primaryButtonHeight: CGFloat = 58
    static let cardRadius: CGFloat = 22
    static let edge: CGFloat = 16
}

/// Camera screens keep the camera the hero: type grows through the large accessibility sizes
/// but stops before an instruction card could hide most of the wall.
let cameraTypeCap = DynamicTypeSize.xSmall...DynamicTypeSize.accessibility2

enum Motion {
    /// Screen-to-screen crossfades and card swaps.
    static let screen = Animation.easeOut(duration: 0.25)
    /// Instruction text swaps: fast enough to never delay reading the new line.
    static let text = Animation.easeOut(duration: 0.2)
    /// Pins, the meter ring and the battery reveal: critically damped by default so nothing
    /// wobbles over a live camera; a small bounce only on the pin the homeowner just placed.
    static let settle = Animation.spring(duration: 0.4, bounce: 0)
    static let pin = Animation.spring(duration: 0.45, bounce: 0.25)
    /// Fog lifting off a cell. Slower than UI chrome on purpose: it is the moment the homeowner
    /// learns "the phone saw that", and a longer ease-out reads as mist, not a flicker.
    static let fogLift: TimeInterval = 0.7
}
