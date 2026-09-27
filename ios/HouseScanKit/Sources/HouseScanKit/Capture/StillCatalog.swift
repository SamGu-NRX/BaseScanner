import Foundation

/// The close-up stills of one scan, such as the meter close-up, by purpose (scene.json `stills`
/// key, "meter_close").
///
/// Every saved still is a photo of the scan, kept with its frame for the packet. Only a still the
/// homeowner accepted stands for its purpose: scene.json lists it, and the packet links it to its
/// mark. A still that was turned down (the reader found no number, "None of these", or the step
/// was skipped) stays a plain photo, a record of the attempt, never the accepted close-up.
/// Before, a rejected meter photo was listed and linked like an accepted one.
public struct StillCatalog<Frame: Sendable>: Sendable {
    public struct Still: Sendable {
        public var fileName: String
        public var frame: Frame
        public var accepted: Bool
    }

    /// Purpose to the still saved for it: the photo on disk under `fileName`.
    public private(set) var saved: [String: Still] = [:]

    public init() {}

    /// Purpose to file name for the accepted stills: scene.json's `stills`.
    public var acceptedFileNames: [String: String] {
        saved.filter(\.value.accepted).mapValues(\.fileName)
    }

    /// Purpose to frame for every saved still, accepted or not: the packet's photos.
    public var frames: [String: Frame] { saved.mapValues(\.frame) }

    public func isAccepted(_ purpose: String) -> Bool { saved[purpose]?.accepted == true }

    /// A still was written for `purpose`, over any earlier one. Nobody has accepted the new
    /// photo, so an earlier acceptance goes with the photo it was for.
    public mutating func save(_ frame: Frame, purpose: String, fileName: String) {
        saved[purpose] = Still(fileName: fileName, frame: frame, accepted: false)
    }

    /// The homeowner accepted the still saved for `purpose`. False when none is saved.
    @discardableResult
    public mutating func accept(_ purpose: String) -> Bool {
        guard saved[purpose] != nil else { return false }
        saved[purpose]?.accepted = true
        return true
    }

    /// The still saved for `purpose` no longer stands for it (the step was skipped). The photo
    /// stays a plain photo of the scan.
    public mutating func withdraw(_ purpose: String) {
        saved[purpose]?.accepted = false
    }

    /// Forgets every still. Returns their file names, for the caller to delete.
    public mutating func removeAll() -> [String] {
        defer { saved = [:] }
        return saved.values.map(\.fileName).sorted()
    }
}
