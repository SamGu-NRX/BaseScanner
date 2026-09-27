import Foundation
import simd

/// What the 3D map says about the battery's volume at a chosen stretch of wall.
public enum SpotView: Sendable, Equatable {
    /// Measured depth found something standing in the volume. The stretch counts as unseen and a
    /// better view is needed; the homeowner's answer can't change that.
    case occluder
    /// Measured rays crossed the whole volume, the ground under it and the facade behind it
    /// were seen: nothing stands there.
    case clear
    /// Neither: too little measured evidence. The homeowner's answer decides, as on a phone
    /// without LiDAR.
    case unknown
}

/// How a chosen spot's check comes out, from the map's view and the homeowner's answer.
public enum SpotDecision: Sendable, Equatable {
    case clear
    case obstacle
    /// Ask for another view of the stretch.
    case needsAnotherView
    /// Ask the homeowner whether the spot is clear.
    case needsConfirmation

    /// The homeowner's answer, when there is one, is `true` for clear and `false` for an
    /// obstacle. An occluder the map measured always needs another view, whatever the answer:
    /// the answer can't clear what depth found standing there. The map's clear needs no answer;
    /// an obstacle the homeowner reports still stands.
    public static func decide(_ view: SpotView, homeownerSaysClear: Bool?) -> SpotDecision {
        switch view {
        case .occluder: .needsAnotherView
        case .clear: homeownerSaysClear == false ? .obstacle : .clear
        case .unknown:
            switch homeownerSaysClear {
            case true?: .clear
            case false?: .obstacle
            case nil: .needsConfirmation
            }
        }
    }
}

extension Map3D {
    /// What the map shows in the battery's volume over `span` (meters of s along `wall`): from
    /// the facade's face out to `overheadDepth` (the battery's depth), from `groundClearance`
    /// above each column's ground up to headroom. Only measured evidence decides, LiDAR or
    /// feature rays; estimated depth, detected planes and the mesh never do.
    ///
    /// - `occluder`: a measured surface hit in at least `minOccluderHits` frames stands in the
    ///   volume. Two frames, so one stray depth pixel can't block a spot; a voxel hit once is
    ///   neither clear nor an occluder.
    /// - `clear`: the facade is seen to headroom over the span (`isWallSeen`), the ground is
    ///   seen in every column (`groundHeight`), and every voxel of the volume is free by a
    ///   measured ray.
    /// - `unknown`: anything else.
    ///
    /// The span is read along `wall` through the map's current frame, so the answer follows a
    /// refined meter anchor or a changed wall the same way coverage does.
    public func spotView(span: ClosedRange<Float>, along wall: WallFrame) -> SpotView {
        var clear = true
        let cells = cellIndices.filter { cellRange($0).upperBound > span.lowerBound && cellRange($0).lowerBound < span.upperBound }
        guard !cells.isEmpty else { return .unknown }
        for index in cells {
            let range = cellRange(index)
            let facade = facadeOffset(cell: index, along: wall)
            if facade == nil || !isWallSeen(cell: index, along: wall) { clear = false }
            let near = nearStart(facade ?? 0)
            let ss = samples(in: max(range.lowerBound, span.lowerBound)...min(range.upperBound, span.upperBound))
            for s in ss {
                for out in stride(from: near, through: config.overheadDepth, by: config.voxelSize / 2) {
                    let ground = groundHeight(wall, s: s, out: out)
                    if ground == nil { clear = false }
                    for height in stride(from: (ground ?? 0) + config.groundClearance, through: config.headroom, by: config.voxelSize / 2) {
                        guard let g = coordinate(wall, s: s, height: height, out: out) else {
                            clear = false
                            continue
                        }
                        if let voxel = grid.voxel(g), voxel.state(config) == .surface, Int(voxel.hits) >= Self.minOccluderHits,
                           !VoxelSources(rawValue: voxel.sources).isDisjoint(with: VoxelSources.measuredHit) {
                            return .occluder
                        }
                        if !grid.isMeasuredFree(g, config: config) { clear = false }
                    }
                }
            }
        }
        return clear ? .clear : .unknown
    }

    /// Frames a measured surface must be hit in to count as an occluder at a chosen spot. A
    /// guess, not tuned: one frame is a stray pixel as often as an object.
    static let minOccluderHits = 2
}
