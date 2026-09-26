import CoreGraphics
import Foundation
import HouseScanKit
import ImageIO
import simd

/// One camera frame from the live session or a replay, in the form the engine consumes.
struct SourceFrame: Sendable {
    /// Replay keyframe id, or "live-<n>".
    var id: String
    /// Seconds on the frame clock (ARFrame.timestamp, or the replay's timestamps).
    var timestamp: Double
    var camera: CameraFrame
    var tracking: TrackingQuality
    /// Measured on some frames only; auto-capture reuses the last measurement in between.
    var quality: FrameQuality?
    /// Where the full-resolution JPEG comes from if the frame is kept.
    var jpeg: JPEGPayload
    /// The replay image, drawn as the feed. Nil for live frames.
    var still: CGImage?
    /// World transform of the meter's ARAnchor in this frame, when one exists.
    var meterAnchor: simd_float4x4?
    /// Detected horizontal planes as (center x, y, center z, radius), world meters. Empty when
    /// ARKit has found none or the frame doesn't carry them.
    var groundPlanes: [SIMD4<Float>] = []
    /// Shown for review or tapping only; never offered to auto-capture.
    var isReview = false
    /// Carries only pose and tracking, so overlays follow the camera between sampled frames.
    var isPoseOnly = false

    var projection: CameraProjection {
        CameraProjection(cameraToWorld: camera.cameraToWorld, intrinsics: camera.intrinsics, imageSize: camera.imageSize)
    }

    var captureTracking: TrackingStatus {
        switch tracking {
        case .normal: .normal
        case .limited: .limited
        case .notAvailable: .notAvailable
        }
    }
}

enum JPEGPayload: Sendable {
    /// A JPEG already on disk (replay keyframes).
    case file(URL)
    /// A JPEG encoded on the AR delegate queue.
    case data(Data)
    /// Not encoded; the frame can't be kept.
    case none

    var isAvailable: Bool {
        if case .none = self { return false }
        return true
    }
}

/// Image helpers that run off the main actor.
enum ImageWork {
    /// Decodes a JPEG and measures its quality from a quarter-size grayscale copy.
    static func decode(_ url: URL) -> (CGImage, FrameQuality)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, quality(of: image))
    }

    static func quality(of image: CGImage) -> FrameQuality {
        let width = max(8, image.width / 4)
        let height = max(8, image.height / 4)
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return FrameQuality(LumaImage(width: width, height: height, pixels: pixels))
    }

    /// A small upright thumbnail: the landscape sensor image rotated 90° clockwise, as the
    /// screen shows it.
    static func uprightThumbnail(jpeg: Data, maxPixels: Int = 240) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return rotatedClockwise(thumb)
    }

    static func rotatedClockwise(_ image: CGImage) -> CGImage? {
        let width = image.height
        let height = image.width
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Core Graphics has y up: rotating the content by -90° about the origin and shifting it up
        // by the new height turns the image clockwise as seen on screen.
        context.translateBy(x: 0, y: CGFloat(height))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
