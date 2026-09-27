import Foundation

/// CPU copies of the fog shader's two scalar rules (Shaders.swift, `blurFragment` and
/// `lagFragment`), so the tests can pin them. See the header of Shaders.swift's fog section for
/// the whole layer and what it borrows.
public enum FogMask {
    /// Reveal strength after blur: clamped to 1, then smoothstep from 0.12 to 0.55.
    public static let revealLow: Float = 0.12
    public static let revealHigh: Float = 0.55
    /// The lagged mask eases up toward the reveal with this time constant, so the fog lifts a
    /// beat after the dots arrive.
    public static let lagTimeConstant: Float = 0.6
    /// Fog returns faster than it lifts. A single 600 ms lag both ways left the sky clear for most
    /// of a second after the tilt cut, the reveal trailing a view that had moved on.
    public static let returnTimeConstant: Float = 0.12
    /// Under Reduce Motion both directions are linear fades of these lengths instead.
    public static let reducedFade: Float = 0.4
    public static let reducedReturn: Float = 0.12

    public static func shape(_ accumulated: Float) -> Float {
        let x = min(max((min(accumulated, 1) - revealLow) / (revealHigh - revealLow), 0), 1)
        return x * x * (3 - 2 * x)
    }

    public static func lagStep(from previous: Float, toward target: Float, dt: Float, reduceMotion: Bool) -> Float {
        let lifting = target > previous
        if reduceMotion {
            let step = dt / (lifting ? reducedFade : reducedReturn)
            return previous + min(max(target - previous, -step), step)
        }
        return previous + (target - previous) * (1 - exp(-dt / (lifting ? lagTimeConstant : returnTimeConstant)))
    }
}
