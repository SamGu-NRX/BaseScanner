import Foundation
import simd

/// Where an aim target lies from the phone's view, in the terms of a portrait screen, so the
/// card's words can agree with the ring and the edge chevron. On build 4.1 the chevron pointed up
/// while the card said "Tilt down": the homeowner had tilted past the ground and was looking at
/// their feet (#81).
///
/// Camera space is ARKit's (`CameraFrame`): the landscape sensor's +x points down a portrait
/// screen, its +y to the right, and the camera looks along -z. The overlay's chevron reads it the
/// same way (`WallProjection.screenDirection` in the app).
public enum AimHint: String, Sendable, Equatable, CaseIterable {
    /// Near enough the middle of the view that the ring is on screen.
    case onScreen
    case above
    case below
    case left
    case right
    /// Behind the camera.
    case behind

    /// Up or down from the view's axis, radians, within which the target counts as on screen:
    /// 20 degrees. About where the overlay hands the ring over to a chevron on a 6.1 in portrait
    /// screen, whose band for the ring leaves room for the card above and the buttons below. A
    /// guess from the layout, not measured on a phone.
    public static let onScreenUpDown: Float = 20 * .pi / 180
    /// The same to either side: 18 degrees. The screen shows less of the image across than
    /// along. A guess from the layout, not measured on a phone.
    public static let onScreenSideways: Float = 18 * .pi / 180

    /// With the hint from the frame before (`classify(target:camera:previous:)`), how far past an
    /// edge of the on-screen band the target must go to leave it, and how far inside the edge to
    /// come into it: 2 degrees each way. The card's title follows the hint, and a hand-held phone
    /// with the target near an edge swapped it several times a second (review of #120). A
    /// guess, not measured on a phone.
    public static let edgeMargin: Float = 2 * .pi / 180
    /// With the hint from the frame before, off screen, how many times larger the other axis must
    /// be before the direction named turns from up or down to left or right, or back. 1.2 is a
    /// guess, for the same reason as `edgeMargin`.
    public static let axisBias: Float = 1.2

    /// Where `target` (world) lies from `camera`'s view. Off screen, the direction named is the
    /// larger part of the one the chevron points in.
    ///
    /// `previous`, the hint for the same target on the frame before, makes the answer sticky near
    /// the edges (`edgeMargin`, `axisBias`); nil classifies from the named edges alone.
    public static func classify(target: SIMD3<Float>, camera: CameraFrame, previous: AimHint? = nil) -> AimHint {
        let local = camera.cameraSpace(target)
        let depth = -local.z
        guard depth > 0 else { return .behind }
        let up = atan2(-local.x, depth)
        let right = atan2(local.y, depth)
        let margin: Float = previous == nil ? 0 : (previous == .onScreen ? edgeMargin : -edgeMargin)
        if abs(up) <= onScreenUpDown + margin, abs(right) <= onScreenSideways + margin { return .onScreen }
        let vertical: Bool
        switch previous {
        case .above?, .below?:
            vertical = abs(local.x) * axisBias >= abs(local.y)
        case .left?, .right?:
            vertical = abs(local.x) > abs(local.y) * axisBias
        case .onScreen?, .behind?, nil:
            vertical = abs(local.x) >= abs(local.y)
        }
        if vertical { return up > 0 ? .above : .below }
        return right > 0 ? .right : .left
    }
}
