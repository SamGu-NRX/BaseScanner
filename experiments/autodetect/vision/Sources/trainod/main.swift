// Trains a Create ML object detector (MLObjectDetector) on a folder of images plus
// annotations.json in Create ML's format: [{"image": "a.jpg", "annotations": [{"label",
// "coordinates": {"x", "y", "width", "height"}}]}], pixels, box centre, top-left origin.
//
// Usage: trainod <train-dir> <out.mlmodel> [transfer|yolo] [max-iterations]
// transfer: transfer learning on Apple's object feature print (the extractor ships in the OS,
// so the model file holds only the detection head). yolo: the full darknet-YOLO network.
// Without max-iterations, Create ML picks the count.

import CreateML
import CoreML
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: trainod <train-dir> <out.mlmodel> [transfer|yolo] [max-iterations]\n".utf8))
    exit(2)
}
let trainDir = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2])
let algoName = args.count > 3 ? args[3] : "transfer"
let iterations = args.count > 4 ? Int(args[4]) : nil

let algorithm: MLObjectDetector.ModelParameters.ModelAlgorithmType
switch algoName {
case "transfer": algorithm = .transferLearning(.objectPrint(revision: 1))
case "yolo": algorithm = .darknetYolo
default:
    FileHandle.standardError.write(Data("unknown algorithm \(algoName); use transfer or yolo\n".utf8))
    exit(2)
}

var params = MLObjectDetector.ModelParameters(validation: .split(strategy: .automatic), maxIterations: iterations)
params.algorithm = algorithm
let started = Date()
let detector = try MLObjectDetector(
    trainingData: .directoryWithImagesAndJsonAnnotation(at: trainDir),
    parameters: params,
    annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center)
)
let seconds = Date().timeIntervalSince(started)
try detector.write(to: out, metadata: MLModelMetadata(
    author: "house-scanning autodetect experiment",
    shortDescription: "Window and door detector, Create ML \(algoName), Open Images V7 train subset",
    license: "Training images CC BY 2.0 (Open Images); see manifests/oi_train.csv"
))
let report: [String: Any] = [
    "algorithm": algoName,
    "max_iterations": iterations.map { $0 as Any } ?? NSNull(),
    "train_seconds": seconds,
    "training_map50": detector.trainingMetrics.meanAveragePrecision.IoU50,
    "validation_map50": detector.validationMetrics.meanAveragePrecision.IoU50,
    "validation_ap50": detector.validationMetrics.averagePrecision.IoU50,
    "parameters": "\(detector.modelParameters)",
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
