import Foundation

/// Which layer draws the result on "See it on your wall": the AR scene (RealityKit) or the
/// screen's own drawing over the camera (the Canvas). Exactly one of them draws it at a time.
///
/// The Canvas is the default. The AR scene takes over only once the app has seen it drawing the
/// result for `confirmation` seconds without a break. It keeps it while it holds the result
/// (anchored and enabled), whether or not the battery is in view, and gives it back at once when
/// it stops holding it. Build 4.1 hid the Canvas as soon as the model was handed to the AR scene;
/// on a phone where the scene then drew nothing, the homeowner saw no battery at all.
///
/// A confirmation covers one model. A model rebuilt for a moved wall is a new entity nobody has
/// seen drawn yet, so the engine calls `modelReplaced` before it goes in
/// (`ScanEngine.showResultInCamera`).
public struct ResultOverlayPolicy: Sendable, Equatable {
    /// How long the AR scene has to be seen drawing before the Canvas steps aside: long enough
    /// to ride out a frame or two of an anchor settling, short enough that both layers are not
    /// on screen together for long. A guess, not measured on a phone.
    public static let confirmation: Double = 0.5

    /// True while the AR scene draws the result and the Canvas should not.
    public private(set) var usesRealityKit = false
    /// The AR scene has been seen drawing this model for `confirmation` seconds.
    private var confirmed = false
    /// When the current unbroken run of "drawn" began; nil while the AR scene isn't drawing.
    private var drawnSince: Double?

    public init() {}

    /// Takes one look at the AR scene at `time` in seconds (any clock that only goes forward) and
    /// returns `usesRealityKit`.
    ///
    /// - `drawn`: the AR scene draws the result now, with the battery's middle in view. Only
    ///   this confirms the model.
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

    /// The AR scene's model is about to be replaced by a new one: back to the Canvas, and the new
    /// model has to be seen drawing for `confirmation` seconds before the Canvas steps aside
    /// again. Without this a rebuilt model that looked anchored and in view at the next look took
    /// over at once, and if it drew nothing the homeowner saw no battery (Codex review of #100).
    public mutating func modelReplaced() {
        confirmed = false
        drawnSince = nil
        usesRealityKit = false
    }
}
