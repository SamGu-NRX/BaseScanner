import ARKit
import CoreVideo
import Foundation
import HouseScanKit
import simd

/// Converts ARKit objects into HouseScanKit's 3D map inputs. Call on the AR delegate queue; only
/// the returned Sendable values may leave it.
///
/// Session configuration each function needs (setting it is the engine's job):
/// - `depthFrame`: `frameSemantics.insert(.sceneDepth)` when
///   `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`; otherwise it returns nil.
/// - `meshChunk`: `sceneReconstruction = .meshWithClassification` when
///   `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`.
///   With `.mesh`, chunks have no classes. Call it from the session's anchor add and update
///   callbacks, not per frame: every chunk is redrawn into the map each time it is passed.
/// - `plane`, `planes`: `planeDetection` with `.horizontal` and/or `.vertical`.
/// - `featureFrame`: nothing extra; points are empty when ARKit has none for the frame.
enum Map3DFeed {
    /// The LiDAR depth image of a frame, or nil when the frame has no `sceneDepth`, no confidence
    /// map, or an unexpected pixel format.
    static func depthFrame(_ frame: ARFrame) -> DepthFrame? {
        guard let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap else { return nil }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8
        else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height,
              var depth = copyPixels(depthMap, as: Float.self, width: width, height: height),
              let confidence = copyPixels(confidenceMap, as: UInt8.self, width: width, height: height)
        else { return nil }
        // The packet's encoding: 0, never NaN, where there is no measurement.
        for index in depth.indices where !(depth[index].isFinite && depth[index] >= 0) { depth[index] = 0 }
        return DepthFrame(photo: photoCamera(frame), width: width, height: height, depth: depth, kind: .lidar(confidence: confidence))
    }

    /// A replay's stored LiDAR depth (`SourceFrame.depth`) as the map's depth frame. `pose` is the
    /// photo's camera; the image keeps its own intrinsics and size. Both use z-depth and the same
    /// pixel convention, so only millimeters become meters (0 stays no measurement).
    static func depthFrame(_ image: DepthImage, pose: CameraFrame) -> DepthFrame {
        let camera = CameraFrame(
            cameraToWorld: pose.cameraToWorld, intrinsics: image.intrinsics,
            imageSize: SIMD2(Float(image.width), Float(image.height)))
        return DepthFrame(
            camera: camera, width: image.width, height: image.height,
            depth: image.millimeters.map { Float($0) / 1000 }, kind: .lidar(confidence: image.confidence))
    }

    static func meshChunk(_ anchor: ARMeshAnchor) -> MeshChunk {
        let geometry = anchor.geometry

        let source = geometry.vertices
        precondition(source.format == .float3, "mesh vertices have format \(source.format.rawValue), expected float3")
        let vertexBase = source.buffer.contents().advanced(by: source.offset)
        let vertices = (0..<source.count).map { index in
            let p = vertexBase.advanced(by: index * source.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }

        let element = geometry.faces
        precondition(element.indexCountPerPrimitive == 3, "mesh faces have \(element.indexCountPerPrimitive) indices each, expected 3")
        let faceBase = UnsafeRawPointer(element.buffer.contents())
        let faces: [SIMD3<UInt32>]
        switch element.bytesPerIndex {
        case 4:
            let indices = faceBase.assumingMemoryBound(to: UInt32.self)
            faces = (0..<element.count).map { SIMD3(indices[$0 * 3], indices[$0 * 3 + 1], indices[$0 * 3 + 2]) }
        case 2:
            let indices = faceBase.assumingMemoryBound(to: UInt16.self)
            faces = (0..<element.count).map {
                SIMD3(UInt32(indices[$0 * 3]), UInt32(indices[$0 * 3 + 1]), UInt32(indices[$0 * 3 + 2]))
            }
        default:
            preconditionFailure("mesh faces have \(element.bytesPerIndex) bytes per index, expected 2 or 4")
        }

        // ARKit gives one class per face; a count mismatch is dropped rather than tripping
        // MeshChunk's precondition on live data.
        var classes: [MeshClass] = []
        if let classification = geometry.classification, classification.count == faces.count {
            let classBase = UnsafeRawPointer(classification.buffer.contents()).advanced(by: classification.offset)
            classes = (0..<classification.count).map { index in
                MeshClass(rawValue: classBase.load(fromByteOffset: index * classification.stride, as: UInt8.self)) ?? .none
            }
        }

        return MeshChunk(id: anchor.identifier, worldFromChunk: anchor.transform, vertices: vertices, faces: faces, classes: classes)
    }

    static func plane(_ anchor: ARPlaneAnchor) -> PlaneObservation {
        let alignment: PlaneObservation.Alignment = anchor.alignment == .vertical ? .vertical : .horizontal
        let boundary = anchor.geometry.boundaryVertices.map { SIMD2($0.x, $0.z) }
        if boundary.count >= 3 {
            return PlaneObservation(id: anchor.identifier, worldFromPlane: anchor.transform, alignment: alignment, boundary: boundary)
        }
        let extent = anchor.planeExtent
        return PlaneObservation(
            id: anchor.identifier, worldFromPlane: anchor.transform, alignment: alignment,
            center: SIMD2(anchor.center.x, anchor.center.z),
            width: extent.width, length: extent.height, rotationOnYAxis: extent.rotationOnYAxis
        )
    }

    static func featureFrame(_ frame: ARFrame) -> FeatureFrame {
        FeatureFrame(camera: photoCamera(frame), points: frame.rawFeaturePoints?.points ?? [])
    }

    static func planes(_ frame: ARFrame) -> [PlaneObservation] {
        frame.anchors.compactMap { $0 as? ARPlaneAnchor }.map(plane)
    }

    /// The color camera: pose, and intrinsics for the captured image at its native size.
    private static func photoCamera(_ frame: ARFrame) -> CameraFrame {
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        return CameraFrame(
            cameraToWorld: frame.camera.transform,
            intrinsics: SIMD4(k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y),
            imageSize: SIMD2(Float(resolution.width), Float(resolution.height)))
    }

    /// Copies a single-plane pixel buffer row by row into a tightly packed array; rows may be padded.
    private static func copyPixels<T: BitwiseCopyable>(_ buffer: CVPixelBuffer, as _: T.Type, width: Int, height: Int) -> [T]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard bytesPerRow >= width * MemoryLayout<T>.stride else { return nil }
        return [T](unsafeUninitializedCapacity: width * height) { output, count in
            for row in 0..<height {
                let source = UnsafeRawPointer(base).advanced(by: row * bytesPerRow)
                let destination = UnsafeMutableRawPointer(output.baseAddress!).advanced(by: row * width * MemoryLayout<T>.stride)
                destination.copyMemory(from: source, byteCount: width * MemoryLayout<T>.stride)
            }
            count = width * height
        }
    }
}
