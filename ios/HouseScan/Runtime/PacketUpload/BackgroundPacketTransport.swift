import Foundation
import HouseScanKit
import OSLog
import Synchronization

/// How the packet's files leave the phone: an upload task per file, from the file, on a
/// background `URLSession`, so transfers carry on while the app is suspended, and after the
/// system ends it. The intake's own calls go through the adapter, not here.
///
/// A background session outlives the process: a relaunch re-creates it with the same identifier
/// and gets back the transfers still running, and the results of those that finished meanwhile.
/// Each task's `taskDescription` is the uploader's key ("<scan id>/<path>"), so a later request
/// for the same file joins the running transfer instead of sending the file twice, and a
/// transfer that finished with a 2xx while no one was waiting counts as sent.
final class BackgroundPacketTransport: NSObject, PacketUploadTransport, URLSessionDataDelegate, Sendable {
    static var identifier: String { "\(Bundle.main.bundleIdentifier ?? "dev.housescanning.housescan").packet-upload" }

    private struct Waiter {
        var continuation: CheckedContinuation<PacketHTTPResponse, any Error>
        var progress: @Sendable (Int) -> Void
    }

    private struct Registry {
        /// Transfers a previous launch started that are still running, by key.
        var running: [String: URLSessionUploadTask] = [:]
        var waiters: [Int: Waiter] = [:]
        var bodies: [Int: Data] = [:]
        /// Finished tasks no one waits for yet, by task identifier.
        var finished: [Int: Result<PacketHTTPResponse, any Error>] = [:]
        /// 2xx answers of transfers no one was waiting for, by key.
        var sentByKey: [String: PacketHTTPResponse] = [:]
    }

    private let registry = Mutex(Registry())
    /// Set once, in `init`; a background session keeps a strong reference to its delegate.
    nonisolated(unsafe) private var session: URLSession!
    nonisolated(unsafe) private var adopted: Task<Void, Never>!
    private let onEventsFinished: @Sendable () -> Void

    /// Creates the one background session of this process. Creating a second with the same
    /// identifier is an error, so `PacketUploadService` holds the only instance.
    init(onEventsFinished: @escaping @Sendable () -> Void) {
        self.onEventsFinished = onEventsFinished
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        // The homeowner asked for this now; don't let the system hold it for a charger and Wi-Fi.
        configuration.isDiscretionary = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let session = session!
        adopted = Task { [self] in
            let tasks = await session.allTasks
            registry.withLock { r in
                for case let task as URLSessionUploadTask in tasks where task.state == .running {
                    if let key = task.taskDescription { r.running[key] = task }
                }
            }
            RuntimeLog.engine.info("packet upload: \(tasks.count) transfers carried over from an earlier launch")
        }
    }

    func upload(_ request: URLRequest, file: URL, key: String, progress: @escaping @Sendable (Int) -> Void) async throws -> PacketHTTPResponse {
        await adopted.value
        enum Start { case sent(PacketHTTPResponse), task(URLSessionUploadTask) }
        let start = registry.withLock { r -> Start? in
            if let answer = r.sentByKey.removeValue(forKey: key) { return .sent(answer) }
            return r.running.removeValue(forKey: key).map(Start.task)
        }
        let task: URLSessionUploadTask
        switch start {
        case .sent(let answer)?:
            return answer
        case .task(let running)?:
            task = running
        case nil:
            task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = key
        }
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let done = registry.withLock { r -> Result<PacketHTTPResponse, any Error>? in
                    if let done = r.finished.removeValue(forKey: id) { return done }
                    r.waiters[id] = Waiter(continuation: continuation, progress: progress)
                    return nil
                }
                if let done {
                    continuation.resume(with: done)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels every transfer of a scan, running or carried over, for "Start over".
    func cancelTransfers(scanID: String) {
        let prefix = "\(scanID)/"
        registry.withLock { r in
            for key in r.running.keys where key.hasPrefix(prefix) { r.running.removeValue(forKey: key)?.cancel() }
            for key in r.sentByKey.keys where key.hasPrefix(prefix) { r.sentByKey.removeValue(forKey: key) }
        }
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(prefix) == true { task.cancel() }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        registry.withLock { $0.bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64, totalBytesExpectedToSend _: Int64) {
        let progress = registry.withLock { $0.waiters[task.taskIdentifier]?.progress }
        progress?(Int(totalBytesSent))
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let result: Result<PacketHTTPResponse, any Error>
        if let error {
            result = .failure(error)
        } else if let http = task.response as? HTTPURLResponse {
            result = .success(PacketHTTPResponse(status: http.statusCode, body: registry.withLock { $0.bodies[id] ?? Data() }))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        let waiter = registry.withLock { r -> Waiter? in
            r.bodies[id] = nil
            if let key = task.taskDescription { r.running[key] = nil }
            if let waiter = r.waiters.removeValue(forKey: id) { return waiter }
            r.finished[id] = result
            if case .success(let answer) = result, (200..<300).contains(answer.status), let key = task.taskDescription {
                r.sentByKey[key] = answer
            }
            return nil
        }
        waiter?.continuation.resume(with: result)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        onEventsFinished()
    }
}
