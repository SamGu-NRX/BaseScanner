import Foundation

// Vector helpers on the standard library's SIMD3<Double>. The `simd` module has equivalents, but it
// does not exist on Linux. These stay internal so they never shadow `simd` inside the app.

extension SIMD3 where Scalar == Double {
    func dot(_ other: Self) -> Double {
        (self * other).sum()
    }

    func cross(_ other: Self) -> Self {
        Self(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    var length: Double {
        dot(self).squareRoot()
    }

    /// The vector with its vertical (y) component removed.
    var horizontal: Self {
        Self(x, 0, z)
    }
}

/// World up under ARKit's `.gravity` alignment: y points away from gravity.
let worldUp = SIMD3<Double>(0, 1, 0)

func degrees(fromRadians radians: Double) -> Double {
    radians * 180 / .pi
}

func radians(fromDegrees degrees: Double) -> Double {
    degrees * .pi / 180
}

/// `acos` in degrees with the cosine clamped to [-1, 1], so a rounding error just past 1 gives
/// 0° instead of NaN.
func acosDegrees(_ cosine: Double) -> Double {
    degrees(fromRadians: acos(min(1, max(-1, cosine))))
}
