import CoreGraphics
import Foundation
import HouseScanKit
import OSLog

/// A kept keyframe: its JPEG on disk and the camera it was taken with.
struct StoredKeyframe: Sendable {
    /// Also the JPEG's file name without extension, for example "k00001".
    let id: String
    let camera: CameraFrame
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

    /// Writes a keyframe's JPEG unrotated, as the sensor produced it. Returns whether it was
    /// stored, and an upright thumbnail for the capture acknowledgment.
    func saveKeyframe(_ payload: JPEGPayload, index: Int, camera: CameraFrame) async -> (stored: Bool, thumbnail: CGImage?) {
        let id = String(format: "k%05d", index)
        let url = directory.appending(path: "\(id).jpg")
        let startedIn = epoch
        let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = Self.data(of: payload) else { return nil }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
            return ImageWork.uprightThumbnail(jpeg: data) ?? Self.placeholder
        }.value
        guard FileManager.default.fileExists(atPath: url.path) else {
            RuntimeLog.engine.error("keyframe \(id, privacy: .public) was not written")
            return (false, nil)
        }
        // Taken in a world frame that was discarded while the file was being written.
        guard startedIn == epoch else { return (false, nil) }
        keyframes.append(StoredKeyframe(id: id, camera: camera))
        keyframes.sort { $0.id < $1.id }
        return (true, thumbnail)
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
    /// bundle is for replay and debugging (the upload sends scene.json alone) and stays on the
    /// phone until the next scan.
    func writeBundle(sceneJSON: Data) async throws -> URL {
        let directory = directory
        let files = keyframes.map(\.fileName) + stills.values.sorted()
        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            // Streamed to disk one photo at a time: a long walk's JPEGs held in memory twice (the
            // entries and the archive) is what the old in-memory build cost.
            var entries: [(name: String, load: () throws -> Data)] = [("scene.json", { sceneJSON })]
            for name in files {
                entries.append((name, { try Data(contentsOf: directory.appending(path: name)) }))
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

    /// A tiny gray square so an acknowledgment still appears when a thumbnail can't be made.
    nonisolated private static var placeholder: CGImage? {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.setFillColor(gray: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }
}
