import Foundation
import LiveDotsCore

/// The fixture and both modes' precomputed timelines.
struct ReplayData: Sendable {
    let replay: Replay
    let lidar: DotTimeline
    let noLidar: DotTimeline
    /// Recognised-box states per keyframe.
    let boxes: [[BoxState]]

    var keyframeCount: Int { replay.keyframes.count }

    func timeline(_ mode: CaptureMode) -> DotTimeline {
        switch mode {
        case .lidar: lidar
        case .noLidar: noLidar
        }
    }

    /// Reads the fixture and runs both fields over every keyframe, off the main actor.
    @concurrent
    static func load(folder: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ReplayData {
        let replay = try Replay.load(folder: folder)
        let (lidar, noLidar) = try DotTimeline.build(replay: replay, progress: progress)
        return ReplayData(replay: replay, lidar: lidar, noLidar: noLidar, boxes: BoxState.timeline(for: replay.keyframes))
    }

    /// The same, blocking, for the command-line paths.
    nonisolated static func loadNow(folder: URL) throws -> ReplayData {
        let replay = try Replay.load(folder: folder)
        let (lidar, noLidar) = try DotTimeline.build(replay: replay)
        return ReplayData(replay: replay, lidar: lidar, noLidar: noLidar, boxes: BoxState.timeline(for: replay.keyframes))
    }
}

enum FixtureLocator {
    struct Missing: Error, CustomStringConvertible {
        let tried: [String]
        var description: String {
            "no fixture at \(tried.joined(separator: " or ")); run ./fetch-fixtures.sh from experiments/live-dots first"
        }
    }

    /// `--fixture` if given, else Fixtures/synthetic-wall-lidar under the working directory, else
    /// under this package's folder (so `swift run` works from anywhere).
    static func folder(_ explicit: String?) throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = explicit.map { [URL(fileURLWithPath: $0)] } ?? [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/synthetic-wall-lidar"),
            packageRoot.appendingPathComponent("Fixtures/synthetic-wall-lidar"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.appendingPathComponent("session.json").path) {
            return url
        }
        throw Missing(tried: candidates.map(\.path))
    }
}
