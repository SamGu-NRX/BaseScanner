import ARKit
import Observation

/// What the AR session currently reports, for the capture screen to display.
///
/// `SessionDelegate` writes to it from ARKit callbacks; SwiftUI reads it.
@MainActor
@Observable
final class CaptureSessionModel {
    private(set) var trackingState: TrackingState = .notAvailable
    private(set) var isInterrupted = false
    private(set) var failure: SessionFailure?

    /// Whether this device can produce LiDAR scene depth. Recorded for later capture code;
    /// the session never turns depth on and the app does not require it.
    let lidarAvailable: Bool

    // Plane identifiers rather than running counts, so a repeated add or remove cannot skew a count.
    private var horizontalPlanes: Set<UUID> = []
    private var verticalPlanes: Set<UUID> = []

    var horizontalPlaneCount: Int { horizontalPlanes.count }
    var verticalPlaneCount: Int { verticalPlanes.count }

    init(lidarAvailable: Bool = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)) {
        self.lidarAvailable = lidarAvailable
    }

    func trackingChanged(to state: TrackingState) {
        trackingState = state
    }

    func planesAdded(_ planes: [DetectedPlane]) {
        for plane in planes {
            switch plane.orientation {
            case .horizontal: horizontalPlanes.insert(plane.id)
            case .vertical: verticalPlanes.insert(plane.id)
            }
        }
    }

    func planesRemoved(_ planes: [DetectedPlane]) {
        for plane in planes {
            switch plane.orientation {
            case .horizontal: horizontalPlanes.remove(plane.id)
            case .vertical: verticalPlanes.remove(plane.id)
            }
        }
    }

    func interruptionChanged(isInterrupted: Bool) {
        self.isInterrupted = isInterrupted
    }

    func sessionFailed(_ error: any Error) {
        if let arError = error as? ARError, arError.code == .cameraUnauthorized {
            failure = .cameraAccessDenied
        } else {
            failure = .other(error.localizedDescription)
        }
    }
}

enum TrackingState: Equatable, Sendable {
    case notAvailable
    case limited(LimitedReason)
    case normal

    enum LimitedReason: Equatable, Sendable {
        case initializing
        case excessiveMotion
        case insufficientFeatures
        case relocalizing
        case unknown
    }

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable:
            self = .notAvailable
        case .normal:
            self = .normal
        case .limited(let reason):
            switch reason {
            case .initializing: self = .limited(.initializing)
            case .excessiveMotion: self = .limited(.excessiveMotion)
            case .insufficientFeatures: self = .limited(.insufficientFeatures)
            case .relocalizing: self = .limited(.relocalizing)
            @unknown default: self = .limited(.unknown)
            }
        }
    }
}

/// A plane anchor reduced to the fields the model counts, so it can cross to the main actor.
struct DetectedPlane: Sendable {
    enum Orientation: Sendable {
        case horizontal
        case vertical
    }

    let id: UUID
    let orientation: Orientation

    /// Returns nil for anchors that are not planes and for alignments added after iOS 26.
    init?(_ anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor else { return nil }
        switch plane.alignment {
        case .horizontal: orientation = .horizontal
        case .vertical: orientation = .vertical
        @unknown default: return nil
        }
        id = plane.identifier
    }
}

enum SessionFailure: Equatable, Sendable {
    case cameraAccessDenied
    case other(String)
}
