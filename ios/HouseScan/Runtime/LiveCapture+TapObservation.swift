import ARKit
import CoreImage
import HouseScanKit

extension LiveCapture {
    /// The frame under a tap, for the capture packet's meter tap: that ARFrame's raw pose,
    /// intrinsics and image, and the tap as a pixel of its landscape sensor image, mapped the way
    /// the app maps every view point (`CameraProjection.imagePixel(forViewPoint:in:)`).
    ///
    /// The image is copied into memory here, so no ARFrame outlives this call (holding one starves
    /// ARKit's buffer pool); the JPEG is encoded later, off the main actor. The frame is ARKit's
    /// current one, which can be a frame or two newer than the one the raycast used; its own time
    /// stamps the tap. Nil unless tracking is normal.
    func tapObservation(at viewPoint: CGPoint, viewSize: CGSize) -> TapObservation? {
        guard let frame = arView.session.currentFrame, case .normal = frame.camera.trackingState,
              let copy = Self.copy(frame.capturedImage) else { return nil }
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let projection = CameraProjection(
            cameraToWorld: frame.camera.transform, intrinsics: SIMD4(k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y),
            imageSize: SIMD2(Float(size.width), Float(size.height)))
        let pixel = projection.imagePixel(forViewPoint: viewPoint, in: viewSize)
        let image = TapImage(buffer: copy)
        return TapObservation(
            t: frame.timestamp, cameraToWorld: projection.cameraToWorld, intrinsics: projection.intrinsics, width: Int(size.width),
            height: Int(size.height), tracking: .normal, pixel: SIMD2(Double(pixel.x), Double(pixel.y)), jpeg: { image.jpeg() })
    }

    /// A copy of the camera's pixel buffer this code owns, so encoding never holds ARKit's.
    private struct TapImage: @unchecked Sendable {
        let buffer: CVPixelBuffer

        /// JPEG of the sensor image as captured: landscape, unrotated, matching the intrinsics.
        func jpeg() -> Data? {
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
            return CIContext(options: [.cacheIntermediates: false]).jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: space, options: options)
        }
    }

    /// Plane by plane, row by row: the two buffers' rows can differ in padding.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), CVPixelBufferGetPixelFormatType(source), nil, &made
        ) == kCVReturnSuccess, let copy = made else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(copy) else { return nil }
        for plane in 0..<max(planes, 1) {
            let isPlanar = planes > 0
            guard let from = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let to = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy) else { return nil }
            let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            let fromStride = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toStride = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy)
            for row in 0..<rows {
                memcpy(to + row * toStride, from + row * fromStride, min(fromStride, toStride))
            }
        }
        return copy
    }
}
