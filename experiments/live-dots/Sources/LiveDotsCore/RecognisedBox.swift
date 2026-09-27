import simd

/// A thing the app would recognise on the wall. Simulated: the rectangles are the synthetic
/// fixture's painted objects, taken from its generator, not detected.
public struct RecognisedBox: Sendable, Equatable {
    public let caption: String
    /// Wall-plane rectangle on z = 0: (minX, minY), (maxX, maxY).
    public let min: SIMD2<Float>
    public let max: SIMD2<Float>
    /// The electric meter is the anchor: solid blue from the first keyframe it is in view.
    public let isMeter: Bool

    public static let fixture: [RecognisedBox] = [
        RecognisedBox(caption: "Electric meter", min: SIMD2(-0.15, 1.3), max: SIMD2(0.15, 1.7), isMeter: true),
        RecognisedBox(caption: "Gas meter", min: SIMD2(-1.35, 0.3), max: SIMD2(-1.05, 0.8), isMeter: false),
        RecognisedBox(caption: "Door", min: SIMD2(-3.4, 0), max: SIMD2(-2.5, 2.05), isMeter: false),
        RecognisedBox(caption: "Window", min: SIMD2(2.0, 0.9), max: SIMD2(3.0, 2.0), isMeter: false),
    ]

    /// Corners in world space, clockwise from top-left as the wall is seen from the front.
    public var corners: [SIMD3<Float>] {
        [SIMD3(min.x, max.y, 0), SIMD3(max.x, max.y, 0), SIMD3(max.x, min.y, 0), SIMD3(min.x, min.y, 0)]
    }

    var centre: SIMD3<Float> { SIMD3((min + max) / 2, 0) }

    private func point(_ u: Float, _ v: Float) -> SIMD3<Float> {
        SIMD3(min.x + (max.x - min.x) * u, min.y + (max.y - min.y) * v, 0)
    }

    private static func inFrame(_ p: SIMD3<Float>, _ projection: ScreenProjection) -> Bool {
        guard let s = projection.screenPoint(p) else { return false }
        return s.x >= 0 && s.y >= 0 && s.x <= projection.viewSize.x && s.y <= projection.viewSize.y
    }

    /// Share of an 11 x 11 grid over the box that lands on screen.
    public func visibleFraction(_ projection: ScreenProjection) -> Float {
        var inside = 0
        for i in 0...10 {
            for j in 0...10 where Self.inFrame(point(Float(i) / 10, Float(j) / 10), projection) { inside += 1 }
        }
        return Float(inside) / 121
    }

    /// Both vertical edges have at least half of their 11 samples on screen.
    public func sidesInFrame(_ projection: ScreenProjection) -> Bool {
        [Float(0), 1].allSatisfy { u in
            (0...10).count { Self.inFrame(point(u, Float($0) / 10), projection) } >= 6
        }
    }

    /// The camera sees the box within 30 degrees of face-on.
    public func isFaceOn(from camera: SIMD3<Float>) -> Bool {
        simd_dot(simd_normalize(camera - centre), SIMD3(0, 0, 1)) >= cos(Float.pi / 6)
    }
}

/// When each box appeared and when it settled, on the playback clock. Sticky: a box that has
/// appeared stays (it simply goes off screen), and a solid box never goes back to dashed.
public struct BoxState: Sendable, Equatable {
    public var appearedAt: Float?
    public var solidAt: Float?

    public init(appearedAt: Float? = nil, solidAt: Float? = nil) {
        self.appearedAt = appearedAt
        self.solidAt = solidAt
    }

    /// Boxes other than the meter appear at 60% in view (dashed, not settled) and turn solid
    /// the first time a keyframe sees them within 30 degrees of face-on with both side edges on
    /// screen. The meter appears solid as soon as its centre is on screen.
    public mutating func update(_ box: RecognisedBox, projection: ScreenProjection, at t: Float) {
        if box.isMeter {
            if appearedAt == nil, box.visibleFraction(projection) > 0,
               let s = projection.screenPoint(box.centre),
               s.x >= 0, s.y >= 0, s.x <= projection.viewSize.x, s.y <= projection.viewSize.y {
                appearedAt = t
                solidAt = t
            }
            return
        }
        if appearedAt == nil, box.visibleFraction(projection) >= 0.6 { appearedAt = t }
        if appearedAt != nil, solidAt == nil, box.isFaceOn(from: projection.cameraPosition), box.sidesInFrame(projection) {
            solidAt = t
        }
    }

    public static func timeline(for keyframes: [Keyframe], boxes: [RecognisedBox] = RecognisedBox.fixture) -> [[BoxState]] {
        var states = boxes.map { _ in BoxState() }
        return keyframes.enumerated().map { index, keyframe in
            let projection = ScreenProjection(keyframe: keyframe, viewSize: SIMD2(390, 844))
            for b in boxes.indices { states[b].update(boxes[b], projection: projection, at: Schedule.start(of: index)) }
            return states
        }
    }
}
