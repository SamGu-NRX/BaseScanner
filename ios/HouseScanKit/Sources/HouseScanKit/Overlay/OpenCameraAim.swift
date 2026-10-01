import CoreGraphics

/// Where the find-meter reticle sits, and so where "This is my meter" marks, when the
/// instruction card folds at the largest text sizes. The middle of the screen is then under the
/// card, so the aim moves to the middle of the open camera between the card and the button.
public enum OpenCameraAim {
    /// The aim point in the camera view's coordinates (the full screen, the window's global
    /// space), or nil for the middle of the screen. Nil when the card doesn't fold, before the
    /// chrome has measured its open camera, or when none of it is on screen. While the chrome
    /// scrolls, the point follows the part of the open camera that is on screen.
    /// - Parameters:
    ///   - folds: whether the card folds at this text size (`CameraChrome.aims` at an
    ///     accessibility size).
    ///   - window: the open camera between the card and the button, as the chrome measured it.
    ///   - camera: the camera view's size.
    public static func point(folds: Bool, window: CGRect?, camera: CGSize) -> CGPoint? {
        guard folds, let window else { return nil }
        let shown = window.intersection(CGRect(origin: .zero, size: camera))
        // Only the height matters. The chrome measures the open camera from a Spacer, which
        // can be zero points wide; requiring a width put the reticle back under the card at AX5
        // (run 36877327250).
        guard !shown.isNull, shown.height > 0 else { return nil }
        return CGPoint(x: shown.midX, y: shown.midY)
    }
}
