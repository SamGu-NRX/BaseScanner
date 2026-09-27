import Foundation

/// One packet's upload, as saved next to the packet (`fileName` in the scan folder) after every
/// change, so a relaunch picks it up where it was. The server stays the authority on what is
/// stored: every run starts with `PacketIntake.begin`, whose `stored` replaces `stored` here.
public struct PacketUploadState: Codable, Sendable, Equatable {
    public static let fileName = "packet-upload.json"

    public enum Phase: Codable, Sendable, Equatable {
        case sending
        case complete
        /// Stopped: `refused` answers won't change on a retry; others may.
        case failed(PacketUploadFailure)
    }

    /// What `begin` sends, consent included: a state can't exist without the homeowner's yes.
    public var request: PacketIntakeRequest
    public var phase: Phase = .sending
    /// The last session `begin` opened; its id resumes it.
    public var session: PacketIntakeSession?
    public var stored: Set<String> = []
    /// Uploads tried per file, across launches; the backoff grows with it.
    public var attempts: [String: Int] = [:]
    /// Times the server said files were missing (`finish`) or not taken (`commit`).
    public var incompleteAnswers = 0
    /// What the server named the finished packet by.
    public var reference: String?

    public init(request: PacketIntakeRequest) {
        self.request = request
    }

    public var scanID: String { request.scanID }

    public func progress(inFlight: Int = 0) -> PacketUploadProgress {
        let sent = request.files.filter { stored.contains($0.path) }
        return PacketUploadProgress(
            filesSent: sent.count, filesTotal: request.files.count,
            bytesSent: min(sent.reduce(0) { $0 + $1.bytes } + inFlight, totalBytes), bytesTotal: totalBytes)
    }

    public var totalBytes: Int { request.files.reduce(0) { $0 + $1.bytes } }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> PacketUploadState {
        try JSONDecoder().decode(PacketUploadState.self, from: Data(contentsOf: url))
    }
}

public struct PacketUploadProgress: Sendable, Equatable {
    public var filesSent: Int
    public var filesTotal: Int
    public var bytesSent: Int
    public var bytesTotal: Int

    public init(filesSent: Int, filesTotal: Int, bytesSent: Int, bytesTotal: Int) {
        self.filesSent = filesSent
        self.filesTotal = filesTotal
        self.bytesSent = bytesSent
        self.bytesTotal = bytesTotal
    }

    public var fraction: Double { bytesTotal > 0 ? Double(bytesSent) / Double(bytesTotal) : 0 }
}

/// Why an upload stopped.
public enum PacketUploadFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    /// Refused at `step`: sending the same thing again gets the same answer.
    case refused(step: String, detail: String)
    /// Network errors or retryable answers until the retry limit.
    case gaveUp(step: String, detail: String)
    /// The packet on disk can't be read, or no longer matches its manifest.
    case packetChanged(String)

    public var description: String {
        switch self {
        case .refused(let step, let detail): "\(step) refused: \(detail)"
        case .gaveUp(let step, let detail): "\(step) kept failing: \(detail)"
        case .packetChanged(let detail): "packet unreadable: \(detail)"
        }
    }

    /// Whether a later run could succeed without anything changing on the phone.
    public var isTransient: Bool {
        if case .gaveUp = self { true } else { false }
    }
}

/// How hard the phone tries. None of these numbers comes from a measurement: they are guesses
/// for a phone on a home's Wi-Fi or on cellular outdoors, to revisit once the server exists.
public struct PacketUploadRetryPolicy: Sendable, Equatable {
    /// Seconds before the first retry, doubling each time up to `maxDelay`.
    public var firstDelay: Double = 2
    public var maxDelay: Double = 60
    /// Tries per file upload and per intake call before the upload stops as failed.
    public var maxAttempts = 6
    /// `begin` repeated for fresh targets (401, 403, expired, or the session gone) with no file
    /// stored since.
    public var maxRefreshes = 4
    /// Answers naming files missing before the upload stops: a server that keeps losing them.
    public var maxIncompleteAnswers = 3
    /// URLs this close to `expires_at` count as expired and are fetched again first.
    public var expiryMargin: Double = 30

    public init() {}

    /// Seconds to wait after the `attempt`-th try failed (1-based): 2, 4, 8, 16, 32, 60, 60...
    public func delay(afterAttempt attempt: Int) -> Double {
        min(maxDelay, firstDelay * pow(2, Double(max(attempt, 1) - 1)))
    }
}
