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

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appending(path: "Scans/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func nextKeyframeIndex() -> Int {
        defer { nextIndex += 1 }
        return nextIndex
    }

    /// Writes a keyframe's JPEG unrotated, as the sensor produced it, and returns an upright
    /// thumbnail for the capture acknowledgment.
    func saveKeyframe(_ payload: JPEGPayload, index: Int, camera: CameraFrame) async -> CGImage? {
        let id = String(format: "k%05d", index)
        let url = directory.appending(path: "\(id).jpg")
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
            return nil
        }
        keyframes.append(StoredKeyframe(id: id, camera: camera))
        keyframes.sort { $0.id < $1.id }
        return thumbnail
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
        keyframes = []
    }

    /// Zips scene.json with every keyframe and still into `scan.zip` and returns its URL. The
    /// bundle stays on the phone until the next scan, so a failed upload can be retried.
    func writeBundle(sceneJSON: Data) async throws -> URL {
        let directory = directory
        let files = keyframes.map(\.fileName) + stills.values.sorted()
        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            var entries = [ZipEntry(name: "scene.json", data: sceneJSON)]
            for name in files {
                entries.append(ZipEntry(name: name, data: try Data(contentsOf: directory.appending(path: name))))
            }
            let zip = try ZipWriter.archive(entries, modified: Date())
            let url = directory.appending(path: "scan.zip")
            try zip.write(to: url, options: .atomic)
            return url
        }.value
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
