import SwiftUI

enum Palette {
    /// The dots' one colour, #E6ECF4.
    static let hologram = Color(red: 0xE6 / 255, green: 0xEC / 255, blue: 0xF4 / 255)
    /// The glow around every Hologram dot, #9CC8FF.
    static let glow = Color(red: 0x9C / 255, green: 0xC8 / 255, blue: 0xFF / 255)
    /// Dots on the occluder, core and glow, #B49CFF.
    static let hiddenViolet = Color(red: 0xB4 / 255, green: 0x9C / 255, blue: 0xFF / 255)
    static let window = Color(red: 0.055, green: 0.059, blue: 0.071)
}
