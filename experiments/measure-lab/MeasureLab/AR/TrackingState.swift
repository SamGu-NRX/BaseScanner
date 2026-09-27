import ARKit

/// ARKit's tracking state reduced to a Sendable value the main actor can hold.
enum TrackingState: Equatable, Sendable {
    case notAvailable
    case limited(LimitedReason)
    case normal

    enum LimitedReason: String, Equatable, Sendable {
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

    /// The name written to session.json, for example "limited.excessiveMotion".
    var manifestName: String {
        switch self {
        case .notAvailable: "notAvailable"
        case .normal: "normal"
        case .limited(let reason): "limited.\(reason.rawValue)"
        }
    }

    var instruction: String {
        switch self {
        case .notAvailable: "Waiting for the camera"
        case .normal: "Tracking"
        case .limited(.initializing): "Move the phone slowly to start"
        case .limited(.excessiveMotion): "Slow down"
        case .limited(.insufficientFeatures): "Aim lower to include the ground"
        case .limited(.relocalizing): "Point back at where you were"
        case .limited(.unknown): "Hold the phone steady"
        }
    }
}

enum SessionFailure: Equatable, Sendable {
    case cameraAccessDenied
    case other(String)
}
