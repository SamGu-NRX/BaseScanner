// Finds rectangles with Apple Vision's VNDetectRectanglesRequest, as class-agnostic window
// proposals. One JSON request per stdin line, one JSON result per stdout line.
//
// Request: {"path": "...", "maximumObservations": 0, "minimumAspectRatio": 0.2,
//           "maximumAspectRatio": 1.0, "minimumSize": 0.03, "quadratureTolerance": 30,
//           "minimumConfidence": 0}
// Result:  {"path", "width", "height", "elapsed_ms", "rects": [{"box": [x0, y0, x1, y1],
//           "corners": [[x, y] x4], "score"}], "error"}
// Boxes are the quadrilateral's axis-aligned bounds, normalized, top-left origin. elapsed_ms
// times perform() only, not decoding.

import CoreGraphics
import Foundation
import ImageIO
import Vision

struct Request: Decodable {
    let path: String
    let maximumObservations: Int
    let minimumAspectRatio: Float
    let maximumAspectRatio: Float
    let minimumSize: Float
    let quadratureTolerance: Float
    let minimumConfidence: Float
}

struct Rect: Encodable {
    let box: [Double]
    let corners: [[Double]]
    let score: Float
}

struct Result: Encodable {
    let path: String
    let width: Int
    let height: Int
    let elapsed_ms: Double
    let rects: [Rect]
    let error: String?
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func detect(_ r: Request) -> Result {
    guard let image = loadImage(r.path) else {
        return Result(path: r.path, width: 0, height: 0, elapsed_ms: 0, rects: [], error: "cannot decode image")
    }
    let request = VNDetectRectanglesRequest()
    request.maximumObservations = r.maximumObservations
    request.minimumAspectRatio = r.minimumAspectRatio
    request.maximumAspectRatio = r.maximumAspectRatio
    request.minimumSize = r.minimumSize
    request.quadratureTolerance = r.quadratureTolerance
    request.minimumConfidence = r.minimumConfidence
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let started = DispatchTime.now().uptimeNanoseconds
    do {
        try handler.perform([request])
    } catch {
        return Result(path: r.path, width: image.width, height: image.height, elapsed_ms: 0, rects: [], error: "\(error)")
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    // Vision's normalized coordinates have a bottom-left origin; flip y.
    let rects = (request.results ?? []).map { o -> Rect in
        let pts = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { [Double($0.x), 1 - Double($0.y)] }
        let xs = pts.map { $0[0] }, ys = pts.map { $0[1] }
        return Rect(box: [xs.min()!, ys.min()!, xs.max()!, ys.max()!], corners: pts, score: o.confidence)
    }
    return Result(path: r.path, width: image.width, height: image.height, elapsed_ms: ms, rects: rects, error: nil)
}

let decoder = JSONDecoder()
let encoder = JSONEncoder()
while let line = readLine() {
    guard !line.isEmpty else { continue }
    let result: Result
    do {
        result = detect(try decoder.decode(Request.self, from: Data(line.utf8)))
    } catch {
        result = Result(path: "", width: 0, height: 0, elapsed_ms: 0, rects: [], error: "bad request: \(error)")
    }
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
    fflush(stdout)
}
