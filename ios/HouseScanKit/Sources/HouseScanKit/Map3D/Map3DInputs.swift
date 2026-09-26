import Foundation
import simd

// What the 3D map is built from, as plain values: the app's ARKit adapter
// (HouseScan/Runtime/Map3DFeed.swift) fills them on the AR delegate queue. World coordinates
// are ARKit's gravity-aligned world in meters.

/// A per-pixel depth image with the camera that took it, encoded as a capture packet's `depth`
/// (packet/README.md, "Depth alignment", on t3/packet).
///
/// `camera` describes the depth image itself (`camera.imageSize` is (`width`, `height`)); build
/// it from the photo's camera with `init(photo:...)`. A value is meters along the camera's -z
/// axis, not along the pixel's ray, as ARKit's `sceneDepth` reports it, and 0 means no
/// measurement. Pixel (u, v) covers the square from (u, v) to (u + 1, v + 1), row `v` from the
/// top of the unrotated landscape image; its value is at index v * width + u.
///
/// A packet's photo pose maps the camera into the meter frame: integrate it with a `Map3D`
/// whose `MapFrame` is the packet's `meter_anchor`, and `camera.cameraToWorld` =
/// `poseInWorld * pose`.
public struct DepthFrame: Sendable {
    public enum Kind: Sendable {
        /// LiDAR depth (ARKit `sceneDepth`), with ARKit's confidence per pixel when there is one:
        /// 0 low, 1 medium, 2 high (`ARConfidenceLevel` raw values). Without it every pixel is
        /// taken as high.
        case lidar(confidence: [UInt8]?)
        /// Depth estimated from the color image, for example by a monocular depth model, with one
        /// standard deviation per pixel in meters.
        case estimated(sigma: [Float])
    }

    public var camera: CameraFrame
    public var width: Int
    public var height: Int
    /// Meters, finite and not negative; 0 where there is no measurement.
    public var depth: [Float]
    public var kind: Kind

    public init(camera: CameraFrame, width: Int, height: Int, depth: [Float], kind: Kind) {
        precondition(width > 0 && height > 0 && depth.count == width * height, "depth has \(depth.count) values for \(width) x \(height)")
        precondition(depth.allSatisfy { $0.isFinite && $0 >= 0 }, "depth holds a negative or non-finite value; 0 marks no measurement")
        switch kind {
        case .lidar(let confidence):
            precondition(confidence.map { $0.count == depth.count } ?? true, "confidence has \(confidence?.count ?? 0) values for \(depth.count) depths")
        case .estimated(let sigma):
            precondition(sigma.count == depth.count, "sigma has \(sigma.count) values for \(depth.count) depths")
        }
        self.camera = camera
        self.width = width
        self.height = height
        self.depth = depth
        self.kind = kind
    }

    /// A stored LiDAR depth image (a replay's, `DepthImage`) taken with `pose`'s camera. The image
    /// keeps its own intrinsics and size; both types use z-depth and the same pixel convention,
    /// so only millimeters become meters (0 stays no measurement).
    public init(image: DepthImage, pose: CameraFrame) {
        let camera = CameraFrame(
            cameraToWorld: pose.cameraToWorld, intrinsics: image.intrinsics,
            imageSize: SIMD2(Float(image.width), Float(image.height)))
        self.init(
            camera: camera, width: image.width, height: image.height,
            depth: image.millimeters.map { Float($0) / 1000 }, kind: .lidar(confidence: image.confidence))
    }

    /// A depth image covering the same view as a photo taken by `photo`, at `width` x `height`.
    /// Depth pixel (u, v) covers photo pixels from u W / w to (u + 1) W / w across and likewise
    /// down, so the intrinsics scale by w / W and h / H.
    public init(photo: CameraFrame, width: Int, height: Int, depth: [Float], kind: Kind) {
        let scale = SIMD2(Float(width), Float(height)) / photo.imageSize
        let k = photo.intrinsics
        let camera = CameraFrame(
            cameraToWorld: photo.cameraToWorld, intrinsics: SIMD4(k.x * scale.x, k.y * scale.y, k.z * scale.x, k.w * scale.y),
            imageSize: SIMD2(Float(width), Float(height)))
        self.init(camera: camera, width: width, height: height, depth: depth, kind: kind)
    }
}

/// ARKit's per-face mesh classification. Raw values are `ARMeshClassification`'s.
public enum MeshClass: UInt8, Sendable, CaseIterable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7
}

/// One chunk of ARKit's reconstructed mesh (an `ARMeshAnchor`), replaced whole when ARKit
/// updates it. Classes are the packet's `lidar/mesh.ply` `classification` values. A packet's
/// merged mesh, already in the meter frame, is one chunk with `worldFromChunk` =
/// `MapFrame.poseInWorld`.
public struct MeshChunk: Sendable {
    public var id: UUID
    /// Chunk-local to world (the anchor's transform).
    public var worldFromChunk: simd_float4x4
    /// Chunk-local positions.
    public var vertices: [SIMD3<Float>]
    /// Three vertex indices per face.
    public var faces: [SIMD3<UInt32>]
    /// One per face, or empty when the session doesn't classify.
    public var classes: [MeshClass]

    public init(id: UUID, worldFromChunk: simd_float4x4, vertices: [SIMD3<Float>], faces: [SIMD3<UInt32>], classes: [MeshClass] = []) {
        precondition(classes.isEmpty || classes.count == faces.count, "\(classes.count) classes for \(faces.count) faces")
        self.id = id
        self.worldFromChunk = worldFromChunk
        self.vertices = vertices
        self.faces = faces
        self.classes = classes
    }
}

/// A plane ARKit detected (an `ARPlaneAnchor`), replaced whole when ARKit updates it.
public struct PlaneObservation: Sendable {
    public enum Alignment: Sendable {
        case horizontal
        case vertical
    }

    public var id: UUID
    /// Plane-local to world. The plane is local y = 0 with its normal along local +y.
    public var worldFromPlane: simd_float4x4
    public var alignment: Alignment
    /// The plane's extent as a polygon of local (x, z) points: ARKit's boundary vertices, or the
    /// four corners of its extent rectangle.
    public var boundary: [SIMD2<Float>]

    public init(id: UUID, worldFromPlane: simd_float4x4, alignment: Alignment, boundary: [SIMD2<Float>]) {
        self.id = id
        self.worldFromPlane = worldFromPlane
        self.alignment = alignment
        self.boundary = boundary
    }

    /// A rectangular extent `width` along local x and `length` along local z, centred on local
    /// `center` and turned by `rotationOnYAxis` radians (ARKit's `planeExtent`).
    public init(
        id: UUID, worldFromPlane: simd_float4x4, alignment: Alignment,
        center: SIMD2<Float>, width: Float, length: Float, rotationOnYAxis: Float = 0
    ) {
        let c = cos(rotationOnYAxis)
        let s = sin(rotationOnYAxis)
        let corners = [SIMD2<Float>(-width, -length), SIMD2(width, -length), SIMD2(width, length), SIMD2(-width, length)].map { half in
            let p = half / 2
            // Rotation about +y by the angle, written in (x, z).
            return center + SIMD2(c * p.x + s * p.y, -s * p.x + c * p.y)
        }
        self.init(id: id, worldFromPlane: worldFromPlane, alignment: alignment, boundary: corners)
    }
}

/// What a phone without LiDAR knows about one frame: its camera and the feature points ARKit
/// tracked in it (`ARFrame.rawFeaturePoints`, world meters). Planes arrive separately.
public struct FeatureFrame: Sendable {
    public var camera: CameraFrame
    public var points: [SIMD3<Float>]

    public init(camera: CameraFrame, points: [SIMD3<Float>]) {
        self.camera = camera
        self.points = points
    }
}
