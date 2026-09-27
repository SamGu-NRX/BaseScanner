import MeasureGeometry

/// One accepted tap, resolved to a saved frame, a pixel of its JPEG and the world ray through it.
struct TapInput: Sendable {
    let snapshot: FrameSnapshot
    let pixel: (u: Double, v: Double)
    let ray: Ray
    let frozen: Bool
    let displayMappingCheck: Double?
    /// The ARKit ground raycast, when the tool needs one. Nil means ARKit found no horizontal
    /// surface along the ray, which never counts as open space.
    let ground: GroundHit?
}

struct GroundHit: Sendable {
    enum Surface: String, Sendable {
        /// Inside the extent of a horizontal plane ARKit has found.
        case detectedPlane
        /// On a found plane's infinite extension, past its detected edge.
        case extendedPlane
        /// ARKit's estimate without a found plane.
        case estimatedPlane
    }

    let point: SIMD3<Double>
    let surface: Surface
    let planeAnchor: String?
}
