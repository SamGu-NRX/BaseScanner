// Reads text from images with Apple Vision (VNRecognizeTextRequest), the engine the iPhone app
// would call. One JSON request per stdin line, one JSON result per stdout line, so a Python
// driver can stream thousands of degraded images through a single process.
//
// Request:  {"path": "...", "level": "accurate"|"fast", "language_correction": false,
//            "crop": [x, y, w, h],   // optional, normalized, top-left origin
//            "barcodes": false}      // true also runs VNDetectBarcodesRequest (revision 4)
// Result:   {"path", "width", "height", "elapsed_ms", "lines": [{"text", "confidence",
//            "box": [x, y, w, h], "candidates": [...]}],   // box normalized, top-left origin
//            "barcodes": [{"payload", "symbology", "confidence", "box"}]}   // when requested
//
// Usage: meterocr < requests.jsonl        or        meterocr [--fast] [--lc] image...

import CoreGraphics
import Foundation
import ImageIO
import Vision

struct Request: Decodable {
    let path: String
    var level: String? = "accurate"
    var language_correction: Bool? = false
    var crop: [Double]? = nil
    var barcodes: Bool? = false
}

struct Line: Encodable {
    let text: String
    let confidence: Float
    let box: [Double]
    let candidates: [String]
}

struct Barcode: Encodable {
    let payload: String?
    let symbology: String
    let confidence: Float
    let box: [Double]
}

struct Result: Encodable {
    let path: String
    let level: String
    let language_correction: Bool
    let crop: [Double]?
    let width: Int
    let height: Int
    let elapsed_ms: Double
    let lines: [Line]
    let barcodes: [Barcode]?
    let error: String?
}

enum ReadError: Error, CustomStringConvertible {
    case unreadableImage(String)
    case badCrop([Double])

    var description: String {
        switch self {
        case .unreadableImage(let path): "cannot decode image at \(path)"
        case .badCrop(let crop): "crop must be 4 normalized values inside [0, 1], got \(crop)"
        }
    }
}

func loadImage(_ path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw ReadError.unreadableImage(path) }
    return image
}

func read(_ request: Request) -> Result {
    let level = request.level ?? "accurate"
    let correction = request.language_correction ?? false
    let started = Date()
    var width = 0
    var height = 0
    do {
        var image = try loadImage(request.path)
        if let crop = request.crop {
            guard crop.count == 4, crop.allSatisfy({ (0...1).contains($0) }),
                  crop[0] + crop[2] <= 1.0001, crop[1] + crop[3] <= 1.0001
            else { throw ReadError.badCrop(crop) }
            let rect = CGRect(
                x: crop[0] * Double(image.width), y: crop[1] * Double(image.height),
                width: crop[2] * Double(image.width), height: crop[3] * Double(image.height)
            ).integral
            guard let cropped = image.cropping(to: rect) else { throw ReadError.badCrop(crop) }
            image = cropped
        }
        width = image.width
        height = image.height

        let vision = VNRecognizeTextRequest()
        vision.revision = VNRecognizeTextRequestRevision3
        vision.recognitionLevel = level == "fast" ? .fast : .accurate
        vision.usesLanguageCorrection = correction
        vision.recognitionLanguages = ["en-US"]
        // Default is already 0.0 (full resolution, per the SDK header); set it so a future
        // default change cannot silently drop small labels.
        vision.minimumTextHeight = 0
        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.revision = VNDetectBarcodesRequestRevision4
        let wantsBarcodes = request.barcodes ?? false
        try VNImageRequestHandler(cgImage: image, orientation: .up)
            .perform(wantsBarcodes ? [vision, barcodeRequest] : [vision])
        let barcodes = wantsBarcodes
            ? (barcodeRequest.results ?? []).map { observation in
                let b = observation.boundingBox
                return Barcode(
                    payload: observation.payloadStringValue,
                    symbology: observation.symbology.rawValue,
                    confidence: observation.confidence,
                    box: [b.minX, 1 - b.maxY, b.width, b.height])
            }
            : nil

        let lines = (vision.results ?? []).compactMap { observation -> Line? in
            let top = observation.topCandidates(3)
            guard let best = top.first else { return nil }
            let b = observation.boundingBox  // normalized, bottom-left origin
            return Line(
                text: best.string,
                confidence: best.confidence,
                box: [b.minX, 1 - b.maxY, b.width, b.height],
                candidates: top.map(\.string)
            )
        }
        return Result(
            path: request.path, level: level, language_correction: correction, crop: request.crop,
            width: width, height: height, elapsed_ms: Date().timeIntervalSince(started) * 1000,
            lines: lines, barcodes: barcodes, error: nil)
    } catch {
        return Result(
            path: request.path, level: level, language_correction: correction, crop: request.crop,
            width: width, height: height, elapsed_ms: Date().timeIntervalSince(started) * 1000,
            lines: [], barcodes: nil, error: String(describing: error))
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

func emit(_ result: Result) {
    let data = try! encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty {
    let decoder = JSONDecoder()
    while let line = readLine() {
        guard !line.isEmpty else { continue }
        do {
            let request = try decoder.decode(Request.self, from: Data(line.utf8))
            autoreleasepool { emit(read(request)) }
        } catch {
            FileHandle.standardError.write(Data("bad request line: \(line)\n".utf8))
            exit(2)
        }
    }
} else {
    let fast = arguments.contains("--fast")
    let correction = arguments.contains("--lc")
    arguments.removeAll { $0.hasPrefix("--") }
    for path in arguments {
        emit(read(Request(path: path, level: fast ? "fast" : "accurate", language_correction: correction)))
    }
}
