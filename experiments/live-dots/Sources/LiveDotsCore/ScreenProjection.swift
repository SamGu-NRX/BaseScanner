import simd

/// Where world points land on a portrait phone screen that shows the keyframe's landscape sensor
/// image turned 90 degrees clockwise and scaled to fill (cropping the sides, as ARKit's display
/// transform does). The phone is held in portrait, so camera +x is world down: landscape pixel
/// (u, v) becomes portrait pixel (imageHeight - v, u).
public struct ScreenProjection: Sendable {
    /// Screen size in any unit (points or pixels), origin top-left, y down.
    public let viewSize: SIMD2<Float>
    /// Landscape image size, (640, 480) for the fixture.
    public let imageSize: SIMD2<Float>
    public let intrinsics: SIMD4<Float>
    public let worldToCamera: simd_float4x4
    public let cameraPosition: SIMD3<Float>
    /// Screen units per portrait image pixel.
    public let scale: Float
    /// Screen position of the portrait image's top-left corner.
    public let offset: SIMD2<Float>

    public init(keyframe: Keyframe, viewSize: SIMD2<Float>) {
        self.viewSize = viewSize
        imageSize = SIMD2(Float(keyframe.width), Float(keyframe.height))
        intrinsics = keyframe.intrinsics
        worldToCamera = keyframe.cameraToWorld.inverse
        cameraPosition = keyframe.cameraPosition
        let portrait = SIMD2(imageSize.y, imageSize.x)
        scale = max(viewSize.x / portrait.x, viewSize.y / portrait.y)
        offset = (viewSize - portrait * scale) / 2
    }

    public func portraitPixel(u: Float, v: Float) -> SIMD2<Float> {
        SIMD2(imageSize.y - v, u)
    }

    /// Screen position of a world point, or nil behind the camera.
    public func screenPoint(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let camera = CameraMath.transform(worldToCamera, world)
        guard let pixel = CameraMath.project(camera, intrinsics: intrinsics) else { return nil }
        return offset + portraitPixel(u: pixel.u, v: pixel.v) * scale
    }

    /// World to Metal clip space (x right, y up, depth fixed at 0.5), the same mapping as
    /// `screenPoint`. Points behind the camera get w < 0 and the GPU clips them.
    public var clipMatrix: simd_float4x4 {
        let (fx, fy, cx, cy) = (intrinsics.x, intrinsics.y, intrinsics.z, intrinsics.w)
        // Rows act on camera-space (x, y, z, 1); w is the depth along -z.
        let w = SIMD4<Float>(0, 0, -1, 0)
        let portraitX = SIMD4<Float>(0, fy, cy - imageSize.y, 0)
        let portraitY = SIMD4<Float>(fx, 0, -cx, 0)
        let screenX = offset.x * w + scale * portraitX
        let screenY = offset.y * w + scale * portraitY
        let clipX = (2 / viewSize.x) * screenX - w
        let clipY = w - (2 / viewSize.y) * screenY
        let cameraToClip = simd_float4x4(rows: [clipX, clipY, 0.5 * w, w])
        return cameraToClip * worldToCamera
    }
}
