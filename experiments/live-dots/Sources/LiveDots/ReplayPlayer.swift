import LiveDotsCore
import Observation
import QuartzCore

/// The playback state the controls edit and the renderer reads. Keyframes play at 4 per second
/// and cut; the dots animate on the same clock.
@Observable
final class ReplayPlayer {
    let keyframeCount: Int
    var mode: CaptureMode = .lidar
    var reduceMotion: Bool
    var showFog = false
    private(set) var isPlaying = false
    private(set) var keyframe = 0
    /// Playback seconds. Keyframe k is on screen from k / 4 to (k + 1) / 4.
    @ObservationIgnored private(set) var playhead: Float = 0
    /// After a scrub the frame shows its settled state instead of replaying births.
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var lastTick: CFTimeInterval?

    /// Playback runs this long past the last keyframe so its births finish.
    private var end: Float { Float(keyframeCount) / Tuning.keyframesPerSecond + Tuning.birthDuration }

    init(keyframeCount: Int, reduceMotion: Bool) {
        self.keyframeCount = keyframeCount
        self.reduceMotion = reduceMotion
    }

    var request: FrameRequest {
        FrameRequest(
            mode: mode, keyframe: keyframe, time: settled ? 1e5 : playhead,
            reduceMotion: reduceMotion, showFog: showFog)
    }

    func togglePlayback() {
        if isPlaying {
            isPlaying = false
            return
        }
        if playhead >= end - 1e-3 || (keyframe == keyframeCount - 1 && settled) { seek(to: 0, settle: false) }
        settled = false
        lastTick = nil
        isPlaying = true
    }

    /// Jumps to a keyframe and shows it settled. Scrubbing while playing keeps playing from there.
    func scrub(to index: Int) {
        seek(to: index, settle: !isPlaying)
    }

    private func seek(to index: Int, settle: Bool) {
        keyframe = min(max(index, 0), keyframeCount - 1)
        playhead = Float(keyframe) / Tuning.keyframesPerSecond
        settled = settle
        lastTick = nil
    }

    /// Advances the clock; the Metal view calls this once per display frame.
    func tick(now: CFTimeInterval) {
        guard isPlaying else { return }
        if let lastTick { playhead += Float(now - lastTick) }
        lastTick = now
        let index = min(Int(playhead * Tuning.keyframesPerSecond), keyframeCount - 1)
        if index != keyframe { keyframe = index }
        if playhead >= end {
            playhead = end
            isPlaying = false
        }
    }
}
