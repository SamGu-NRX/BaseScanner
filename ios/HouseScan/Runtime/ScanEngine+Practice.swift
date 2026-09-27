import Foundation
import HouseScanKit

/// Practice meter (HouseScanKit `PracticeMeter`). The meter tap is the usual one: the same raycast
/// and refusals, since they guard the wall's geometry, and the tapped spot becomes the meter's
/// anchor, where the camera view draws the sample (`PracticeMeterOverlay`). Only the close-up's
/// photo changes; its pose, depth and the view coverage takes from it stay the live frame's.
extension ScanEngine {
    /// Reads the developer switch when a scan starts; the scan keeps the answer to its end.
    func startPracticeIfOn() {
        state.isPracticeScan = DeveloperSettings.shared.practiceMeterOn
        guard state.isPracticeScan else { return }
        RuntimeLog.engine.info("practice meter: a drawn sample stands in for the meter and its close-up photo")
    }

    /// The frame whose photo the close-up stores and the reader reads: `frame` itself, or on a
    /// practice scan `frame` with a photo of the sample in place of the camera's, at the camera
    /// image's size so the frame's intrinsics still fit it. Without a photo when the sample can't
    /// be drawn, so the save fails and the close-up asks for a retake rather than storing a photo
    /// of whatever the camera saw.
    func closeUpPhoto(_ frame: SourceFrame) async -> SourceFrame {
        guard state.isPracticeScan else { return frame }
        let size = frame.camera.imageSize
        let jpeg = await Task.detached(priority: .userInitiated) {
            SampleMeterArt.closeUpJPEG(width: Int(size.x), height: Int(size.y))
        }.value
        var photo = frame
        if let jpeg {
            photo.jpeg = .data(jpeg)
        } else {
            RuntimeLog.engine.error("practice meter: the sample photo could not be drawn at \(Int(size.x))x\(Int(size.y))")
            photo.jpeg = .none
        }
        return photo
    }
}
