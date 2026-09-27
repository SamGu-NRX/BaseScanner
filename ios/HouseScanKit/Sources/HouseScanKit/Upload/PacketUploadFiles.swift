import Foundation

public struct PacketUploadSummary: Sendable, Equatable {
    public var photos: Int
    public var bytes: Int

    public init(photos: Int, bytes: Int) {
        self.photos = photos
        self.bytes = bytes
    }
}

/// A finished packet folder as an intake receives it: every file manifest.json lists, plus
/// manifest.json itself, each checked on disk against the manifest's size and SHA-256.
public struct PacketUploadPacket: Sendable, Equatable {
    /// manifest.json first, then the listed files in the manifest's order.
    public let files: [PacketUploadFile]
    public let packetVersion: String
    /// SHA-256 of the packet's scene.json, byte for byte the scene sent to /v1/placements.
    public let sceneSHA256: String
    /// What the consent screen counts.
    public let photoCount: Int
    /// Depth maps or a mesh: the "3D data" the consent screen names.
    public let has3DData: Bool

    public var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case noScene
        case unsafePath(String)
        case duplicatePath(String)
        case missing(String)
        case mismatch(path: String, expected: String, found: String)

        public var description: String {
            switch self {
            case .noScene: "manifest.json names no scene.json, so the packet can't be joined to its placement request"
            case .unsafePath(let path): "manifest.json names \(path), which is outside the packet folder"
            case .duplicatePath(let path): "manifest.json names \(path) twice with different contents"
            case .missing(let path): "\(path) is listed in manifest.json but not in the packet folder"
            case .mismatch(let path, let expected, let found): "\(path) on disk is \(found); manifest.json says \(expected)"
            }
        }
    }

    /// Reads `folder/manifest.json` and hashes every file it lists. Reads the whole packet (up to
    /// about 80 MB), so call it off the main thread. A file whose size or hash differs from the
    /// manifest throws: the server would find it missing or wrong again and again.
    public static func read(folder: URL) throws -> PacketUploadPacket {
        let manifestData = try Data(contentsOf: folder.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(PacketManifest.self, from: manifestData)
        guard let scene = manifest.scene else { throw ReadError.noScene }

        var files = [PacketUploadFile(
            path: "manifest.json", bytes: manifestData.count, sha256: PacketFiles.sha256(manifestData), contentType: contentType("manifest.json"))]
        var seen: [String: PacketManifest.File] = [:]
        for listed in listedFiles(manifest) {
            guard isInside(listed.path) else { throw ReadError.unsafePath(listed.path) }
            if let earlier = seen[listed.path] {
                guard earlier == listed else { throw ReadError.duplicatePath(listed.path) }
                continue
            }
            seen[listed.path] = listed
            let url = folder.appending(path: listed.path)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ReadError.missing(listed.path) }
            let sha = PacketFiles.sha256(data)
            guard data.count == listed.bytes, sha == listed.sha256 else {
                throw ReadError.mismatch(path: listed.path, expected: "\(listed.bytes) bytes, \(listed.sha256)", found: "\(data.count) bytes, \(sha)")
            }
            files.append(PacketUploadFile(path: listed.path, bytes: listed.bytes, sha256: listed.sha256, contentType: contentType(listed.path)))
        }
        let hasDepth = manifest.photos.contains { $0.depth != nil } || !(manifest.depthFrames ?? []).isEmpty
        return PacketUploadPacket(
            files: files, packetVersion: manifest.packetVersion, sceneSHA256: scene.sha256, photoCount: manifest.photos.count,
            has3DData: hasDepth || manifest.lidar?.mesh != nil)
    }

    /// What the consent screen shows before anything is hashed: the photo count and the packet's
    /// size, from manifest.json alone.
    public static func summary(folder: URL) throws -> PacketUploadSummary {
        let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(PacketManifest.self, from: data)
        let listed = Dictionary(listedFiles(manifest).map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        return PacketUploadSummary(photos: manifest.photos.count, bytes: data.count + listed.values.reduce(0, +))
    }

    /// Every file the manifest names, in the manifest's order: photos with their depth, depth
    /// frames, streams, the mesh, then scene.json.
    public static func listedFiles(_ m: PacketManifest) -> [PacketManifest.File] {
        var out: [PacketManifest.File] = []
        for photo in m.photos {
            out.append(photo.image)
            out += [photo.depth?.map, photo.depth?.confidence, photo.depth?.sigma].compactMap { $0 }
        }
        for frame in m.depthFrames ?? [] {
            out += [frame.map, frame.confidence, frame.sigma].compactMap { $0 }
        }
        let streams = PacketStream.allCases.compactMap { m.streams?[$0] }
            + [m.streams?.location, m.streams?.heading].compactMap { $0 }
        out += streams.map { PacketManifest.File(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) }
        if let mesh = m.lidar?.mesh { out.append(mesh) }
        if let scene = m.scene { out.append(PacketManifest.File(path: scene.path, bytes: scene.bytes, sha256: scene.sha256)) }
        return out
    }

    /// The packet's file kinds. PLY and the raw depth grids have no registered type of their own.
    public static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "json": "application/json"
        case "jpg", "jpeg": "image/jpeg"
        case "csv": "text/csv"
        default: "application/octet-stream"
        }
    }

    /// Relative, "/"-separated, with no empty, "." or ".." component.
    static func isInside(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
