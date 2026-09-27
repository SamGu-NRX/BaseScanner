import Foundation

/// An HTTP answer: status and body.
public struct PacketHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    var bodyText: String { String(decoding: body.prefix(300), as: UTF8.self) }
}

/// How a file reaches its upload target. The app uses a background session; the tests use
/// `URLSessionPacketTransport` over a URLProtocol mock. HTTP error statuses come back as
/// responses; only transport failures throw.
public protocol PacketUploadTransport: Sendable {
    /// `file` as the whole body of `request`. `key` names the file across launches, so a
    /// transport that outlives the process (a background session) can hand back a transfer a
    /// previous launch started. `progress` gets the bytes of this file sent so far.
    func upload(_ request: URLRequest, file: URL, key: String, progress: @escaping @Sendable (Int) -> Void) async throws -> PacketHTTPResponse
}

/// Uploads on one ordinary `URLSession`, with its async API.
public struct URLSessionPacketTransport: PacketUploadTransport {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func upload(_ request: URLRequest, file: URL, key _: String, progress: @escaping @Sendable (Int) -> Void) async throws -> PacketHTTPResponse {
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: ProgressDelegate(progress))
        return PacketHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        let progress: @Sendable (Int) -> Void
        init(_ progress: @escaping @Sendable (Int) -> Void) { self.progress = progress }
        func urlSession(_: URLSession, task _: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64, totalBytesExpectedToSend _: Int64) {
            progress(Int(totalBytesSent))
        }
    }
}

public enum PacketUploadEvent: Sendable, Equatable {
    case sending(PacketUploadProgress)
    /// A call failed in a way a retry can fix; the next try is `after` seconds away.
    case waiting(PacketUploadProgress, after: Double)
}

public enum PacketUploadResult: Sendable, Equatable {
    /// No intake: nothing was sent.
    case disabled
    /// No consent: nothing was sent.
    case notConsented
    case sent(reference: String?)
    case failed(PacketUploadFailure)
    /// The run was stopped (start over, or a retry replacing it). The saved state resumes it.
    case cancelled
}

/// Sends a packet through a `PacketIntake`: `begin`, an upload per file not stored, `commit`,
/// `finish`; `begin` again when targets are refused or expire, and when the server says files
/// are missing. Files go up all at once, because a background session only carries on with
/// transfers already handed to it while the app is suspended. Plain logic over the intake and
/// the transport, with the clock and the waits injected.
public actor PacketUploader {
    private let intake: (any PacketIntake)?
    private let transport: any PacketUploadTransport
    private let policy: PacketUploadRetryPolicy
    private let now: @Sendable () -> Date
    private let wait: @Sendable (Double) async throws -> Void

    private var state: PacketUploadState?
    private var folder: URL?
    private var persist: (@Sendable (PacketUploadState) async -> Void)?
    private var events: (@Sendable (PacketUploadEvent) -> Void)?
    private var inFlight: [String: Int] = [:]

    public nonisolated let isEnabled: Bool

    /// `intake` nil means no server is selected: every call returns `.disabled` and sends nothing.
    public init(
        intake: (any PacketIntake)?, transport: any PacketUploadTransport, policy: PacketUploadRetryPolicy = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        wait: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.intake = intake
        isEnabled = intake != nil
        self.transport = transport
        self.policy = policy
        self.now = now
        self.wait = wait
    }

    /// Starts sending `packet`, read from `folder`. Without an intake or a consent nothing is
    /// sent and `persist` is never called.
    public func send(
        _ packet: PacketUploadPacket, scanID: String, consent: PacketUploadConsent?, folder: URL,
        persist: @escaping @Sendable (PacketUploadState) async -> Void, events: @escaping @Sendable (PacketUploadEvent) -> Void
    ) async -> PacketUploadResult {
        guard intake != nil else { return .disabled }
        guard let consent else { return .notConsented }
        let request = PacketIntakeRequest(
            packetVersion: packet.packetVersion, scanID: scanID, sceneSHA256: packet.sceneSHA256, consent: consent, files: packet.files)
        return await resume(PacketUploadState(request: request), folder: folder, persist: persist, events: events)
    }

    /// Carries on with a saved upload: `begin` again, then whatever the server doesn't have.
    public func resume(
        _ saved: PacketUploadState, folder: URL,
        persist: @escaping @Sendable (PacketUploadState) async -> Void, events: @escaping @Sendable (PacketUploadEvent) -> Void
    ) async -> PacketUploadResult {
        guard let intake else { return .disabled }
        switch saved.phase {
        case .complete: return .sent(reference: saved.reference)
        case .failed, .sending: break
        }
        var start = saved
        start.phase = .sending
        state = start
        self.folder = folder
        self.persist = persist
        self.events = events
        inFlight = [:]
        await save()
        let result = await loop(intake)
        switch result {
        case .sent(let reference):
            state?.phase = .complete
            state?.reference = reference
            await save()
        case .failed(let failure):
            state?.phase = .failed(failure)
            await save()
        case .cancelled, .disabled, .notConsented:
            break
        }
        return result
    }

    // MARK: The loop

    private func loop(_ intake: any PacketIntake) async -> PacketUploadResult {
        var refreshes = 0
        while true {
            if Task.isCancelled { return .cancelled }
            guard let request = state?.request else { return .cancelled }
            let resuming = state?.session?.id
            let session: PacketIntakeSession
            switch await call("begin", { () async throws(PacketIntakeError) in try await intake.begin(request, resuming: resuming) }) {
            case .success(let opened): session = opened
            case .failure(.sessionGone):
                // Nothing to resume: open a new session.
                state?.session = nil
                refreshes += 1
                guard refreshes <= policy.maxRefreshes else { return .failed(.gaveUp(step: "begin", detail: "the session kept disappearing")) }
                continue
            case .failure(let stop): return stop.result
            }
            let paths = Set(request.files.map(\.path))
            state?.session = session
            state?.stored = session.stored.intersection(paths)
            await save()
            report()

            let stored = state?.stored ?? []
            let targets = session.targets.filter { paths.contains($0.path) && !stored.contains($0.path) }
            if !targets.isEmpty {
                if let expiry = session.expiresAt, expiry.timeIntervalSince(now()) <= policy.expiryMargin {
                    refreshes += 1
                    guard refreshes <= policy.maxRefreshes else {
                        return .failed(.gaveUp(step: "begin", detail: "every session's targets expire at \(expiry), before they can be used"))
                    }
                    continue
                }
                let round = await putAll(targets, expiresAt: session.expiresAt)
                if case .stop(let stop) = round { return stop.result }
                var progressed = false
                var resend = false
                let uploaded = (state?.stored ?? []).subtracting(stored)
                if !uploaded.isEmpty {
                    switch await call("commit", { () async throws(PacketIntakeError) in try await intake.commit(uploaded, in: session) }) {
                    case .success(let taken):
                        progressed = !taken.isEmpty
                        let refused = uploaded.subtracting(taken)
                        if !refused.isEmpty {
                            if let stop = await missing(refused, step: "commit") { return stop.result }
                            resend = true
                        }
                    case .failure(.sessionGone):
                        // `begin` says again which of these the server kept.
                        state?.session = nil
                        resend = true
                    case .failure(let stop):
                        return stop.result
                    }
                }
                refreshes = progressed ? 0 : refreshes
                if case .refresh = round {
                    if !progressed { refreshes += 1 }
                    guard refreshes <= policy.maxRefreshes else {
                        return .failed(.gaveUp(step: "upload", detail: "the targets kept being refused (401, 403 or expired)"))
                    }
                    continue
                }
                if resend { continue }
            }

            switch await call("finish", { () async throws(PacketIntakeError) in try await intake.finish(session) }) {
            case .success(.complete(let reference)):
                return .sent(reference: reference)
            case .success(.missing(let missingPaths)):
                if let stop = await missing(missingPaths, step: "finish") { return stop.result }
            case .failure(.sessionGone):
                state?.session = nil
                refreshes += 1
                guard refreshes <= policy.maxRefreshes else { return .failed(.gaveUp(step: "finish", detail: "the session kept disappearing")) }
            case .failure(let stop):
                return stop.result
            }
        }
    }

    /// The server says it lacks `paths`: they go back to unsent, up to the limit.
    private func missing(_ paths: Set<String>, step: String) async -> Stop? {
        state?.stored.subtract(paths)
        state?.incompleteAnswers += 1
        await save()
        guard (state?.incompleteAnswers ?? 0) <= policy.maxIncompleteAnswers else {
            return .fail(.gaveUp(step: step, detail: "still missing \(paths.sorted().joined(separator: ", "))"))
        }
        return nil
    }

    // MARK: File uploads

    private enum PutRound {
        case done
        case refresh
        case stop(Stop)
    }

    private enum PutOutcome: Sendable {
        case stored
        case refresh
        case stop(Stop)
    }

    private func putAll(_ targets: [PacketUploadTarget], expiresAt: Date?) async -> PutRound {
        await withTaskGroup(of: PutOutcome.self) { group in
            for target in targets {
                group.addTask { await self.put(target, expiresAt: expiresAt) }
            }
            var needsRefresh = false
            for await outcome in group {
                switch outcome {
                case .stored: break
                case .refresh: needsRefresh = true
                case .stop(let stop):
                    group.cancelAll()
                    return .stop(stop)
                }
            }
            return needsRefresh ? .refresh : .done
        }
    }

    /// One file until it is stored, needs a fresh target, or can't be sent. Network errors, 408,
    /// 429 and 5xx wait and try the same target again.
    private func put(_ target: PacketUploadTarget, expiresAt: Date?) async -> PutOutcome {
        guard let folder, let scanID = state?.scanID else { return .stop(.cancelled) }
        let step = "upload \(target.path)"
        var request = URLRequest(url: target.url)
        request.httpMethod = target.method
        // Exactly the given headers: a signed URL's signature covers them, and an API key must
        // never reach storage.
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        while true {
            if Task.isCancelled { return .stop(.cancelled) }
            let attempt = (state?.attempts[target.path] ?? 0) + 1
            state?.attempts[target.path] = attempt
            await save()
            let detail: String
            do {
                let response = try await transport.upload(request, file: folder.appending(path: target.path), key: "\(scanID)/\(target.path)") { [weak self] bytes in
                    Task { await self?.noteProgress(target.path, bytes) }
                }
                inFlight[target.path] = nil
                switch Self.classifyUpload(response, expired: expiresAt.map { now() >= $0 } ?? false) {
                case .stored:
                    state?.stored.insert(target.path)
                    await save()
                    report()
                    return .stored
                case .refresh:
                    return .refresh
                case .retry:
                    detail = "\(response.status) \(response.bodyText)"
                case .refused:
                    return .stop(.fail(.refused(step: step, detail: "\(response.status) \(response.bodyText)")))
                }
            } catch {
                inFlight[target.path] = nil
                if Task.isCancelled || error is CancellationError { return .stop(.cancelled) }
                detail = String(describing: error)
            }
            if case .failure(let stop) = await backOff(step: step, attempt: attempt, detail: detail) { return .stop(stop) }
        }
    }

    enum UploadClass: Equatable {
        case stored
        case refresh
        case retry
        case refused
    }

    /// 2xx stored; 401, 403 or an expired target means `begin` again for a fresh one. An expired
    /// signed URL can also answer 400 (Google Cloud Storage says "ExpiredToken"), so a 400 after
    /// `expiresAt`, or one whose body says the URL expired, counts as expired too. 408, 429 and
    /// 5xx retry the same target.
    static func classifyUpload(_ response: PacketHTTPResponse, expired: Bool) -> UploadClass {
        switch response.status {
        case 200..<300: return .stored
        case 401, 403: return .refresh
        case 400 where expired || response.bodyText.localizedCaseInsensitiveContains("expired"): return .refresh
        case 408, 429, 500..<600: return .retry
        default: return expired ? .refresh : .refused
        }
    }

    // MARK: Intake calls and waits

    enum Stop: Error, Sendable {
        case cancelled
        case sessionGone
        case fail(PacketUploadFailure)

        var result: PacketUploadResult {
            switch self {
            case .cancelled: .cancelled
            case .sessionGone: .failed(.gaveUp(step: "intake", detail: "the session is gone"))
            case .fail(let failure): .failed(failure)
            }
        }
    }

    /// An intake call, tried again with backoff while it fails transiently.
    private func call<T: Sendable>(_ step: String, _ body: () async throws(PacketIntakeError) -> T) async -> Result<T, Stop> {
        var attempt = 0
        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            attempt += 1
            let detail: String
            do {
                return .success(try await body())
            } catch {
                switch error {
                case .transient(let reason): detail = reason
                case .refused(let reason): return .failure(.fail(.refused(step: step, detail: reason)))
                case .sessionGone: return .failure(.sessionGone)
                }
            }
            if Task.isCancelled { return .failure(.cancelled) }
            if case .failure(let stop) = await backOff(step: step, attempt: attempt, detail: detail) { return .failure(stop) }
        }
    }

    /// Waits before try `attempt + 1`, or stops once `attempt` reached the limit.
    private func backOff(step: String, attempt: Int, detail: String) async -> Result<Void, Stop> {
        guard attempt < policy.maxAttempts else { return .failure(.fail(.gaveUp(step: step, detail: detail))) }
        let delay = policy.delay(afterAttempt: attempt)
        if let state { events?(.waiting(state.progress(inFlight: inFlightBytes), after: delay)) }
        do {
            try await wait(delay)
        } catch {
            return .failure(.cancelled)
        }
        report()
        return .success(())
    }

    // MARK: Progress and saving

    private var inFlightBytes: Int { inFlight.values.reduce(0, +) }

    private func noteProgress(_ path: String, _ bytes: Int) {
        guard state?.stored.contains(path) == false else { return }
        inFlight[path] = bytes
        report()
    }

    private func report() {
        guard let state else { return }
        events?(.sending(state.progress(inFlight: inFlightBytes)))
    }

    private func save() async {
        guard let state, let persist else { return }
        await persist(state)
    }
}
