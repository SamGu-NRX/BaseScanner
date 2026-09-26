import Foundation

/// Settings of the 3D map. Each value is a starting hypothesis unless its comment cites a
/// source; none has been tuned on real captures yet.
public struct Map3DConfig: Sendable, Equatable {
    // MARK: Storage

    /// Voxel edge, meters. 10 cm is finer than a 6 in coverage cell and than the server's smallest
    /// position error (0.3 ft, 9 cm, rules.yaml errors.meter_ft), and keeps the worst case of the
    /// default bounds near 30 MB (`MapBounds.around`, 16 bytes a voxel).
    public var voxelSize: Float = 0.1

    // MARK: Region of interest

    /// How far along the wall chain from the meter the map must see, meters: 20 ft of cable
    /// reach (Base help page, rules.yaml route.max_ft) plus a battery's width (2.58 ft, the
    /// server's W) and the 3 ft gas, AC and opening clearances beyond its far edge. The pool's
    /// 10 ft is a placeholder in rules.yaml and is not included.
    public var alongExtent: Float = (20 + 2.58 + 3) * 0.3048
    /// How far out from the wall, meters: 15 ft, the ground reach `CoverageConfig.groundDepthReach`
    /// asks for (a pool 10 ft from a battery 1.83 ft deep, with error to spare).
    public var outDepth: Float = 4.572
    /// Headroom, meters: 6.5 ft, NEC 110.26(A)(3) and rules.yaml headroom.min_ft. The wall band
    /// runs from the ground to here, as `CoverageConfig.wallBandHeight` does.
    public var headroom: Float = 1.9812
    /// Top of the map above the meter's ground, meters. Above headroom by enough that an
    /// overhead reach can show more than headroom clear.
    public var top: Float = 2.5
    /// How far below the meter's ground the map reaches, meters, for ground that falls away.
    public var groundBelow: Float = 0.5
    /// Coverage cell width along the wall, meters: `CoverageConfig.cellWidth` (6 in), so spans
    /// from this map and from the 2D coverage map meet on the same edges.
    public var cellWidth: Float = 0.1524
    /// Spacing of ground rows out from the wall, meters: `CoverageConfig.groundDepthSpacing`.
    public var groundRowSpacing: Float = 0.1524

    // MARK: Integration

    /// Every `pixelStride`-th pixel of a depth image along each axis is cast as a ray. 2 keeps a
    /// ray every 4.4 cm at 5 m on ARKit's 256 x 192 depth (about 0.25 degrees a pixel), under half
    /// a voxel, at a quarter of the work.
    public var pixelStride = 2
    /// LiDAR depths below this ARKit confidence (0 low, 1 medium, 2 high) are ignored. ARKit
    /// marks edges, dark and shiny surfaces low.
    public var minConfidence: UInt8 = 1
    /// Depths outside this range are ignored, meters. ARKit's LiDAR is rated to 5 m.
    public var minDepth: Float = 0.2
    public var maxDepth: Float = 5
    /// An estimated depth marks a surface only when two standard deviations are within this,
    /// meters (one and a half voxels); free space is carved to two deviations short of it either way.
    public var maxSurfaceSigma: Float = 0.15
    /// An estimated depth's normal is taken between samples about this far apart, meters, and
    /// a view counts as further from square by the tilt two deviations of depth error across
    /// that span could give it. At a voxel's 0.1 m, 7 cm of independent noise tilts a normal by
    /// up to 45 degrees and lets views 68 degrees from the ground count as within 65
    /// (Map3DEstimatedTests); across 0.3 m the same noise costs 33 degrees, and straight-on views
    /// still count. Wider spans blur more edges into a normal. A guess, not measured.
    public var estimatedNormalBaseline: Float = 0.3
    /// An estimated ray counts against the voxels from two deviations past its depth for this
    /// far, meters. A stray hit then escapes it only by landing more than two deviations plus
    /// this beyond the surface the ray met: over 8 deviations at the 7.5 cm the rule lets hit.
    /// A guess, not measured.
    public var estimatedShadowLength: Float = 0.5
    /// A surface only estimated depth measured counts as seen where at least this share of the
    /// estimated rays that hit it or counted against it hit it. With independent 7.5 cm error, a
    /// visible voxel is hit by about half the rays aimed at it and counted against by about 2%;
    /// one behind an occluder 0.2 m in front, the reverse. A guess between the two, not measured.
    public var minEstimatedHitShare: Float = 0.25
    /// Free space stops this far short of a surface whose normal is unknown, meters (a feature
    /// point off every plane, a depth pixel at an edge): rays within 11 degrees of grazing a
    /// surface could still erase it.
    public var unknownNormalMargin: Float = 0.5
    /// A feature point this close to a detected plane, meters, takes the plane's normal. ARKit's
    /// feature points scatter a few centimeters about the surface they lie on.
    public var planeSnap: Float = 0.05
    /// Pixel grid rendered from detected planes on each feature frame, along each axis.
    public var planeRenderColumns = 64
    public var planeRenderRows = 48

    /// Log-odds of occupancy, in hundredths. A hit adds 0.85 (p = 0.7) and a pass through
    /// subtracts 0.4 (p = 0.4), OctoMap's defaults; the clamp lets a voxel change its mind within
    /// a few frames. At most one hit or one pass counts per voxel per frame, a hit winning.
    public var hitLogOdds: Int16 = 85
    public var missLogOdds: Int16 = -40
    public var minLogOdds: Int16 = -200
    public var maxLogOdds: Int16 = 350
    /// A voxel is surface at or above this and seen free at or below `freeLogOdds`; in between,
    /// or never touched, it is unknown.
    public var surfaceLogOdds: Int16 = 50
    public var freeLogOdds: Int16 = -40

    // MARK: Coverage

    /// A surface counts as seen only from this close, meters: LiDAR's rated range.
    public var maxViewDistance: Float = 5
    /// A surface counts as seen only from a view within this angle of its normal, as
    /// `CoverageConfig.maxAngleFromNormal`.
    public var maxViewAngle: Float = 65 * .pi / 180
    /// How far behind and in front of the wall chain's line a surface still counts as the wall
    /// face, meters: a voxel either way, plus half a voxel behind for a line placed a little in
    /// front of the real face. Anything standing farther out hides the face, including the
    /// meter itself and boxes on the wall, so the few cells behind the meter stay unseen. A
    /// wider window would let a shrub against the wall stand in for the wall behind it, and the
    /// wall band settles the checks for boxes, vents and openings there.
    public var faceBehind: Float = 0.15
    public var faceFront: Float = 0.1
    /// Relief: attached structure standing up to this far proud of the wall line, meters, such
    /// as a pilaster, column or chimney breast, counts as the facade for the wall band, because
    /// nothing can be mounted on the wall behind it. ETH3D electro's pilasters stand 0.36 m
    /// proud (experiments/evals/results/map3d.md on t3/evals). It counts only up to where it
    /// runs without the face showing above it, where no free space was seen between it and the
    /// wall, and where the mesh, when it classifies, does not call it something else; a box or
    /// shrub against the wall still hides the wall.
    public var reliefDepth: Float = 0.5
    /// Relief is at most this wide along the wall, meters; a wider face in front of the wall is
    /// a wall of its own (a bump-out).
    public var maxReliefWidth: Float = 1.0
    /// Recess: a face seen up to this far behind the wall line, meters (a door or window set
    /// back), is the facade there.
    public var recessDepth: Float = 0.5
    /// Ground is looked for from this far above to this far below the meter's ground, meters,
    /// so a yard that slopes a little still has ground. Anything flat and lower than this, such
    /// as a pad or a low step, reads as ground.
    public var groundSearch: Float = 0.2
    /// Facing and overhead space are judged from this far above the ground seen under them,
    /// meters, so grass and uneven ground do not read as something in front of the wall.
    /// Anything lower is not told apart from the ground.
    public var groundClearance: Float = 0.15
    /// Depth of the space over the battery that overhead judges, meters: the battery's 1.83 ft
    /// (the server's D).
    public var overheadDepth: Float = 0.5588

    // MARK: Walls

    /// A plan cell is wall when its vertical surface voxels between `wallBottom` and `top`
    /// add up to at least this height, meters. Taller than a typical shrub, shorter than a wall
    /// with a window in it.
    public var minWallHeight: Float = 0.8
    /// Wall evidence is taken from this height up, meters, clear of the ground and low clutter.
    public var wallBottom: Float = 0.3
    /// A plan cell belongs to a line when it is this close to it, meters, and its normal is
    /// within `wallNormalTolerance` of the line's.
    public var wallInlierDistance: Float = 0.15
    public var wallNormalTolerance: Float = 25 * .pi / 180
    /// Wall pieces shorter than this are dropped, meters.
    public var minWallLength: Float = 0.4
    /// A gap along one line longer than this splits it into two pieces, meters.
    public var maxWallGap: Float = 0.35
    /// Two pieces meet at a corner when both ends are this close to where their lines cross,
    /// meters; lines closer than `minCornerAngle` to parallel join straight across a gap of up
    /// to `maxWallBridge` instead, the gap being wall not seen rather than no wall.
    public var cornerJoinDistance: Float = 0.75
    public var minCornerAngle: Float = 20 * .pi / 180
    public var maxWallBridge: Float = 1.0

    // MARK: Fog of war and views

    /// Edge of a fog cell, meters: three voxels, coarse enough for the UI to draw every one.
    public var fogCellSize: Float = 0.3
    /// Where a suggested view stands: this far from what it should see, meters, and with the
    /// camera this high.
    public var viewDistances: [Float] = [1.5, 2.5, 3.5]
    public var eyeHeight: Float = 1.4

    public init() {}
}
