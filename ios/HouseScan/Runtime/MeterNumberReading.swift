import Foundation

// The boundary between the engine's close-up flow and the meter-number reader. The checks and
// their thresholds come from the close-up eval (experiments/meter-closeup/README.md on
// t3/meter-closeup at 944cbe1, "For the app: what to port").

/// What one close-up photo yielded.
struct MeterReadout: Sendable, Equatable {
    /// The best candidates, barcode-confirmed first, at most three. Empty when the photo must be
    /// retaken.
    var candidates: [MeterNumberCandidate]
    /// Why to retake (`.blurry` from the focus check, `.noNumber` when nothing was read); nil when
    /// there are candidates to show.
    var retake: CloseUpProblem?
    /// The top candidate's characters are small in the photo, so after "None of these" the right
    /// advice is "move closer" (`.numberTooSmall`) rather than a plain retake.
    var numberTooSmall: Bool
}

/// Reads the meter number from the close-up JPEG. Runs off the main actor.
protocol MeterNumberReader: Sendable {
    func read(jpeg: Data) async -> MeterReadout
}

/// Reads nothing: every photo asks for a retake with `.noNumber`. Stands in until the Vision
/// reader lands.
struct UnavailableMeterNumberReader: MeterNumberReader {
    func read(jpeg: Data) async -> MeterReadout {
        MeterReadout(candidates: [], retake: .noNumber, numberTooSmall: false)
    }
}

/// The reader the engine uses. The meter-reader lane points this at its Vision reader.
enum MeterNumberReaders {
    static func make() -> any MeterNumberReader {
        UnavailableMeterNumberReader()
    }
}
