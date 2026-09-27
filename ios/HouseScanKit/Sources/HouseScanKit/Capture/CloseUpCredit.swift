import Foundation

/// The view a close-up photo was taken from: the frame's camera and its LiDAR depth.
public struct CloseUpView: Sendable {
    public var camera: CameraFrame
    public var depth: DepthImage?

    public init(camera: CameraFrame, depth: DepthImage?) {
        self.camera = camera
        self.depth = depth
    }
}

/// Which close-up view coverage may take when the close-up step ends, confirmed or skipped.
///
/// Only the view of the photo on disk, and only once that photo passed the reader's image checks
/// (it decoded and is in focus). A new shot replaces the photo on disk as soon as it starts
/// saving, so the previous view stops counting then, before its replacement has been checked:
/// ending the step in between credits nothing rather than a view whose photo is gone.
public struct CloseUpCredit: Sendable {
    private var checked: CloseUpView?

    public init() {}

    /// A shot fired and its photo is being saved over the last one.
    public mutating func shotStarted() {
        checked = nil
    }

    /// The reader checked the photo the last shot saved. `view` is nil when the shot's tracking
    /// wasn't normal, which never counts either.
    public mutating func photoChecked(_ view: CloseUpView?, passed: Bool) {
        checked = passed ? view : nil
    }

    /// The view to put into coverage as the step ends; nil when none may be. Each view is handed
    /// out once.
    public mutating func take() -> CloseUpView? {
        defer { checked = nil }
        return checked
    }
}
