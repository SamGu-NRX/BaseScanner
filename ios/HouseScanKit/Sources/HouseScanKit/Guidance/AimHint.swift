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

    /// Where `target` (world) lies from `camera`'s view. Off screen, the direction named is the
    /// larger part of the one the chevron points in.
    public static func classify(target: SIMD3<Float>, camera: CameraFrame) -> AimHint {
        let local = camera.cameraSpace(target)
        let depth = -local.z
        guard depth > 0 else { return .behind }
        let up = atan2(-local.x, depth)
        let right = atan2(local.y, depth)
        if abs(up) <= onScreenUpDown, abs(right) <= onScreenSideways { return .onScreen }
        if abs(local.x) >= abs(local.y) { return up > 0 ? .above : .below }
        return right > 0 ? .right : .left
    }
}
