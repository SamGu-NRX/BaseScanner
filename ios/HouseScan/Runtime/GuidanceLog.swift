import Foundation
import HouseScanKit

/// Every request the homeowner was shown during capture, and how each one ended: the packet's
/// `guidance` log. The server reads it to learn what the homeowner could not reach, which
/// scene.json cannot say.
///
/// A request is identified by its `Topic`. The engine reports what is on screen after each
/// guidance change (`show`); a new topic closes the open request with the outcome the engine
/// judges (`show`'s `closing`), unless an action already closed it with a known outcome
/// (`resolve`: "I can't get there", an answered question, a satisfied gap).
///
/// Times are on the capture clock (`ScanEngine.captureClock`): ARFrame.timestamp live. Spans are
/// meters of s along the wall; packaging converts them to meter-frame x.
struct GuidanceLog {
    typealias Kind = PacketGuidanceEntry.Kind
    typealias Origin = PacketGuidanceEntry.Origin
    typealias Band = PacketGuidanceEntry.Band
    typealias Outcome = PacketGuidanceEntry.Outcome

    /// What a request is about. Same topic, same request: a walk's remaining distance or a gap's
    /// progress changing on screen does not make a new one.
    enum Topic: Equatable, Sendable {
        case closeUp
        case walk(WallSide)
        /// Walk round the corner on this side and mark the next wall.
        case nextWall(WallSide)
        case markEnd(WallSide)
        /// Aim at a band at the coverage cell with this index.
        case aimAtGround(cell: Int)
        case aimAtWall(cell: Int)
        case stepBack
        case tiltUp
        case seeBehind(cell: Int)
        /// `GapRequest.id`.
        case gap(id: Int)
        /// `SpotCheck.id`.
        case spotCheck(id: Int)
    }

    struct Request: Equatable, Sendable {
        var topic: Topic
        var kind: Kind
        var origin: Origin
        var message: String
        var band: Band?
        /// Meters of s.
        var span: ClosedRange<Float>?
    }

    struct Entry: Sendable {
        var id: String
        var request: Request
        var shown: Double
        var resolved: Double?
        var outcome: Outcome
    }

    private(set) var entries: [Entry] = []
    /// The request on screen, whether or not it is still open.
    private(set) var current: Request?
    private var openIndex: Int?

    /// Records what is on screen now (nil: no request, such as the review or upload screens).
    /// A different request closes the open one with `closing(open, next)`.
    mutating func show(_ request: Request?, at t: Double, closing: (Request, Request?) -> Outcome) {
        guard request?.topic != current?.topic else { return }
        if let open = openIndex {
            close(open, closing(entries[open].request, request), at: t)
        }
        current = request
        guard let request else { return }
        entries.append(Entry(id: "g\(entries.count + 1)", request: request, shown: t, resolved: nil, outcome: .unresolved))
        openIndex = entries.count - 1
    }

    /// Closes the open request with a known outcome; it may stay on screen a moment longer.
    mutating func resolve(_ outcome: Outcome, at t: Double) {
        guard let open = openIndex else { return }
        close(open, outcome, at: t)
    }

    private mutating func close(_ index: Int, _ outcome: Outcome, at t: Double) {
        entries[index].outcome = outcome
        entries[index].resolved = max(t, entries[index].shown)
        openIndex = nil
    }
}
