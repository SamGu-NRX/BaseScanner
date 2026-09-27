import Foundation
import simd

/// One recorded keyframe: its image, camera and depth file.
public struct Keyframe: Sendable, Equatable {
    public let id: String
    /// Relative to the session folder.
    public let imagePath: String
    public let width: Int
    public let height: Int
    /// fx, fy, cx, cy in pixels of the unrotated landscape JPEG.
    public let intrinsics: SIMD4<Float>
    /// Column-major camera-to-world. Camera +x right, +y up, looking down -z.
    public let cameraToWorld: simd_float4x4
    /// Seconds of device uptime at capture.
    public let timestamp: Double
    public let depth: DepthReference?

    public var cameraPosition: SIMD3<Float> {
        let c = cameraToWorld.columns.3
        return SIMD3(c.x, c.y, c.z)
    }
}

/// Where a keyframe's LiDAR depth lives: Float32 metres, little-endian, row-major, and UInt8
/// confidence in the same layout.
public struct DepthReference: Sendable, Equatable {
    public let file: String
    public let confidenceFile: String?
    public let width: Int
    public let height: Int
}

/// A "measure-lab-session" version 2 replay folder. Reads the keyframes and ignores every other
/// field, because the lab format keeps gaining fields this prototype has no use for.
public struct Replay: Sendable {
    public let folder: URL
    /// Sorted by timestamp, then id.
    public let keyframes: [Keyframe]

    public static func load(folder: URL) throws(FixtureError) -> Replay {
        let url = folder.appendingPathComponent("session.json")
        let data = try read(url)
        let file: SessionFile
        do {
            file = try JSONDecoder().decode(SessionFile.self, from: data)
        } catch {
            throw .malformed(path: url.path, detail: String(describing: error))
        }
        guard file.format == "measure-lab-session" else { throw .wrongFormat(path: url.path, found: file.format) }
        guard file.formatVersion == 2 else { throw .unsupportedVersion(path: url.path, found: file.formatVersion) }
        guard !file.keyframes.isEmpty else { throw .malformed(path: url.path, detail: "keyframes is empty") }

        var keyframes: [Keyframe] = []
        for (index, entry) in file.keyframes.enumerated() {
            guard entry.intrinsics.count == 4 else {
                throw .malformed(path: url.path, detail: "keyframes[\(index)].intrinsics has \(entry.intrinsics.count) values, expected 4")
            }
            guard entry.pose.count == 16 else {
                throw .malformed(path: url.path, detail: "keyframes[\(index)].pose has \(entry.pose.count) values, expected 16")
            }
            let p = entry.pose.map(Float.init)
            let pose = simd_float4x4(columns: (
                SIMD4(p[0], p[1], p[2], p[3]), SIMD4(p[4], p[5], p[6], p[7]),
                SIMD4(p[8], p[9], p[10], p[11]), SIMD4(p[12], p[13], p[14], p[15])
            ))
            let k = entry.intrinsics.map(Float.init)
            keyframes.append(Keyframe(
                id: entry.id, imagePath: entry.img, width: entry.w, height: entry.h,
                intrinsics: SIMD4(k[0], k[1], k[2], k[3]), cameraToWorld: pose, timestamp: entry.timestamp,
                depth: entry.depth.map { DepthReference(file: $0.file, confidenceFile: $0.confidenceFile, width: $0.w, height: $0.h) }
            ))
        }
        keyframes.sort { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id < $1.id }
        return Replay(folder: folder, keyframes: keyframes)
    }

    /// The keyframe's depth, with intrinsics scaled from the JPEG's to the depth map's size.
    public func depth(for keyframe: Keyframe) throws(FixtureError) -> DepthMap {
        guard let reference = keyframe.depth else {
            throw .noDepth(path: folder.appendingPathComponent("session.json").path, keyframe: keyframe.id)
        }
        let depthURL = folder.appendingPathComponent(reference.file)
        let confidenceURL = reference.confidenceFile.map { folder.appendingPathComponent($0) }
        return try DepthMap(
            depth: Self.read(depthURL), depthPath: depthURL.path,
            confidence: confidenceURL.map(Self.read), confidencePath: confidenceURL?.path,
            width: reference.width, height: reference.height,
            intrinsics: keyframe.intrinsics * SIMD4(
                Float(reference.width) / Float(keyframe.width), Float(reference.height) / Float(keyframe.height),
                Float(reference.width) / Float(keyframe.width), Float(reference.height) / Float(keyframe.height))
        )
    }

    public func image(for keyframe: Keyframe) throws(FixtureError) -> RGBImage {
        let url = folder.appendingPathComponent(keyframe.imagePath)
        let image = try RGBImage(jpeg: Self.read(url), path: url.path)
        guard image.width == keyframe.width, image.height == keyframe.height else {
            throw .imageSize(path: url.path, found: SIMD2(image.width, image.height), expected: SIMD2(keyframe.width, keyframe.height))
        }
        return image
    }

    private static func read(_ url: URL) throws(FixtureError) -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .unreadable(path: url.path, reason: error.localizedDescription)
        }
    }
}

private struct SessionFile: Decodable {
    let format: String
    let formatVersion: Int
    let keyframes: [Entry]

    struct Entry: Decodable {
        let id: String
        let img: String
        let w: Int
        let h: Int
        let intrinsics: [Double]
        let pose: [Double]
        let timestamp: Double
        let depth: Depth?
    }

    struct Depth: Decodable {
        let file: String
        let confidenceFile: String?
        let w: Int
        let h: Int
    }
}
