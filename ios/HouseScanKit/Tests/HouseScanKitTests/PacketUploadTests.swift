import CryptoKit
import Foundation
@testable import HouseScanKit
import Testing

// MARK: - Test doubles: storage behind URLProtocol, and an intake that signs URLs to it

/// Storage that takes PUTs in memory, reached through `FakePacketProtocol` on its own host name so
/// tests can run in parallel. It never touches the network. Its log also records the mock
/// intake's calls, so tests can check their order against the uploads.
final class FakeStorage: @unchecked Sendable {
    enum PutBehavior {
        case store
        case status(Int, String)
        case networkError
        /// A network error once `ready` is true: a file failing after the ones before it went up.
        case networkErrorOnce(ready: @Sendable () -> Bool)
        /// No answer until the request is cancelled.
        case hang
    }

    struct Logged: Equatable {
        var call: String
        var path: String = ""
        var generation: Int = 0
        var headers: [String: String] = [:]
    }

    let host = "storage-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var _log: [Logged] = []
    private var _stored: [String: Data] = [:]
    private var puts: [String: Int] = [:]

    /// Answers each PUT by file path and the how-manieth PUT of that file it is (1-based).
    var putBehavior: @Sendable (String, Int) -> PutBehavior = { _, _ in .store }

    var log: [Logged] { lock.withLock { _log } }
    var storedPaths: Set<String> { lock.withLock { Set(_stored.keys) } }
    func stored(_ path: String) -> Data? { lock.withLock { _stored[path] } }
    func drop(_ path: String) { _ = lock.withLock { _stored.removeValue(forKey: path) } }
    func note(_ call: String) { lock.withLock { _log.append(Logged(call: call)) } }

    init() { FakePacketProtocol.register(self) }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakePacketProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: configuration)
    }

    func url(generation: Int, path: String) -> URL {
        URL(string: "https://\(host)/bucket/g\(generation)/\(path)")!
    }

    enum Answer {
        case response(Int, Data)
        case error(URLError)
        case hang
        case errorWhen(@Sendable () -> Bool, URLError)
    }

    func handle(_ request: URLRequest, body: Data) -> Answer {
        // /bucket/g<generation>/<file path>
        let parts = (request.url?.path() ?? "").split(separator: "/", maxSplits: 2).map(String.init)
        guard request.httpMethod == "PUT", parts.count == 3, parts[0] == "bucket" else { return .response(404, Data()) }
        let path = parts[2]
        let count = lock.withLock { () -> Int in
            _log.append(Logged(call: "PUT", path: path, generation: Int(parts[1].dropFirst()) ?? 0, headers: request.allHTTPHeaderFields ?? [:]))
            puts[path, default: 0] += 1
            return puts[path] ?? 0
        }
        switch putBehavior(path, count) {
        case .store:
            lock.withLock { _stored[path] = body }
            return .response(200, Data())
        case .status(let status, let text):
            return .response(status, Data(text.utf8))
        case .networkError:
            return .error(URLError(.networkConnectionLost))
        case .networkErrorOnce(let ready):
            return .errorWhen(ready, URLError(.networkConnectionLost))
        case .hang:
            return .hang
        }
    }

    /// File paths PUT, in order, from log entry `from` on.
    func putPaths(from: Int = 0) -> [String] {
        log.dropFirst(from).filter { $0.call == "PUT" }.map(\.path)
    }
}

/// An intake for tests only: it signs URLs to `FakeStorage` and counts a file stored once the
/// storage holds its exact bytes. It stands for no real server's API.
actor MockIntake: PacketIntake {
    let storage: FakeStorage
    private var generation = 0
    private var finishes = 0
    private(set) var requests: [PacketIntakeRequest] = []
    private(set) var resumed: [String?] = []
    /// Seconds from now to `expiresAt`, by `begin` call (1-based).
    var expiry: @Sendable (Int) -> Double = { _ in 3600 }
    /// Paths the server drops right before answering the `finish` call with this number.
    var losesOnFinish: @Sendable (Int) -> [String] = { _ in [] }
    /// Errors `begin` throws, by call number, before answering.
    var beginError: @Sendable (Int) -> PacketIntakeError? = { _ in nil }

    init(storage: FakeStorage) { self.storage = storage }

    func set(expiry: @escaping @Sendable (Int) -> Double = { _ in 3600 }, losesOnFinish: @escaping @Sendable (Int) -> [String] = { _ in [] },
             beginError: @escaping @Sendable (Int) -> PacketIntakeError? = { _ in nil }) {
        self.expiry = expiry
        self.losesOnFinish = losesOnFinish
        self.beginError = beginError
    }

    private func holds(_ file: PacketUploadFile) -> Bool {
        guard let data = storage.stored(file.path) else { return false }
        return data.count == file.bytes && PacketFiles.sha256(data) == file.sha256
    }

    func begin(_ request: PacketIntakeRequest, resuming: String?) async throws(PacketIntakeError) -> PacketIntakeSession {
        generation += 1
        storage.note("begin")
        requests.append(request)
        resumed.append(resuming)
        if let error = beginError(generation) { throw error }
        let stored = Set(request.files.filter(holds).map(\.path))
        let targets = request.files.filter { !stored.contains($0.path) }.map { file in
            PacketUploadTarget(path: file.path, url: storage.url(generation: generation, path: file.path), headers: ["Content-Type": file.contentType])
        }
        return PacketIntakeSession(id: "session-1", expiresAt: Date().addingTimeInterval(expiry(generation)), stored: stored, targets: targets)
    }

    func commit(_ paths: Set<String>, in _: PacketIntakeSession) async throws(PacketIntakeError) -> Set<String> {
        storage.note("commit")
        guard let files = requests.last?.files else { return [] }
        return Set(files.filter { paths.contains($0.path) && holds($0) }.map(\.path))
    }

    func finish(_: PacketIntakeSession) async throws(PacketIntakeError) -> PacketIntakeFinish {
        finishes += 1
        storage.note("finish")
        for path in losesOnFinish(finishes) { storage.drop(path) }
        let missing = (requests.last?.files ?? []).filter { !holds($0) }.map(\.path)
        return missing.isEmpty ? .complete(reference: "r-1") : .missing(Set(missing))
    }
}

final class FakePacketProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: FakeStorage] = [:]
    private static let lock = NSLock()

    static func register(_ server: FakeStorage) { lock.withLock { servers[server.host] = server } }
    private static func server(_ host: String?) -> FakeStorage? { lock.withLock { host.flatMap { servers[$0] } } }

    override class func canInit(with request: URLRequest) -> Bool { server(request.url?.host()) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(request.url?.host()) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch server.handle(request, body: Self.body(of: request)) {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang:
            break
        case .errorWhen(let ready, let error):
            fail(when: ready, error)
        }
    }

    private func fail(when ready: @escaping @Sendable () -> Bool, _ error: URLError) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [self] in
            if ready() {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                fail(when: ready, error)
            }
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Saved states, in order, and the waits asked for.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [PacketUploadState] = []
    private var _waits: [Double] = []
    var states: [PacketUploadState] { lock.withLock { _states } }
    var waits: [Double] { lock.withLock { _waits } }
    func save(_ state: PacketUploadState) { lock.withLock { _states.append(state) } }
    func waited(_ seconds: Double) { lock.withLock { _waits.append(seconds) } }
}

// MARK: - Tests

@Suite struct PacketUploadTests {
    private static let consent = PacketUploadConsent(grantedAt: Date(timeIntervalSince1970: 1_790_470_923), textID: "packet-consent-1")
    private static let scanID = "3f1c0000-0000-0000-0000-000000000001"

    /// A finished synthetic packet (PacketWriterTests' `SyntheticPacket`) in a fresh folder.
    private func writePacket() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        let jpegs = root.appending(path: "jpegs")
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        return try SyntheticPacket().write(to: root.appending(path: "packet"), jpegs: jpegs)
    }

    private func uploader(_ intake: MockIntake?, _ storage: FakeStorage, recorder: Recorder,
                          wait: (@Sendable (Double) async throws -> Void)? = nil) -> PacketUploader {
        PacketUploader(intake: intake, transport: URLSessionPacketTransport(session: storage.session()), wait: wait ?? { recorder.waited($0) })
    }

    private func send(_ uploader: PacketUploader, _ packet: PacketUploadPacket, folder: URL,
                      consent: PacketUploadConsent? = PacketUploadTests.consent, recorder: Recorder) async -> PacketUploadResult {
        await uploader.send(packet, scanID: Self.scanID, consent: consent, folder: folder, persist: { recorder.save($0) }, events: { _ in })
    }

    private struct Setup {
        var storage = FakeStorage()
        var recorder = Recorder()
        var folder: URL
        var packet: PacketUploadPacket
        var intake: MockIntake
    }

    private func setup() throws -> Setup {
        let folder = try writePacket()
        let storage = FakeStorage()
        return Setup(storage: storage, folder: folder, packet: try PacketUploadPacket.read(folder: folder), intake: MockIntake(storage: storage))
    }

    // MARK: File list

    @Test func fileListMatchesTheManifestAndTheDisk() throws {
        let folder = try writePacket()
        let packet = try PacketUploadPacket.read(folder: folder)
        let manifestData = try Data(contentsOf: folder.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(PacketManifest.self, from: manifestData)

        #expect(packet.files.first == PacketUploadFile(
            path: "manifest.json", bytes: manifestData.count, sha256: sha256Hex(manifestData), contentType: "application/json"))
        // Every other file is one the manifest lists, with its size and hash, and so is the disk.
        let listed = Dictionary(PacketUploadPacket.listedFiles(manifest).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(packet.files.count == listed.count + 1)
        for file in packet.files.dropFirst() {
            let entry = try #require(listed[file.path], "\(file.path) is not in the manifest")
            #expect(file.bytes == entry.bytes && file.sha256 == entry.sha256, "\(file.path)")
            let data = try Data(contentsOf: folder.appending(path: file.path))
            #expect(file.bytes == data.count && file.sha256 == sha256Hex(data), "\(file.path) on disk")
        }
        // Nothing in the folder is left out.
        #expect(Set(packet.files.map(\.path)) == (try regularFiles(in: folder)))
        #expect(packet.sceneSHA256 == manifest.scene?.sha256)
        #expect(packet.sceneSHA256 == sha256Hex(try Data(contentsOf: folder.appending(path: "scene.json"))))
        #expect(packet.photoCount == 3 && packet.has3DData && packet.packetVersion == "1.1")
        #expect(packet.files.first { $0.path.hasSuffix(".jpg") }?.contentType == "image/jpeg")
        #expect(packet.files.first { $0.path.hasSuffix(".csv") }?.contentType == "text/csv")
        #expect(packet.files.first { $0.path.hasSuffix(".ply") }?.contentType == "application/octet-stream")
        #expect(try PacketUploadPacket.summary(folder: folder) == PacketUploadSummary(photos: 3, bytes: packet.totalBytes))
    }

    @Test func aFileThatNoLongerMatchesItsManifestEntryIsRefused() throws {
        let folder = try writePacket()
        let photo = try #require(try PacketUploadPacket.read(folder: folder).files.first { $0.path.hasSuffix(".jpg") })
        try Data("not the photo".utf8).write(to: folder.appending(path: photo.path))
        #expect(throws: PacketUploadPacket.ReadError.self) { try PacketUploadPacket.read(folder: folder) }
        try FileManager.default.removeItem(at: folder.appending(path: photo.path))
        #expect(throws: PacketUploadPacket.ReadError.missing(photo.path)) { try PacketUploadPacket.read(folder: folder) }
    }

    @Test func pathsMustStayInsideThePacket() {
        #expect(PacketUploadPacket.isInside("photos/p00001.jpg"))
        for path in ["", "/etc/passwd", "../x", "photos/../../x", "photos//p.jpg", "./p.jpg", "a\\b"] {
            #expect(!PacketUploadPacket.isInside(path), "\(path)")
        }
    }

    // MARK: Configuration and consent

    @Test func noEndpointOrNoIntakeMeansDisabledAndNothingSent() async throws {
        for text in [nil, "", "  ", "$(HOUSESCAN_PACKET_UPLOAD_URL)", "ftp://example.com", "https://"] as [String?] {
            #expect(PacketUploadEndpoint(baseURL: text) == nil, "\(text ?? "nil")")
        }
        #expect(PacketUploadEndpoint(baseURL: "https://x.test", bearerKey: "$(HOUSESCAN_PACKET_UPLOAD_KEY)")?.bearerKey == nil)
        #expect(PacketUploadEndpoint(baseURL: "https://x.test", bearerKey: " k ")?.bearerKey == "k")

        let s = try setup()
        let disabled = uploader(nil, s.storage, recorder: s.recorder)
        #expect(!disabled.isEnabled)
        #expect(await send(disabled, s.packet, folder: s.folder, recorder: s.recorder) == .disabled)
        let saved = PacketUploadState(request: PacketIntakeRequest(
            packetVersion: "1.1", scanID: "s", sceneSHA256: "x", consent: Self.consent, files: s.packet.files))
        #expect(await disabled.resume(saved, folder: s.folder, persist: { s.recorder.save($0) }, events: { _ in }) == .disabled)
        #expect(s.storage.log.isEmpty)
        #expect(s.recorder.states.isEmpty)
    }

    @Test func consentOffSendsNothing() async throws {
        let form = PacketConsentForm()
        #expect(!form.agreed && !form.canSend)
        #expect(form.consent(at: Date()) == nil)

        let s = try setup()
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder,
                                consent: form.consent(at: Date()), recorder: s.recorder)
        #expect(result == .notConsented)
        #expect(s.storage.log.isEmpty, "no intake call and no upload")
        #expect(await s.intake.requests.isEmpty)
        #expect(s.recorder.states.isEmpty)

        var agreed = form
        agreed.agreed = true
        let time = Date(timeIntervalSince1970: 1_790_470_923)
        #expect(agreed.canSend)
        #expect(agreed.consent(at: time) == PacketUploadConsent(grantedAt: time, textID: "packet-consent-1"))
    }

    /// Editing the consent text without a new id would record a yes to words no one saw.
    @Test func consentWordingIsPinnedToItsID() {
        let wording = PacketConsentWording.current
        #expect(wording.id == "packet-consent-1")
        #expect(wording.fingerprint == "d43cc93d46e3a35c211c68941c1e1b80cc6973380c240f23b53491a53f1f03c4",
                "the consent wording changed: give it a new id (packet-consent-2) and pin its fingerprint, \(wording.fingerprint)")
    }

    // MARK: Uploads

    @Test func sendsEveryFileThenFinishes() async throws {
        let s = try setup()
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        #expect(result == .sent(reference: "r-1"))
        #expect(s.storage.storedPaths == Set(s.packet.files.map(\.path)))
        for file in s.packet.files {
            #expect(s.storage.stored(file.path) == (try Data(contentsOf: s.folder.appending(path: file.path))), "\(file.path) bytes")
        }
        let calls = s.storage.log.map(\.call)
        #expect(calls.first == "begin" && Array(calls.suffix(2)) == ["commit", "finish"])
        let putCount: Int = calls.filter { $0 == "PUT" }.count
        #expect(putCount == s.packet.files.count)
        // Each upload carries exactly the target's headers, and never an API key.
        let puts = s.storage.log.filter { $0.call == "PUT" }
        #expect(puts.allSatisfy { $0.headers["Authorization"] == nil })
        #expect(puts.filter { $0.path.hasSuffix(".jpg") }.allSatisfy { $0.headers["Content-Type"] == "image/jpeg" })
        let request = try #require(await s.intake.requests.first)
        #expect(request.consent == Self.consent && request.scanID == Self.scanID)
        #expect(request.sceneSHA256 == s.packet.sceneSHA256 && request.files == s.packet.files)
        #expect(s.recorder.states.last?.phase == .complete && s.recorder.states.last?.reference == "r-1")
    }

    /// One file fails mid-way and the app dies while the later files are still going: the next
    /// launch begins again from the saved state (resuming the same session) and sends only that
    /// file and the later ones.
    @Test(.timeLimit(.minutes(1))) func resumesAfterAnInterruptedFile() async throws {
        let s = try setup()
        let order = s.packet.files.map(\.path)
        let broken = order[order.count / 2]
        let later = Set(order.drop { $0 != broken })
        let earlier = Set(order.prefix { $0 != broken })
        s.storage.putBehavior = { [storage = s.storage] path, count in
            if count > 1 { return .store }
            if path == broken { return .networkErrorOnce { storage.storedPaths == earlier } }
            return later.contains(path) ? .hang : .store
        }
        // The first wait, before retrying the broken file, is where the process dies.
        let first = uploader(s.intake, s.storage, recorder: s.recorder, wait: { _ in throw CancellationError() })
        #expect(await send(first, s.packet, folder: s.folder, recorder: s.recorder) == .cancelled)
        #expect(s.storage.storedPaths == earlier)

        // The next launch: the saved state, read back from disk.
        let file = s.folder.deletingLastPathComponent().appending(path: PacketUploadState.fileName)
        try #require(s.recorder.states.last).save(to: file)
        let saved = try PacketUploadState.load(from: file)
        #expect(saved.attempts[broken] == 1 && saved.session?.id == "session-1")
        let logged = s.storage.log.count
        let second = uploader(s.intake, s.storage, recorder: s.recorder)
        let result = await second.resume(saved, folder: s.folder, persist: { s.recorder.save($0) }, events: { _ in })
        #expect(result == .sent(reference: "r-1"))
        #expect(s.storage.log.dropFirst(logged).first?.call == "begin", "a fresh begin comes first")
        #expect(await s.intake.resumed.last == "session-1", "the relaunch resumes the saved session")
        #expect(Set(s.storage.putPaths(from: logged)) == later)
        #expect(s.storage.putPaths(from: logged).count == later.count, "each remaining file once")
        #expect(s.storage.storedPaths == Set(order))
    }

    /// 403 on an upload, and targets that expire before use: both go back to `begin` for fresh
    /// targets, and only the files not yet stored are sent again.
    @Test func refusedOrExpiredTargetsBeginAgain() async throws {
        let s = try setup()
        let target = try #require(s.packet.files.last?.path)
        // The first session's targets have already expired; the second's work except `target`'s,
        // whose signature storage refuses once.
        await s.intake.set(expiry: { call in call == 1 ? -10 : 3600 })
        s.storage.putBehavior = { path, count in path == target && count == 1 ? .status(403, "SignatureDoesNotMatch") : .store }
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        #expect(result == .sent(reference: "r-1"))
        let log = s.storage.log
        let begins: Int = log.filter { $0.call == "begin" }.count
        #expect(begins == 3)
        #expect(!log.contains { $0.call == "PUT" && $0.generation == 1 }, "an expired target was used")
        let thirdRound: [String] = log.filter { $0.call == "PUT" && $0.generation == 3 }.map(\.path)
        #expect(thirdRound == [target])
        let puts: Int = s.storage.putPaths().count
        #expect(puts == s.packet.files.count + 1)
    }

    @Test func uploadAnswerClassification() {
        func answer(_ status: Int, _ body: String = "") -> PacketHTTPResponse { PacketHTTPResponse(status: status, body: Data(body.utf8)) }
        #expect(PacketUploader.classifyUpload(answer(200), expired: false) == .stored)
        #expect(PacketUploader.classifyUpload(answer(401), expired: false) == .refresh)
        #expect(PacketUploader.classifyUpload(answer(400, "<Code>ExpiredToken</Code>"), expired: false) == .refresh)
        #expect(PacketUploader.classifyUpload(answer(400, "bad"), expired: true) == .refresh)
        #expect(PacketUploader.classifyUpload(answer(400, "bad"), expired: false) == .refused)
        for status in [408, 429, 500, 503] {
            #expect(PacketUploader.classifyUpload(answer(status), expired: false) == .retry)
        }
        #expect(PacketIntakeError.classify(status: 201, body: "") == nil)
        #expect(PacketIntakeError.classify(status: 404, body: "") == .sessionGone)
        #expect(PacketIntakeError.classify(status: 503, body: "busy") == .transient("503 busy"))
        #expect(PacketIntakeError.classify(status: 413, body: "too big") == .refused("413 too big"))
    }

    /// 5xx and network errors retry the same file with growing waits; nothing else is re-sent.
    @Test func serverErrorsRetryTheFileWithBackoff() async throws {
        let s = try setup()
        let target = try #require(s.packet.files.dropFirst().first?.path)
        s.storage.putBehavior = { path, count in
            guard path == target else { return .store }
            return count == 1 ? .status(503, "busy") : count == 2 ? .networkError : .store
        }
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        #expect(result == .sent(reference: "r-1"))
        #expect(s.recorder.waits == [2, 4])
        let targetPuts: Int = s.storage.putPaths().filter { $0 == target }.count
        let begins: Int = s.storage.log.filter { $0.call == "begin" }.count
        #expect(targetPuts == 3 && begins == 1)
    }

    /// A transient intake failure retries the call with the same backoff.
    @Test func transientIntakeErrorsRetry() async throws {
        let s = try setup()
        await s.intake.set(beginError: { call in call <= 2 ? .transient("503") : nil })
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        #expect(result == .sent(reference: "r-1"))
        #expect(s.recorder.waits == [2, 4])
    }

    @Test func stopsAfterTheRetryLimit() async throws {
        let s = try setup()
        let target = try #require(s.packet.files.first?.path)
        s.storage.putBehavior = { path, _ in path == target ? .status(500, "down") : .store }
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        let failure = PacketUploadFailure.gaveUp(step: "upload \(target)", detail: "500 down")
        #expect(result == .failed(failure))
        #expect(s.recorder.waits == [2, 4, 8, 16, 32])
        #expect(s.recorder.states.last?.phase == .failed(failure))
        #expect(!s.storage.log.contains { $0.call == "finish" })
    }

    @Test func refusedPacketStops() async throws {
        let s = try setup()
        let target = try #require(s.packet.files.first?.path)
        s.storage.putBehavior = { path, _ in path == target ? .status(413, "limit is 80 MB") : .store }
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        #expect(result == .failed(.refused(step: "upload \(target)", detail: "413 limit is 80 MB")))
        #expect(!PacketUploadFailure.refused(step: "", detail: "").isTransient)
        #expect(s.recorder.waits.isEmpty)
    }

    /// `finish` names a missing file: the uploader begins again, sends it and finishes again.
    @Test func missingFilesAreSentAgain() async throws {
        let s = try setup()
        let lost = try #require(s.packet.files.dropFirst(2).first?.path)
        await s.intake.set(losesOnFinish: { round in round == 1 ? [lost] : [] })
        let result = await send(uploader(s.intake, s.storage, recorder: s.recorder), s.packet, folder: s.folder, recorder: s.recorder)
        #expect(result == .sent(reference: "r-1"))
        let calls = s.storage.log.map { $0.call == "PUT" ? "PUT \($0.path)" : $0.call }
        let firstFinish = try #require(calls.firstIndex(of: "finish"))
        let afterFirstFinish: [String] = Array(calls[(firstFinish + 1)...])
        let expected: [String] = ["begin", "PUT \(lost)", "commit", "finish"]
        #expect(afterFirstFinish == expected)
        #expect(s.recorder.states.last?.incompleteAnswers == 1)
    }

    @Test func backoffDoublesUpToTheCap() {
        let policy = PacketUploadRetryPolicy()
        #expect((1...8).map(policy.delay(afterAttempt:)) == [2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test func savedStateRoundTrips() throws {
        var state = PacketUploadState(request: PacketIntakeRequest(
            packetVersion: "1.1", scanID: "scan", sceneSHA256: "abc", consent: Self.consent,
            files: [PacketUploadFile(path: "manifest.json", bytes: 10, sha256: "x", contentType: "application/json")]))
        state.session = PacketIntakeSession(id: "s", expiresAt: Date(timeIntervalSince1970: 1_790_474_523), stored: ["manifest.json"], targets: [])
        state.stored = ["manifest.json"]
        state.attempts = ["manifest.json": 2]
        state.phase = .failed(.gaveUp(step: "finish", detail: "d"))
        let url = FileManager.default.temporaryDirectory.appending(path: "state-\(UUID().uuidString).json")
        try state.save(to: url)
        #expect(try PacketUploadState.load(from: url) == state)
        #expect(state.progress() == PacketUploadProgress(filesSent: 1, filesTotal: 1, bytesSent: 10, bytesTotal: 10))
    }

    // MARK: Helpers

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func regularFiles(in folder: URL) throws -> Set<String> {
        let root = folder.standardizedFileURL.pathComponents.count
        var out = Set<String>()
        let walker = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.insert(url.standardizedFileURL.pathComponents.dropFirst(root).joined(separator: "/"))
        }
        return out
    }
}
