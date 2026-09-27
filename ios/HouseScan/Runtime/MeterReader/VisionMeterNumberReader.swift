import CoreGraphics
import Foundation
import HouseScanKit
import ImageIO
import Vision

/// Reads the meter number from a close-up with Apple Vision, configured as the close-up eval
/// measured it (experiments/meter-closeup/README.md on t3/meter-closeup at 944cbe1, "For the app:
/// what to port"): focus check first, then text and barcodes, then HouseScanKit's ranking and size
/// check.
struct VisionMeterNumberReader: MeterNumberReader {
    /// How the stored pixels turn upright, as an EXIF orientation. Vision reads and the size check
    /// measures the upright photo.
    let orientation: CGImagePropertyOrientation

    @concurrent func read(jpeg: Data) async -> MeterReadout {
        Self.readout(jpeg: jpeg, orientation: orientation)
    }

    /// Nothing read in a photo that decoded and is in focus.
    private static let retakeNoNumber = MeterReadout(candidates: [], retake: .noNumber, numberTooSmall: false, photoPassedChecks: true)
    private static let undecodable = MeterReadout(candidates: [], retake: .noNumber, numberTooSmall: false, photoPassedChecks: false)

    private static func readout(jpeg: Data, orientation: CGImagePropertyOrientation) -> MeterReadout {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let gray = luma(of: image)
        else { return undecodable }

        // The eval's flow blocks a blurry photo before showing candidates, so Vision need not run.
        if MeterPhotoChecks.isOutOfFocus(sharpness: MeterPhotoChecks.wholePhotoSharpness(gray)) {
            return MeterReadout(candidates: [], retake: .blurry, numberTooSmall: false, photoPassedChecks: false)
        }

        let text = VNRecognizeTextRequest()
        text.revision = VNRecognizeTextRequestRevision3
        // The eval read 97% of meter numbers at .accurate and 75% at .fast; language correction
        // added nothing.
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["en-US"]
        text.usesLanguageCorrection = false
        // 0 is the default (full resolution); set so a changed default cannot drop small labels.
        text.minimumTextHeight = 0
        let barcodes = VNDetectBarcodesRequest()
        barcodes.revision = VNDetectBarcodesRequestRevision4
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([text, barcodes])
        } catch {
            return retakeNoNumber
        }

        let lines = (text.results ?? []).compactMap { observation -> MeterTextLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return MeterTextLine(text: best.string, box: topLeftBox(observation.boundingBox))
        }
        let payloads = (barcodes.results ?? []).compactMap(\.payloadStringValue)
        let found = MeterNumberRanking.candidates(lines: lines, barcodePayloads: payloads)
        let turned: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
        let uprightHeight = turned.contains(orientation) ? image.width : image.height
        guard let choices = MeterPhotoChecks.choices(from: found, photoHeight: uprightHeight) else {
            return retakeNoNumber
        }
        return MeterReadout(
            candidates: choices.candidates.enumerated().map { index, candidate in
                MeterNumberCandidate(id: index, text: candidate.core, barcodeConfirmed: candidate.barcodeConfirmed)
            },
            retake: nil,
            numberTooSmall: choices.numberTooSmall,
            photoPassedChecks: true,
            brand: MeterBrand.read(lines)
        )
    }

    /// Vision's normalized box has a bottom-left origin; the ranking uses a top-left one.
    private static func topLeftBox(_ box: CGRect) -> MeterBox {
        MeterBox(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// 8-bit luma of the stored pixels. Drawn in the image's own RGB color space when it has one,
    /// so the values are the file's, as PIL reads them, not color-matched.
    private static func luma(of image: CGImage) -> MeterGrayImage? {
        let width = image.width
        let height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = 4 * width
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return bytes.withUnsafeBytes { MeterGrayImage(rgbx: $0, width: width, height: height, bytesPerRow: bytesPerRow) }
    }
}
