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
    /// The photo decoded and passed the focus check, whether or not a number was read in it. Only
    /// such a photo's view goes into coverage (`CloseUpCredit`).
    var photoPassedChecks: Bool
    /// The maker named on the meter (`MeterBrand.read`), or nil when no line names one. Shown
    /// beside the candidates; it counts only when the homeowner confirms a number without
    /// rejecting it.
    var brand: String? = nil
}

/// Reads the meter number from the close-up JPEG. Runs off the main actor.
protocol MeterNumberReader: Sendable {
    func read(jpeg: Data) async -> MeterReadout
}

/// Reads nothing: every photo asks for a retake with `.noNumber`. Stands in until the Vision
/// reader lands.
struct UnavailableMeterNumberReader: MeterNumberReader {
    func read(jpeg: Data) async -> MeterReadout {
        // No check ran, so nothing vouches for the photo.
        MeterReadout(candidates: [], retake: .noNumber, numberTooSmall: false, photoPassedChecks: false)
    }
}

/// The reader the engine uses.
enum MeterNumberReaders {
    static func make() -> any MeterNumberReader {
        // The close-up JPEG holds the landscape sensor image unrotated (LiveCapture.encode) and the
        // app is portrait-only, so the upright photo is the stored one turned 90° clockwise, as
        // ImageWork.uprightThumbnail shows it: EXIF `.right`.
        VisionMeterNumberReader(orientation: .right)
    }
}
