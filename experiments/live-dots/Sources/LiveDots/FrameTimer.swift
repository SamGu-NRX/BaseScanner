import Synchronization

/// Running averages of the live view's frame cost. Command buffers report GPU time on a Metal
/// thread, so the numbers sit behind a lock.
nonisolated final class FrameTimer: Sendable {
    struct Averages {
        var cpuMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var sprites = 0
    }

    private let state = Mutex(Averages())

    func record(cpuSeconds: Double, gpuSeconds: Double, sprites: Int) {
        state.withLock {
            $0.cpuMilliseconds = $0.cpuMilliseconds * 0.95 + cpuSeconds * 1000 * 0.05
            $0.gpuMilliseconds = $0.gpuMilliseconds * 0.95 + gpuSeconds * 1000 * 0.05
            $0.sprites = sprites
        }
    }

    var averages: Averages { state.withLock { $0 } }
}
