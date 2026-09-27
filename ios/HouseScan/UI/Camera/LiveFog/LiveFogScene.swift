import Foundation
import simd

/// What the fog mask holds at one place: how thick the fog is, how much of it is the violet of a
/// hidden stretch, and how much is a gap request's amber. Channels of the mask texture, in order.
struct FogValue: Equatable {
    var fog: Float
    var hidden: Float
    var requested: Float

    static let clear = FogValue(fog: 0, hidden: 0, requested: 0)

    /// The rule the fog follows, from the coverage map's own cell states: the fog lifts only
    /// where coverage counts the cell, never where depth merely reached.
    /// - unseen: full fog.
    /// - seen from one position: thinned, not lifted, since one view is not evidence.
    /// - covered: lifted.
    /// - hidden (the camera looked, depth found something nearer): still fog, since the wall
    ///   behind is unseen, but thinner and violet, so the thing in front shows through with its
    ///   violet dots.
    /// - skipped ("I can't get there"): lifted here; `FogMarks` hatches it, so it never reads as
    ///   seen.
    /// - requested by a gap and not yet covered: amber instead of fog, so the camera shows where
    ///   to aim.
    static func target(_ state: CellState, requested: Bool) -> FogValue {
        if requested, state != .covered { return FogValue(fog: 0, hidden: 0, requested: 1) }
        return switch state {
        case .unseen: FogValue(fog: 1, hidden: 0, requested: 0)
        case .seen: FogValue(fog: 0.55, hidden: 0, requested: 0)
        case .hidden: FogValue(fog: 0.75, hidden: 1, requested: 0)
        case .covered, .skipped: .clear
        }
    }

    func mixed(to other: FogValue, _ t: Float) -> FogValue {
        FogValue(fog: fog + (other.fog - fog) * t, hidden: hidden + (other.hidden - hidden) * t, requested: requested + (other.requested - requested) * t)
    }

    var total: Float { fog + hidden + requested }
}

/// Eases each cell from its old fog to its new one when coverage changes it. Lifting is the
/// signature moment ("the phone saw that") and takes `Motion.fogLift` on the strong ease-out;
/// fog coming back (a cell turning hidden, a request raised) is quick, 150 ms, because it is the
/// system answering, not a reveal. Under Reduce Motion both are linear fades, 400 and 120 ms, as
/// in the prototype. Keyed by the cell's s, not its index in the strip, which shifts when the
/// strip grows to the left.
@MainActor
final class FogCellAnimator {
    struct Key: Hashable {
        var band: CoverageBand
        /// The cell's left edge in whole cell widths from s = 0.
        var cell: Int
    }

    private struct Track {
        var from: FogValue
        var to: FogValue
        var start: Double
        var duration: Double
        var linear: Bool

        func value(at now: Double) -> FogValue {
            guard duration > 0 else { return to }
            let p = Float(min(max((now - start) / duration, 0), 1))
            return from.mixed(to: to, linear ? p : Easing.strongEaseOut(p))
        }

        func isDone(at now: Double) -> Bool { now - start >= duration }
    }

    private var tracks: [Key: Track] = [:]
    private var seen: Set<Key> = []

    /// The cell's value now. A cell seen for the first time starts at its target.
    func value(_ key: Key, target: FogValue, now: Double, reduceMotion: Bool) -> FogValue {
        seen.insert(key)
        guard var track = tracks[key] else {
            tracks[key] = Track(from: target, to: target, start: now, duration: 0, linear: false)
            return target
        }
        if track.to != target {
            let current = track.value(at: now)
            let lifting = target.total < current.total
            let duration = reduceMotion ? (lifting ? 0.4 : 0.12) : (lifting ? Motion.fogLift : 0.15)
            track = Track(from: current, to: target, start: now, duration: duration, linear: reduceMotion)
            tracks[key] = track
        }
        return track.value(at: now)
    }

    /// Forgets cells the last frame did not draw, so the table never outgrows the strip.
    func endFrame() {
        if tracks.count > seen.count { tracks = tracks.filter { seen.contains($0.key) } }
        seen.removeAll(keepingCapacity: true)
    }
}

/// Builds the fog mask's geometry: each coverage cell as a wall column from the ground up
/// `columnHeight` and a stretch of ground out `groundReach`, carrying its `FogValue`. The column
/// and the stretch reach past the bands coverage measures (4.5 ft of wall, 4 ft of ground) on
/// purpose: fog there could never lift, and fog that walking can't clear stops meaning
/// "not seen yet". The wall above a covered column and the lawn in front of it are nothing the
/// scan decides on. Past a marked end the wall is not part of the scan, and is clear. Anything
/// no quad reaches (the wall past the strip, where the walk has not been) keeps the mask's clear
/// value, full fog.
enum FogMaskGeometry {
    struct Vertex {
        var position: SIMD4<Float>
        var value: SIMD4<Float>
    }

    static let columnHeight: Float = 8
    static let groundReach: Float = 8
    /// How far past a marked end the clear stretch runs.
    static let pastEnd: Float = 30

    /// Writes triangles into `vertices` (at most `capacity`) and returns how many it wrote.
    /// Neighbouring cells with the same value on the same piece of wall merge into one quad.
    @MainActor
    static func build(
        coverage: CoverageStrip, wall: WallGeometry, highlight: GapRequest?, animator: FogCellAnimator,
        now: Double, reduceMotion: Bool, into vertices: UnsafeMutablePointer<Vertex>, capacity: Int
    ) -> Int {
        var count = 0
        func quad(_ band: CoverageBand, _ s0: Float, _ s1: Float, _ value: FogValue) {
            guard count + 6 <= capacity else { return }
            let far0 = band == .wall ? wall.world(s: s0, height: columnHeight) : wall.world(s: s0, height: 0, out: groundReach)
            let far1 = band == .wall ? wall.world(s: s1, height: columnHeight) : wall.world(s: s1, height: 0, out: groundReach)
            let a = SIMD4(wall.world(s: s0, height: 0), 1), b = SIMD4(wall.world(s: s1, height: 0), 1)
            let c = SIMD4(far1, 1), d = SIMD4(far0, 1)
            let v = SIMD4(value.fog, value.hidden, value.requested, 0)
            vertices[count] = Vertex(position: a, value: v)
            vertices[count + 1] = Vertex(position: b, value: v)
            vertices[count + 2] = Vertex(position: c, value: v)
            vertices[count + 3] = Vertex(position: a, value: v)
            vertices[count + 4] = Vertex(position: c, value: v)
            vertices[count + 5] = Vertex(position: d, value: v)
            count += 6
        }

        let visible = coverage.visibleRange
        if visible.upperBound > visible.lowerBound {
            for band in CoverageBand.allCases {
                let states = coverage.cells(band)
                var run: (s0: Float, s1: Float, value: FogValue, along: SIMD3<Float>)?
                for index in states.indices {
                    let range = coverage.cellRange(index)
                    guard range.upperBound > visible.lowerBound, range.lowerBound < visible.upperBound else { continue }
                    let s0 = max(range.lowerBound, visible.lowerBound), s1 = min(range.upperBound, visible.upperBound)
                    let requested = highlight.map { $0.band == band && $0.span.lowerBound < range.upperBound && range.lowerBound < $0.span.upperBound } ?? false
                    let key = FogCellAnimator.Key(band: band, cell: Int((range.lowerBound / coverage.cellWidth).rounded()))
                    let value = animator.value(key, target: FogValue.target(states[index], requested: requested), now: now, reduceMotion: reduceMotion)
                    let along = wall.along(atS: (s0 + s1) / 2)
                    if var current = run, current.value == value, current.along == along, abs(current.s1 - s0) < 1e-4 {
                        current.s1 = s1
                        run = current
                    } else {
                        if let current = run { quad(band, current.s0, current.s1, current.value) }
                        run = (s0, s1, value, along)
                    }
                }
                if let current = run { quad(band, current.s0, current.s1, current.value) }
            }
        }
        for band in CoverageBand.allCases {
            if let left = wall.leftEnd { quad(band, left - pastEnd, left, .clear) }
            if let right = wall.rightEnd { quad(band, right, right + pastEnd, .clear) }
        }
        animator.endFrame()
        return count
    }
}

/// The dots' timing on the renderer's clock: when each was born, when its opacity last changed
/// and from what, when it turned edge, and, for a dot that left the field, when it died. The
/// shader evaluates the curves, so the buffer changes only when the field does or a death ends.
@MainActor
final class DotTimeline {
    struct Sprite {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var c: SIMD4<Float>
    }

    private struct Track {
        var birth: Float
        var from: Float
        var to: Float
        var opacityTime: Float
        var edgeSince: Float
        var dot: LiveDots.Dot

        func opacity(at t: Float) -> Float {
            from + (to - from) * Easing.strongEaseOut((t - opacityTime) / 0.25)
        }
    }

    /// Metal compiles with fast math, which assumes no infinities.
    private static let never: Float = 1e6
    private static let deathFade: Float = 0.3

    private var tracks: [UInt64: Track] = [:]
    private var dying: [(track: Track, death: Float)] = []
    private var revision = -1
    /// Dots the renderer draws at once, living and dying: the field's own cap
    /// (`SurfaceDotConfig.maxDots`, 5,000) and as many again fading out.
    static let capacity = 10_000

    /// Takes a new field. Returns true when the sprites changed.
    func update(_ field: LiveDots, now: Float) -> Bool {
        guard field.revision != revision else { return false }
        revision = field.revision
        var next: [UInt64: Track] = [:]
        next.reserveCapacity(field.dots.count)
        for dot in field.dots {
            if var track = tracks[dot.id] {
                if dot.opacity != track.to {
                    track.from = track.opacity(at: now)
                    track.to = dot.opacity
                    track.opacityTime = now
                }
                if dot.isEdge, track.edgeSince >= Self.never { track.edgeSince = now }
                track.dot = dot
                next[dot.id] = track
            } else {
                next[dot.id] = Track(
                    birth: now, from: dot.opacity, to: dot.opacity, opacityTime: -Self.never,
                    edgeSince: dot.isEdge ? -Self.never : Self.never, dot: dot)
            }
        }
        for (id, track) in tracks where next[id] == nil { dying.append((track, now)) }
        if dying.count > Self.capacity / 2 { dying.removeFirst(dying.count - Self.capacity / 2) }
        tracks = next
        return true
    }

    /// Drops dots whose fade has finished. Returns true when any went.
    func expire(now: Float) -> Bool {
        let before = dying.count
        dying.removeAll { now - $0.death > Self.deathFade }
        return dying.count != before
    }

    /// Two sprites per dot, its halo then its core, so the sharp cores sit on the glow. Returns
    /// how many it wrote, at most `capacity`.
    func write(into sprites: UnsafeMutablePointer<Sprite>, capacity: Int) -> Int {
        var count = 0
        func add(_ track: Track, death: Float) {
            guard count + 2 <= capacity else { return }
            let d = track.dot
            let b = SIMD4(track.birth, track.from, track.to, track.opacityTime)
            let c = SIMD4(track.edgeSince, death, d.onOccluder ? 1 : 0, 0)
            sprites[count] = Sprite(a: SIMD4(d.position, 1), b: b, c: c)
            sprites[count + 1] = Sprite(a: SIMD4(d.position, 0), b: b, c: c)
            count += 2
        }
        for track in tracks.values { add(track, death: Self.never) }
        for entry in dying { add(entry.track, death: entry.death) }
        return count
    }
}

/// cubic-bezier(0.23, 1, 0.32, 1), the same curve the shader solves.
enum Easing {
    static func strongEaseOut(_ progress: Float) -> Float {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        let x1: Float = 0.23, x2: Float = 0.32
        var t = progress
        for _ in 0..<8 {
            let u = 1 - t
            let x = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t - progress
            let dx = 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
            if abs(dx) < 1e-6 { break }
            t = min(max(t - x / dx, 0), 1)
        }
        let u = 1 - t
        return 3 * u * u * t + 3 * u * t * t + t * t * t
    }
}
