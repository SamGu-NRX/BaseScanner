import simd

/// Deterministic 64-bit hashing (SplitMix64 finaliser) for jitter, thinning and dot order.
/// Swift's `Hasher` is seeded per process, so it can't give a field that looks the same twice.
public enum StableHash {
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public static func hash(_ key: SIMD3<Int32>, seed: UInt64 = 0) -> UInt64 {
        var h = mix(seed)
        h = mix(h ^ UInt64(UInt32(bitPattern: key.x)))
        h = mix(h ^ UInt64(UInt32(bitPattern: key.y)))
        h = mix(h ^ UInt64(UInt32(bitPattern: key.z)))
        return h
    }

    /// A value in [0, 1) from the top 24 bits.
    public static func unit(_ h: UInt64) -> Float {
        Float(h >> 40) / Float(1 << 24)
    }
}

public enum Jitter {
    /// A fixed offset in the plane perpendicular to `normal`, uniform over a disc of radius
    /// `Tuning.jitterFraction * cellSize`, from a hash of the cell index.
    public static func offset(for key: SIMD3<Int32>, normal: SIMD3<Float>, cellSize: Float) -> SIMD3<Float> {
        let (t, b) = tangentBasis(normal)
        let h = StableHash.hash(key, seed: 0x6A17)
        let angle = StableHash.unit(h) * 2 * Float.pi
        let radius = Tuning.jitterFraction * cellSize * StableHash.unit(StableHash.mix(h)).squareRoot()
        return (t * cos(angle) + b * sin(angle)) * radius
    }

    static func tangentBasis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let length = simd_length(n)
        let normal = length > 1e-6 ? n / length : SIMD3<Float>(0, 0, 1)
        let helper: SIMD3<Float> = abs(normal.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let t = simd_normalize(simd_cross(helper, normal))
        return (t, simd_cross(normal, t))
    }
}
