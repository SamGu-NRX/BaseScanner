import Foundation

/// The prototype's rule values. Each is the brief's value unless its comment says why it differs.
public enum Tuning {
    // MARK: LiDAR fusion

    public static let voxelSize: Float = 0.05
    /// ARKit confidence: 0 low, 1 medium, 2 high.
    public static let minimumConfidence: UInt8 = 1
    public static let depthRange: ClosedRange<Float> = 0.3...6
    /// Jitter radius as a fraction of the cell it sits in, so the field never reads as a grid.
    public static let jitterFraction: Float = 0.3
    /// A new view of a voxel counts only when it differs from every stored view by more than this.
    public static let viewSeparationDegrees: Float = 15
    /// Face neighbours whose normals differ by more than this make a crease edge.
    public static let creaseDegrees: Float = 35
    /// A face neighbour lies along the surface when its direction is within 60 degrees of the
    /// tangent plane (|cos| to the normal under 0.5). Not in the brief; the brief names the idea.
    public static let alongSurfaceCosine: Float = 0.5
    /// A neighbour voxel counts as seen-empty when a depth ray passes it by this much.
    public static let freeSpaceMargin: Float = 0.1
    /// Scale-normalised colour gradient (0 to 1, the step height of the strongest channel) at
    /// which a voxel is an image edge. Chosen from `LiveDots --gradient-report` on the synthetic
    /// fixture: see the comment at the top of DotField.swift for the numbers.
    public static let gradientThreshold: Float = 0.2
    /// Most dots drawn in one frame. Only dots in the phone's view count.
    public static let dotCap = 6_000
    /// An edge dot stays at or below this opacity until some view saw it within
    /// `faceOnDegrees` of its normal. The team's field data: window and door edges seen more
    /// than 30 degrees off face-on carried 8 to 24 inches of error.
    public static let obliqueEdgeOpacityCap: Float = 0.6
    public static let faceOnDegrees: Float = 30
    /// The occluder is any dot this far in front of the wall. The ground under it is excluded by
    /// `groundBand`, which the brief does not mention: without it the lawn would be violet too.
    public static let occluderMinZ: Float = 0.25
    public static let groundBand: Float = 0.1

    // MARK: Drawing

    /// A dot hides while the current keyframe's depth shows something this much nearer.
    public static let occlusionMargin: Float = 0.15

    // MARK: Simulated no-LiDAR

    public static let featureTarget = 600
    public static let featureMatchRadius: Float = 0.08
    public static let featureWindow = 10
    public static let featureMinObservations = 3
    /// Seconds of capture time (the fixture's timestamps), not of playback.
    public static let featureLifetime: Double = 2
    /// Candidate features are merged to one per cell of this size before thinning, so the same
    /// wall spot tends to be picked again in the next keyframe, as a tracked ARKit feature is.
    public static let featureCell: Float = 0.04
    public static let planeCell: Float = 0.12
    public static let planeRange: Float = 4

    // MARK: Coverage ring and fog

    public static let coverageZone: ClosedRange<Float> = -3...3
    public static let coverageColumn: Float = 0.3
    public static let coverageMinViews = 2
    public static let fogCell: Float = 0.3

    // MARK: Playback and motion

    public static let keyframesPerSecond: Float = 4
    public static let birthDuration: Float = 0.35
    public static let evidenceDuration: Float = 0.25
    public static let birthStartScale: Float = 0.6
}
