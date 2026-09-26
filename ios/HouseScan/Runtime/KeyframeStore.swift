import CoreGraphics
import Foundation
import HouseScanKit
import OSLog

/// A kept keyframe: its JPEG on disk and the camera it was taken with.
struct StoredKeyframe: Sendable {
    /// Also the JPEG's file name without extension, for example "k00001".
    let id: String
    let camera: CameraFrame
    /// The depth/index.json entry of the depth files written beside the photo, on LiDAR phones.
    let depth: DepthBundle.Frame?
    var fileName: String { "\(id).jpg" }
}

/// Keyframe JPEGs and close-up stills of one scan, in Caches/Scans/<id>/. File work runs off the
/// main actor; the list of what was stored lives here on the main actor.
@MainActor
final class KeyframeStore {
    let directory: URL
    private(set) var keyframes: [StoredKeyframe] = []
    /// Purpose (scene.json `stills` key) to file name.
    private(set) var stills: [String: String] = [:]
    private var nextIndex = 1
    /// Bumped by `discardKeyframes`, so a write that started before it doesn't land in the list.
    private var epoch = 0

    /// Makes a new, empty scan folder and deletes every other one: only the current scan is kept
    /// on the phone. Covers both a start over (the previous scan's folder) and launch (folders a
    /// quit or crashed run left behind), since both make a new store.
    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let scans = caches.appending(path: "Scans", directoryHint: .isDirectory)
        directory = scans.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.deleteScans(in: scans, except: directory.lastPathComponent)
    }

    func nextKeyframeIndex() -> Int {
        defer { nextIndex += 1 }
        return nextIndex
    }

    /// Writes a keyframe's JPEG unrotated, as the sensor produced it, with `camera`, the pose of
    /// the frame those bytes came from, and its LiDAR depth when there is some. Returns whether it
    /// was stored, and an upright thumbnail for the capture acknowledgment.
    ///
    /// Bytes that don't decode are refused before anything is written: a photo no one can open
    /// is not a view, so it must not become a keyframe the coverage counts. The thumbnail is that
    /// decode. (Before, an undecodable photo was stored with a gray placeholder thumbnail.)
    func saveKeyframe(_ payload: JPEGPayload, index: Int, camera: CameraFrame, depth: DepthImage?) async -> (stored: Bool, thumbnail: CGImage?) {
        let id = String(format: "k%05d", index)
        let directory = directory
        let startedIn = epoch
        let written = await Task.detached(priority: .utility) { () -> Result<(CGImage, DepthBundle.Frame?), KeyframeWriteFailure> in
            guard let data = Self.data(of: payload) else { return .failure(.noPhoto) }
            guard let thumbnail = ImageWork.uprightThumbnail(jpeg: data) else { return .failure(.undecodable) }
            do {
                try data.write(to: directory.appending(path: "\(id).jpg"), options: .atomic)
            } catch {
                return .failure(.writeFailed)
            }
            return .success((thumbnail, depth.flatMap { Self.writeDepth($0, id: id, in: directory) }))
        }.value
        let thumbnail: CGImage
        let depthEntry: DepthBundle.Frame?
        switch written {
        case .success(let (image, entry)):
            thumbnail = image
            depthEntry = entry
        case .failure(let failure):
            RuntimeLog.capture.error("keyframe \(id, privacy: .public) not stored: \(failure.rawValue, privacy: .public)")
            return (false, nil)
        }
        // Taken in a world frame that was discarded while the file was being written.
        guard startedIn == epoch else {
            RuntimeLog.capture.info("keyframe \(id, privacy: .public) not stored: its world frame was discarded")
            return (false, nil)
        }
        keyframes.append(StoredKeyframe(id: id, camera: camera, depth: depthEntry))
        keyframes.sort { $0.id < $1.id }
        return (true, thumbnail)
    }

    /// Writes the keyframe's depth files (`DepthBundle.files`: `depth/<id>.u16` and, with
    /// confidence, `depth/<id>.conf.u8`) into the scan folder at the paths they take in the
    /// bundle, and returns their depth/index.json entry. A failed write loses only the depth: the
    /// photo is the keyframe, and the bundle then lists no depth for it.
    nonisolated private static func writeDepth(_ depth: DepthImage, id: String, in directory: URL) -> DepthBundle.Frame? {
        do {
            let files = try DepthBundle.files(keyframe: id, image: depth)
            try FileManager.default.createDirectory(at: directory.appending(path: "depth", directoryHint: .isDirectory), withIntermediateDirectories: true)
            for entry in files.entries { try entry.data.write(to: directory.appending(path: entry.name), options: .atomic) }
            return files.frame
        } catch {
            RuntimeLog.capture.error("keyframe \(id, privacy: .public) depth not stored: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    enum KeyframeWriteFailure: String, Error {
        case noPhoto = "no photo data"
        case undecodable = "photo does not decode"
        case writeFailed = "write failed"
    }

    /// Writes a still such as the meter close-up. Returns false when there was nothing to write.
    func saveStill(_ payload: JPEGPayload, name: String) async -> Bool {
        let url = directory.appending(path: name)
        let written = await Task.detached(priority: .utility) { () -> Bool in
            guard let data = Self.data(of: payload) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }.value
        if written { stills[Self.purpose(of: name)] = name }
        return written
    }

    func thumbnail(ofStill name: String) async -> CGImage? {
        let url = directory.appending(path: name)
        return await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageWork.uprightThumbnail(jpeg: data)
        }.value
    }

    /// Forgets keyframes taken in a world frame that no longer exists (after a failed
    /// relocalization). Their files stay until the scan is discarded.
    func discardKeyframes() {
        epoch += 1
        keyframes = []
    }

    /// Zips scene.json with every keyframe and still into `scan.zip` and returns its URL. The
    /// bundle is what "Share scan" offers, and a replay can be made from it; the upload sends
    /// scene.json alone. It stays on the phone until the next scan unless the homeowner shares it.
    ///
    /// On a LiDAR phone the bundle also holds each keyframe's depth (`depth/<id>.u16`,
    /// `depth/<id>.conf.u8`), `depth/index.json` listing them, and `mesh.ply`, `mesh` (world
    /// meters) in scene.json's frame, which puts `groundY` at y = 0 (`MeshPLY.data`). Without
    /// LiDAR none of these are written.
    func writeBundle(sceneJSON: Data, mesh: (mesh: TriangleMesh, groundY: Float)?) async throws -> URL {
        let directory = directory
        let depth = keyframes.compactMap(\.depth)
        let files = keyframes.map(\.fileName) + stills.values.sorted() + depth.flatMap { [$0.file] + [$0.confidenceFile].compactMap { $0 } }
        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            // Streamed to disk one photo at a time: a long walk's JPEGs held in memory twice (the
            // entries and the archive) is what the old in-memory build cost.
            var entries: [(name: String, load: () throws -> Data)] = [("scene.json", { sceneJSON })]
            for name in files {
                entries.append((name, { try Data(contentsOf: directory.appending(path: name)) }))
            }
            if !depth.isEmpty {
                let index = try DepthBundle.indexEntry(depth)
                entries.append((index.name, { index.data }))
            }
            if let mesh {
                entries.append((MeshPLY.name, { MeshPLY.data(mesh.mesh, groundY: mesh.groundY) }))
            }
            let url = directory.appending(path: "scan.zip")
            try ZipWriter.write(entries, to: url, modified: Date())
            return url
        }.value
    }

    /// Off the main actor. A write still in flight for a deleted folder fails, because its
    /// directory is gone, and is dropped like any failed write.
    nonisolated private static func deleteScans(in scans: URL, except kept: String) {
        Task.detached(priority: .utility) {
            let files = FileManager.default
            guard let names = try? files.contentsOfDirectory(atPath: scans.path) else { return }
            for name in names where name != kept {
                do {
                    try files.removeItem(at: scans.appending(path: name))
                } catch {
                    RuntimeLog.engine.error("could not delete old scan \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
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
