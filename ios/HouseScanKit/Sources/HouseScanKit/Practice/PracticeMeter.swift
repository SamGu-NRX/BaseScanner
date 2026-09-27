import Foundation
import simd

/// Practice meter: a scan with a drawn sample meter standing in for the electric meter, so the
/// whole flow can be tried indoors, where there is no meter. The homeowner taps any spot on a
/// wall, the sample is drawn there, and the close-up's photo is a picture of the sample while its
/// pose stays the live camera's. Everything after the close-up runs as in a real scan.
///
/// Only development and TestFlight installs may turn it on. An App Store install never can, even
/// when the stored setting says so: a scan of a fake meter must not reach a real homeowner.
public enum PracticeMeter {
    /// Where this copy of the app came from, which decides whether practice meter is offered.
    public enum InstallEnvironment: String, Sendable, Equatable, CaseIterable {
        /// A Debug build, or one Xcode installed with StoreKit testing.
        case development
        /// A TestFlight build: StoreKit's app transaction comes from the sandbox.
        case testFlight
        /// An App Store build: the app transaction comes from production.
        case appStore
        /// Not determined yet, or StoreKit couldn't say. Treated like the App Store.
        case unknown
    }

    /// Whether the switch is shown at all.
    public static func isAvailable(in environment: InstallEnvironment) -> Bool {
        switch environment {
        case .development, .testFlight: true
        case .appStore, .unknown: false
        }
    }

    /// Whether a scan started now is a practice scan: the stored switch, and only where the
    /// switch is offered. A setting left on by a TestFlight build is ignored once the same install
    /// is updated from the App Store.
    public static func isOn(requested: Bool, in environment: InstallEnvironment) -> Bool {
        requested && isAvailable(in: environment)
    }

    // MARK: The sample meter

    /// The drawn meter's size on the wall, meters: about a US socket meter's box, 8 by 12 in. The
    /// close-up gate's framing checks were set for a real meter, so the stand-in is the same size.
    public static let plateSize = SIMD2<Float>(0.20, 0.30)
    /// How far in front of the wall the drawing sits: 5 mm, so the fog and the wall's own
    /// outline don't cut through it. The server never sees it.
    public static let plateStandOff: Float = 0.005

    /// The drawn meter's corners in world meters, centered on the tapped point and upright on the
    /// wall: top left, top right, bottom right, bottom left, as someone facing the wall sees them.
    /// `along` is +x of the meter frame (to the right when facing the wall) and `outward` its +z.
    public static func plateCorners(meter: SIMD3<Float>, along: SIMD3<Float>, outward: SIMD3<Float>) -> [SIMD3<Float>] {
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(along) * plateSize.x / 2
        let top = up * plateSize.y / 2
        let center = meter + simd_normalize(outward) * plateStandOff
        return [center - right + top, center + right + top, center + right - top, center - right - top]
    }

    /// The made-up maker printed on the sample. No real maker's name is one edit from it, so the
    /// brand reader names none (`MeterBrand.read`).
    public static let brand = "SAMPLEWORKS"
    /// The sample's meter number: plainly not a real one.
    public static let number = "12345678"

    /// Every line of text on the sample, top to bottom, as the close-up photo prints it. The
    /// drawing prints exactly these strings; a test runs them through the reader's ranking.
    public static let printedLines: [String] = [
        brand,
        "PRACTICE ONLY",
        "0042.7 kWh",
        "CL200 240V FORM 2S",
        "No. \(number)",
    ]
}
