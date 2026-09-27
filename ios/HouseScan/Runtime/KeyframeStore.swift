import CoreGraphics
import Foundation
import HouseScanKit
import simd
import OSLog

/// A kept photo (a keyframe, or a still such as the meter close-up): its JPEG on disk and what
/// the packet records about the frame it came from.
struct StoredKeyframe: Sendable {
    /// Also the JPEG's file name without extension, for example "k00001".
    let id: String
    let camera: CameraFrame
    /// The frame's time: ARFrame.timestamp live, the recording's time on a replay.
    let t: Double
    let tracking: TrackingQuality
    let exposure: PhotoExposure?
    /// Pixels of the stored JPEG, read from the file.
    let width: Int
    let height: Int
    /// `laplacian_variance_luma_640` of the stored JPEG; nil when its luma could not be read.
    let sharpness: Double?
    /// ARKit's depth for this photo, written beside it as float32 meters (`depth/<id>.f32`) with
    /// its confidence (`depth/<id>.conf.u8`). Live LiDAR frames only.
    let depth: StoredDepth?
    var fileName: String { "\(id).jpg" }
    /// The camera-to-world pose ARKit reported for the photo, in its world frame at `t`, never
    /// corrected. scene.json and the packet use it corrected for the meter anchor's later moves
    /// (`MeterAnchorTracking.correctedPose(_:capturedAt:)`).
    var rawPose: simd_float4x4 { camera.cameraToWorld }
}

struct StoredDepth: Sendable {
    let file: String
    let confidenceFile: String?
    let width: Int
    let height: Int
    /// Nil when the depth's origin is unknown (`DepthPacket.source`); live frames say ARKit's.
    let source: DepthPacket.Source?
}

/// Keyframe JPEGs and close-up stills of one scan, in Caches/Scans/<id>/. File work runs off the
/// main actor; the list of what was stored lives here on the main actor.
@MainActor
final class KeyframeStore {
    let directory: URL
    private(set) var keyframes: [StoredKeyframe] = []
    /// Purpose (scene.json `stills` key) to file name.
    private(set) var stills: [String: String] = [:]
    /// Purpose to the still's frame, for the packet's photos.
    private(set) var stillFrames: [String: StoredKeyframe] = [:]
    private var nextIndex = 1
    /// Bumped by `discardKeyframes`, so a write that started before it doesn't land in the list.
    private var epoch = 0
    /// Called for each photo kept, once its JPEG is on disk, with the still's purpose (nil for a
    /// keyframe). The capture upload seals it from here (`CaptureIntegration`).
    var onKept: (@MainActor (_ photo: StoredKeyframe, _ purpose: String?, _ jpeg: URL) -> Void)?

    /// Makes a new, empty scan folder and deletes every other one: only the current scan is kept
    /// on the phone. Covers both a start over (the previous scan's folder) and launch (folders a
    /// quit or crashed run left behind), since both make a new store. The folders to delete are
    /// listed here, before a newer store can exist, and deleted later off the main actor
    /// (`ScanFolderCleanup`), so a deletion that runs late can't take a newer scan's folder.
    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let scans = caches.appending(path: "Scans", directoryHint: .isDirectory)
        directory = scans.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.delete(ScanFolderCleanup(root: scans, keeping: directory.lastPathComponent))
    }

    func nextKeyframeIndex() -> Int {
        defer { nextIndex += 1 }
        return nextIndex
    }

    /// Writes a keyframe's JPEG unrotated, as the sensor produced it, with the pose, time and
    /// camera settings of the frame those bytes came from, its sharpness, and its ARKit depth when
    /// there is some. Returns whether it was stored, and an upright thumbnail for the capture
    /// acknowledgment.
    ///
    /// Bytes that don't decode are refused before anything is written: a photo no one can open
    /// is not a view, so it must not become a keyframe the coverage counts. The thumbnail is that
    /// decode. (Before, an undecodable photo was stored with a gray placeholder thumbnail.)
    func saveKeyframe(_ frame: SourceFrame, index: Int) async -> (stored: Bool, thumbnail: CGImage?) {
        let id = String(format: "k%05d", index)
        let directory = directory
        let startedIn = epoch
        let written = await Task.detached(priority: .utility) { () -> Result<(CGImage, StoredKeyframe), KeyframeWriteFailure> in
            guard let data = Self.data(of: frame.jpeg) else { return .failure(.noPhoto) }
            guard let thumbnail = ImageWork.uprightThumbnail(jpeg: data) else { return .failure(.undecodable) }
            do {
                try data.write(to: directory.appending(path: "\(id).jpg"), options: .atomic)
            } catch {
                return .failure(.writeFailed)
            }
            return .success((thumbnail, Self.stored(frame, id: id, jpeg: data, in: directory)))
        }.value
        let thumbnail: CGImage
        let stored: StoredKeyframe
        switch written {
        case .success(let (image, entry)):
            thumbnail = image
            stored = entry
        case .failure(let failure):
            RuntimeLog.capture.error("keyframe \(id, privacy: .public) not stored: \(failure.rawValue, privacy: .public)")
            return (false, nil)
        }
        // Taken in a world frame that was discarded while the file was being written.
        guard startedIn == epoch else {
            RuntimeLog.capture.info("keyframe \(id, privacy: .public) not stored: its world frame was discarded")
            return (false, nil)
        }
        keyframes.append(stored)
        keyframes.sort { $0.id < $1.id }
        onKept?(stored, nil, directory.appending(path: stored.fileName))
        return (true, thumbnail)
    }

    /// What the packet records about a photo written as `id`: the frame's pose, time, tracking and
    /// exposure, the JPEG's own pixel size and sharpness, and its depth files, written here.
    nonisolated private static func stored(_ frame: SourceFrame, id: String, jpeg: Data, in directory: URL) -> StoredKeyframe {
        let luma = ImageWork.luma(jpeg: jpeg)
        let sharpness = luma.map { PacketSharpness.laplacianVarianceLuma640(luma: $0.pixels, width: $0.width, height: $0.height) }
        return StoredKeyframe(
            id: id, camera: frame.camera, t: frame.timestamp, tracking: frame.tracking, exposure: frame.exposure,
            width: luma?.width ?? Int(frame.camera.imageSize.x), height: luma?.height ?? Int(frame.camera.imageSize.y),
            sharpness: sharpness, depth: frame.sensorDepth.flatMap { writeDepth($0, id: id, in: directory) }
        )
    }

    /// Writes ARKit's depth for a photo into the scan folder: float32 little-endian meters,
    /// `depth/<id>.f32`, and its confidence, `depth/<id>.conf.u8`. A failed write loses only the
    /// depth: the photo is the keyframe, and the packet then lists no depth for it.
    nonisolated private static func writeDepth(_ depth: DepthPacket, id: String, in directory: URL) -> StoredDepth? {
        let file = "depth/\(id).f32"
        let confidenceFile = depth.confidence == nil ? nil : "depth/\(id).conf.u8"
        do {
            try FileManager.default.createDirectory(at: directory.appending(path: "depth", directoryHint: .isDirectory), withIntermediateDirectories: true)
            var map = Data(capacity: depth.meters.count * 4)
            for value in depth.meters { withUnsafeBytes(of: value.bitPattern.littleEndian) { map.append(contentsOf: $0) } }
            try map.write(to: directory.appending(path: file), options: .atomic)
            if let confidence = depth.confidence, let confidenceFile {
                try Data(confidence).write(to: directory.appending(path: confidenceFile), options: .atomic)
            }
            return StoredDepth(file: file, confidenceFile: confidenceFile, width: depth.width, height: depth.height, source: depth.source)
        } catch {
            RuntimeLog.capture.error("keyframe \(id, privacy: .public) depth not stored: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A stored photo's depth, read back for the packet. Nil when the files are gone or the wrong
    /// size.
    nonisolated static func loadDepth(_ depth: StoredDepth, in directory: URL) -> DepthPacket? {
        guard let map = try? Data(contentsOf: directory.appending(path: depth.file)), map.count == depth.width * depth.height * 4 else { return nil }
        var confidence: [UInt8]?
        if let file = depth.confidenceFile {
            guard let data = try? Data(contentsOf: directory.appending(path: file)), data.count == depth.width * depth.height else { return nil }
            confidence = [UInt8](data)
        }
        return DepthPacket(meters: PacketFiles.floats(littleEndian: map), width: depth.width, height: depth.height, confidence: confidence, source: depth.source)
    }

    enum KeyframeWriteFailure: String, Error {
        case noPhoto = "no photo data"
        case undecodable = "photo does not decode"
        case writeFailed = "write failed"
    }

    /// Writes a still such as the meter close-up from `frame`. Returns false when there was
    /// nothing to write.
    func saveStill(_ frame: SourceFrame, name: String) async -> Bool {
        let directory = directory
        let id = Self.purpose(of: name)
        let startedIn = epoch
        let written = await Task.detached(priority: .utility) { () -> StoredKeyframe? in
            guard let data = Self.data(of: frame.jpeg), (try? data.write(to: directory.appending(path: name), options: .atomic)) != nil else { return nil }
            return Self.stored(frame, id: id, jpeg: data, in: directory)
        }.value
        guard let written else { return false }
        // Taken in a world frame that was discarded while the file was being written. The file is
        // left alone: a close-up in the new frame may already have written the same name, and
        // nothing reads a still that `stills` doesn't list.
        guard startedIn == epoch else {
            RuntimeLog.capture.info("still \(name, privacy: .public) not kept: its world frame was discarded")
            return false
        }
        stills[id] = name
        stillFrames[id] = written
        onKept?(written, id, directory.appending(path: name))
        return true
    }

    func thumbnail(ofStill name: String) async -> CGImage? {
        let url = directory.appending(path: name)
        return await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageWork.uprightThumbnail(jpeg: data)
        }.value
    }

    /// Forgets keyframes and stills taken in a world frame that no longer exists (after a failed
    /// relocalization), the meter close-up included: export and the packet read only what
    /// `keyframes` and `stills` list, so a close-up skipped in the new frame exports none. Keyframe
    /// files stay until the scan is discarded; still files go now, since the next close-up
    /// reuses the name (`meter_close.jpg`).
    func discardKeyframes() {
        epoch += 1
        keyframes = []
        for name in stills.values {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        stills = [:]
        stillFrames = [:]
    }

    /// Where the packet is assembled, and the zip Share scan offers.
    var packetFolder: URL { directory.appending(path: "packet", directoryHint: .isDirectory) }
    var bundleURL: URL { directory.appending(path: "scan.zip") }

    /// Zips the packet folder into `scan.zip`, manifest.json at the zip's root, and removes the
    /// folder. The zip is what "Share scan" offers; the upload sends scene.json alone. It stays on
    /// the phone until the next scan unless the homeowner shares it.
    ///
    /// Streamed to disk one file at a time: a long walk's JPEGs held in memory twice (the entries
    /// and the archive) is what an in-memory build cost.
    nonisolated static func zipPacket(_ folder: URL, to url: URL) throws {
        let files = FileManager.default
        guard let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        let root = folder.standardizedFileURL.pathComponents.count
        var names: [String] = []
        for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            names.append(file.standardizedFileURL.pathComponents.dropFirst(root).joined(separator: "/"))
        }
        // manifest.json first, so a reader streaming the zip meets it before the files it names.
        names.sort { ($0 == "manifest.json" ? 0 : 1, $0) < ($1 == "manifest.json" ? 0 : 1, $1) }
        let entries = names.map { name in (name: name, load: { () throws -> Data in try Data(contentsOf: folder.appending(path: name)) }) }
        try ZipWriter.write(entries, to: url, modified: Date())
        try? files.removeItem(at: folder)
    }

    /// Off the main actor. A write still in flight for a deleted folder fails, because its
    /// directory is gone, and is dropped like any failed write.
    nonisolated private static func delete(_ cleanup: ScanFolderCleanup) {
        Task.detached(priority: .utility) {
            for (url, error) in cleanup.run() {
                RuntimeLog.engine.error("could not delete old scan \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated private static func data(of payload: JPEGPayload) -> Data? {
        switch payload {
        case .data(let data): data
        case .file(let url): try? Data(contentsOf: url)
        case .none: nil
        }
    }

    nonisolated private static func purpose(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
