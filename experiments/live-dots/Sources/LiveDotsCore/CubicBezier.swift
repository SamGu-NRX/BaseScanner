/// A CSS-style cubic-bezier timing curve from (0, 0) to (1, 1). The Metal shader carries the same
/// solver; this copy is for tests and CPU-side opacity bookkeeping.
public struct CubicBezier: Sendable, Equatable {
    public let x1: Float, y1: Float, x2: Float, y2: Float

    public init(x1: Float, y1: Float, x2: Float, y2: Float) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// `cubic-bezier(0.23, 1, 0.32, 1)`, the strong ease-out every dot transition uses.
    public static let strongEaseOut = CubicBezier(x1: 0.23, y1: 1, x2: 0.32, y2: 1)

    /// The curve's y for x = `progress`, clamped to [0, 1].
    public func callAsFunction(_ progress: Float) -> Float {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var t = progress
        for _ in 0..<8 {
            let error = sample(t, x1, x2) - progress
            if abs(error) < 1e-6 { return sample(t, y1, y2) }
            let slope = derivative(t, x1, x2)
            if abs(slope) < 1e-6 { break }
            t = min(max(t - error / slope, 0), 1)
        }
        var low: Float = 0, high: Float = 1
        for _ in 0..<40 {
            let x = sample(t, x1, x2)
            if abs(x - progress) < 1e-6 { break }
            if x < progress { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(t, y1, y2)
    }

    private func sample(_ t: Float, _ a: Float, _ b: Float) -> Float {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func derivative(_ t: Float, _ a: Float, _ b: Float) -> Float {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }
}
