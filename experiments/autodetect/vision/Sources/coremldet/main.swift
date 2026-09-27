// Runs a Create ML object detector through Vision (VNCoreMLRequest), the way the app would, and
// times each call. One image path per stdin line, one JSON result per stdout line.
//
// Usage: coremldet <model.mlmodel|.mlmodelc> <all|cpu> <scaleFill|scaleFit|centerCrop> <conf> <iou>
// Result: {"path", "elapsed_ms", "detections": [{"label", "score", "box": [x0, y0, x1, y1]}]}
// Boxes normalized, top-left origin. elapsed_ms times perform() only, not decoding. `conf` and
// `iou` feed the model's confidenceThreshold and iouThreshold inputs (its NMS stage).

import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

struct Detection: Encodable {
    let label: String
    let score: Float
    let box: [Double]
}

struct Result: Encodable {
    let path: String
    let elapsed_ms: Double
    let detections: [Detection]
    let error: String?
}

final class Thresholds: NSObject, MLFeatureProvider {
    let values: [String: MLFeatureValue]
    init(conf: Double, iou: Double) {
        values = ["confidenceThreshold": MLFeatureValue(double: conf), "iouThreshold": MLFeatureValue(double: iou)]
    }
    var featureNames: Set<String> { Set(values.keys) }
    func featureValue(for name: String) -> MLFeatureValue? { values[name] }
}

let args = CommandLine.arguments
guard args.count == 6, let conf = Double(args[4]), let iou = Double(args[5]) else {
    FileHandle.standardError.write(Data("usage: coremldet <model> <all|cpu> <scaleFill|scaleFit|centerCrop> <conf> <iou>\n".utf8))
    exit(2)
}
var modelURL = URL(fileURLWithPath: args[1])
if modelURL.pathExtension == "mlmodel" {
    modelURL = try MLModel.compileModel(at: modelURL)
}
let config = MLModelConfiguration()
switch args[2] {
case "all": config.computeUnits = .all
case "cpu": config.computeUnits = .cpuOnly
default: FileHandle.standardError.write(Data("compute units must be all or cpu\n".utf8)); exit(2)
}
let crop: VNImageCropAndScaleOption
switch args[3] {
case "scaleFill": crop = .scaleFill
case "scaleFit": crop = .scaleFit
case "centerCrop": crop = .centerCrop
default: FileHandle.standardError.write(Data("unknown crop option \(args[3])\n".utf8)); exit(2)
}
let vnModel = try VNCoreMLModel(for: try MLModel(contentsOf: modelURL, configuration: config))
vnModel.featureProvider = Thresholds(conf: conf, iou: iou)

let encoder = JSONEncoder()
while let path = readLine() {
    guard !path.isEmpty else { continue }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        print(String(decoding: try encoder.encode(Result(path: path, elapsed_ms: 0, detections: [], error: "cannot decode image")), as: UTF8.self))
        continue
    }
    let request = VNCoreMLRequest(model: vnModel)
    request.imageCropAndScaleOption = crop
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let started = DispatchTime.now().uptimeNanoseconds
    var failure: String? = nil
    do { try handler.perform([request]) } catch { failure = "\(error)" }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    let dets = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o -> Detection? in
        let b = o.boundingBox  // normalized, bottom-left origin
        let box = [Double(b.minX), 1 - Double(b.maxY), Double(b.maxX), 1 - Double(b.minY)]
        // One label per box, the most confident, as for the other candidates.
        guard let top = o.labels.first else { return nil }
        return Detection(label: top.identifier, score: top.confidence, box: box)
    }
    print(String(decoding: try encoder.encode(Result(path: path, elapsed_ms: ms, detections: dets, error: failure)), as: UTF8.self))
    fflush(stdout)
}
