/// The measuring tools. Each tap goes to the selected one.
enum Tool: String, CaseIterable, Identifiable, Sendable {
    /// Raycast to a horizontal plane ARKit has found.
    case ground
    /// Two ground contacts at the base of a wall make a vertical plane; a third checks it.
    case wall
    /// A ray from the tapped frame meets the latest wall's plane.
    case wallPoint
    /// The same feature tapped in two frames from different places, triangulated.
    case twoView

    var id: Self { self }

    var title: String {
        switch self {
        case .ground: "Ground"
        case .wall: "Wall"
        case .wallPoint: "On wall"
        case .twoView: "Two-view"
        }
    }

    var systemImage: String {
        switch self {
        case .ground: "arrow.down.to.line"
        case .wall: "ruler"
        case .wallPoint: "scope"
        case .twoView: "eyes"
        }
    }

    /// Whether a tap for this tool needs an ARKit raycast to the ground.
    var needsGround: Bool {
        self == .ground || self == .wall
    }
}
