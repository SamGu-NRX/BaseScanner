import Foundation
import simd

/// Which layer draws the result on "See it on your wall": the AR scene (RealityKit) or the
/// screen's own drawing over the camera (the Canvas). Exactly one of them draws it at a time.
///
/// The Canvas is the default. The AR scene takes over only once the app has seen it drawing the
/// result for `confirmation` seconds without a break. It keeps it while it holds the result
/// (anchored and enabled), whether or not the battery is in view, and gives it back at once when
/// it stops holding it. Build 4.1 hid the Canvas as soon as the model was handed to the AR scene;
/// on a phone where the scene then drew nothing, the homeowner saw no battery at all.
///
/// A confirmation covers one model. The policy also decides when a model has to be built
/// (`needsModel`), and every new model starts back on the Canvas: a model rebuilt for a moved
/// wall is a new entity nobody has seen drawn yet.
///
/// The engine shows only the owner: the Canvas while `usesRealityKit` is false, the AR scene's
/// model while it is true. The model is made see-through rather than disabled while the Canvas
/// owns the result, so the checks behind `drawn` and `held` still run on it
/// (`ScanEngine.setResultInCamera`).
public struct ResultOverlayPolicy: Sendable, Equatable {
    /// How long the AR scene has to be seen drawing before the Canvas steps aside: long enough
    /// to ride out a frame or two of an anchor settling. A guess, not measured on a phone.
    public static let confirmation: Double = 0.5

    /// True while the AR scene draws the result and the Canvas should not.
    public private(set) var usesRealityKit = false
    /// The wall the AR scene's model was built for; nil when there is none.
    public private(set) var builtFor: ResultModelShape?
    /// The AR scene has been seen drawing this model for `confirmation` seconds.
    private var confirmed = false
    /// When the current unbroken run of "drawn" began; nil while the AR scene isn't drawing.
    private var drawnSince: Double?

    public init() {}

    /// Takes one look at the AR scene at `time` in seconds (any clock that only goes forward) and
    /// returns `usesRealityKit`.
    ///
    /// - `drawn`: the AR scene would draw the result now, with the battery's middle in view.
    ///   Only this confirms the model.
    /// - `held`: the AR scene holds the result, drawn or not: anchored and enabled, with the
    ///   battery perhaps out of view. Once the model is confirmed it keeps the result while
    ///   `held`, and gets it back as soon as it holds it again (tracking came back). Going back to
    ///   the Canvas whenever the battery left the view put a second, unoccluded cable and tint a
    ///   few centimetres off RealityKit's own, with the phone on the meter (review of #100).
    ///   `drawn` implies `held`.
    @discardableResult
    public mutating func update(drawn: Bool, held: Bool, time: Double) -> Bool {
        let held = held || drawn
        guard held else {
            drawnSince = nil
            usesRealityKit = false
            return false
        }
        if confirmed {
            usesRealityKit = true
            return true
        }
        guard drawn else {
            drawnSince = nil
            return false
        }
        // A clock that ran back restarts the run rather than confirming it early.
        if let since = drawnSince, since <= time {
            if time - since >= Self.confirmation {
                confirmed = true
                usesRealityKit = true
            }
        } else {
            drawnSince = time
        }
        return usesRealityKit
    }

    /// Whether a model for a wall of `shape` has to go into the AR scene: there is none yet,
    /// `rising` (the screen just opened), or the wall moved or turned past the tolerances since
    /// the last one was built (`ResultModelShape.isClose`). A wall that moved by a centimeter or
    /// two keeps its model, which hangs on the meter's anchor and follows its corrections anyway.
    ///
    /// When it has to, the result goes back to the Canvas at once, and the new model has to be
    /// seen drawing for `confirmation` seconds before the Canvas steps aside again. Kept
    /// confirmed, a rebuilt model that looked anchored and in view at the next look took over at
    /// once, and if it drew nothing the homeowner saw no battery (Codex review of #100). The
    /// caller then puts the model in, or calls `modelRemoved` if it couldn't.
    public mutating func needsModel(for shape: ResultModelShape, rising: Bool) -> Bool {
        if !rising, let builtFor, builtFor.isClose(to: shape) { return false }
        builtFor = shape
        backToTheCanvas()
        return true
    }

    /// There is no model in the AR scene any more: it couldn't go in, or it was taken out.
    public mutating func modelRemoved() {
        builtFor = nil
        backToTheCanvas()
    }

    private mutating func backToTheCanvas() {
        confirmed = false
        drawnSince = nil
        usesRealityKit = false
    }
}

/// What the AR result's model is built from, reduced to what `ResultOverlayPolicy.needsModel`
/// compares: points (the meter, corner anchors), lengths (the ground's height, the ends, corner
/// spans) and directions (along the wall, out from it). The engine fills it from its wall in a
/// fixed order, so two shapes line up entry by entry.
public struct ResultModelShape: Sendable, Equatable {
    public var points: [SIMD3<Float>]
    public var values: [Float?]
    public var directions: [SIMD3<Float>]

    public init(points: [SIMD3<Float>], values: [Float?], directions: [SIMD3<Float>]) {
        self.points = points
        self.values = values
        self.directions = directions
    }

    /// A wall change under these leaves the model as built: a few centimeters is within what the
    /// ground and the meter's anchor are known to. Display choices, not measured.
    public static let rebuildDistance: Float = 0.05
    public static let rebuildTurnDegrees: Float = 2

    /// True when `other` is this shape moved by less than `rebuildDistance` and turned by less
    /// than `rebuildTurnDegrees` in every entry, with the same number of each.
    public func isClose(to other: ResultModelShape) -> Bool {
        guard points.count == other.points.count, values.count == other.values.count,
              directions.count == other.directions.count else { return false }
        let turnCosine = cos(Self.rebuildTurnDegrees * .pi / 180)
        let pointsClose = zip(points, other.points).allSatisfy { simd_distance($0, $1) < Self.rebuildDistance }
        let valuesClose = zip(values, other.values).allSatisfy { pair in
            guard let a = pair.0, let b = pair.1 else { return pair.0 == nil && pair.1 == nil }
            // Equal first: a corner piece's span is infinite toward its open end.
            return a == b || abs(a - b) < Self.rebuildDistance
        }
        let directionsClose = zip(directions, other.directions).allSatisfy {
            simd_dot(simd_normalize($0), simd_normalize($1)) > turnCosine
        }
        return pointsClose && valuesClose && directionsClose
    }
}
