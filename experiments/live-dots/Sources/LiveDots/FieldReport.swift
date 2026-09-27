import Foundation
import LiveDotsCore

/// Per-keyframe counts for both modes: field size, edges (and how many are still under the
/// oblique cap), dots drawn in view, coverage, unseen fog cells, and simulated feature
/// candidates before thinning.
enum FieldReport {
    static func run(fixture: String?) throws {
        let data = try ReplayData.loadNow(folder: FixtureLocator.folder(fixture))
        var field = VoxelField()
        for i in data.lidar.states.indices {
            let l = data.lidar.states[i], n = data.noLidar.states[i]
            let features = n.sprites.count { $0.kind == .feature && $0.deathTime == .infinity }
            let planes = n.sprites.count { $0.kind == .plane }
            let planeRows = Set(n.sprites.filter { $0.kind == .plane }.map { Int(($0.position.y / Tuning.planeCell).rounded(.down)) }).sorted()
            let planeColumns = Set(n.sprites.filter { $0.kind == .plane }.map { Int(($0.position.x / Tuning.planeCell).rounded(.down)) }).sorted()
            let keyframe = data.replay.keyframes[i]
            let frame = FrameInput(index: i, keyframe: keyframe, depth: try data.replay.depth(for: keyframe), gradient: GradientPyramid(image: try data.replay.image(for: keyframe)))
            let candidates = FeatureField.candidates(frame, threshold: Tuning.gradientThreshold).count
            field.integrate(frame)
            let oblique = field.dots().count { $0.kind == .edge && !$0.faceOn }
            print("k\(i + 1) x=\(String(format: "%.1f", data.replay.keyframes[i].cameraPosition.x)) lidar field \(l.fieldCount) edges \(l.edgeCount) (\(oblique) not yet face-on) drawn \(l.sprites.count) cov \(Int(l.coverage * 100))% unseen \(l.unseenCells.count) | nolidar field \(n.fieldCount) candidates \(candidates) features drawn \(features) planes drawn \(planes) over rows \(planeRows.first ?? 0)...\(planeRows.last ?? 0) columns \(planeColumns.first ?? 0)...\(planeColumns.last ?? 0) cov \(Int(n.coverage * 100))%")
        }
    }
}
