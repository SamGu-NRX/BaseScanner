import Observation

/// Share of keyframes fused so far, for the loading bar.
@Observable
final class LoadProgress {
    var fraction: Double = 0
}
