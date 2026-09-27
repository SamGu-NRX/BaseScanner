// Trains a Create ML object detector (MLObjectDetector) on a folder of images plus
// annotations.json in Create ML's format: [{"image": "a.jpg", "annotations": [{"label",
// "coordinates": {"x", "y", "width", "height"}}]}], pixels, box centre, top-left origin.
//
// Usage: trainod <train-dir> <out.mlmodel> <transfer|yolo> <iterations> <session-dir>
// transfer: transfer learning on Apple's object feature print (the extractor ships in the OS,
// so the model file holds only the detection head). yolo: the full darknet-YOLO network.
// Progress goes to stderr every 10 iterations. The session directory keeps checkpoints, so
// rerunning the same command after a kill resumes instead of starting over.

import Combine
import CreateML
import CoreML
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 6, let iterations = Int(args[4]) else {
    fail("usage: trainod <train-dir> <out.mlmodel> <transfer|yolo> <iterations> <session-dir>")
}
let trainDir = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2])
let algoName = args[3]
let sessionDir = URL(fileURLWithPath: args[5], isDirectory: true)

var params = MLObjectDetector.ModelParameters(validation: .split(strategy: .automatic), maxIterations: iterations)
switch algoName {
case "transfer": params.algorithm = .transferLearning(.objectPrint(revision: 1))
case "yolo": params.algorithm = .darknetYolo
default: fail("unknown algorithm \(algoName); use transfer or yolo")
}
let session = MLTrainingSessionParameters(sessionDirectory: sessionDir, reportInterval: 10, checkpointInterval: 50, iterations: iterations)
let started = Date()
let job: MLJob<MLObjectDetector>
if FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("session.json").path) {
    let restored = try MLObjectDetector.restoreTrainingSession(sessionParameters: session)
    job = try MLObjectDetector.resume(restored)
} else {
    job = try MLObjectDetector.train(
        trainingData: .directoryWithImagesAndJsonAnnotation(at: trainDir),
        annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center),
        parameters: params,
        sessionParameters: session
    )
}

let watcher = job.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
    guard let p = MLProgress(progress: progress) else { return }
    let loss = (p.metrics[.loss] as? Double).map { String(format: "%.4f", $0) } ?? "-"
    FileHandle.standardError.write(Data("phase \(p.phase) item \(p.itemCount)/\(p.totalItemCount ?? -1) loss \(loss) t \(Int(p.elapsedTime))s\n".utf8))
}

var bag = Set<AnyCancellable>()
job.result.sink(
    receiveCompletion: { completion in
        if case .failure(let error) = completion { fail("training failed: \(error)") }
    },
    receiveValue: { detector in
        do {
            try detector.write(to: out, metadata: MLModelMetadata(
                author: "house-scanning autodetect experiment",
                shortDescription: "Window and door detector, Create ML \(algoName), Open Images V7 train subset",
                license: "Training images CC BY 2.0 (Open Images); see manifests/oi_train.csv"
            ))
            let report: [String: Any] = [
                "algorithm": algoName,
                "iterations": iterations,
                "train_seconds_this_run": Date().timeIntervalSince(started),
                "training_map50": detector.trainingMetrics.meanAveragePrecision.IoU50,
                "validation_map50": detector.validationMetrics.meanAveragePrecision.IoU50,
                "validation_ap50": detector.validationMetrics.averagePrecision.IoU50,
                "parameters": "\(detector.modelParameters)",
            ]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            exit(0)
        } catch {
            fail("could not write model: \(error)")
        }
    }
).store(in: &bag)

withExtendedLifetime(watcher) { RunLoop.main.run() }
