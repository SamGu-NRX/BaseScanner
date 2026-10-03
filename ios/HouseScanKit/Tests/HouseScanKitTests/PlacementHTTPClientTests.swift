import Foundation
import HouseScanKit
import Synchronization
import Testing

/// The placement client against a real HTTP server on 127.0.0.1, through `URLSession`: what it sends,
/// which replies it returns, and what each failure means for the homeowner
/// (`UploadFailureKind`). The answers are a real server answer to the synthetic replay, with its
/// input hash set per test.
@Suite struct PlacementHTTPClientTests {
    static let scene = Data(#"{"note":"the scene this phone sent"}"#.utf8)
    static let fixtureHash = "2cb165cd4d4e9340496d90a589678ccbbe8ae6720d9d73bcae427a6b22075cb7"

    static func answer(declaring hash: String?) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let line = "\"input_sha256\": \"\(fixtureHash)\","
        #expect(text.contains(line))
        return Data(text.replacingOccurrences(of: line, with: hash.map { "\"input_sha256\": \"\($0)\"," } ?? "").utf8)
    }

    static func client(_ server: LoopbackPlacementServer) -> PlacementHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return PlacementHTTPClient(serverURL: server.base, session: URLSession(configuration: configuration))
    }

    /// Submits `scene` and returns the error it threw, failing the test if it returned an answer.
    static func failure(of client: PlacementHTTPClient) async throws -> any Error {
        do {
            _ = try await client.submit(scene: scene) { _ in }
        } catch {
            return error
        }
        Issue.record("the client returned an answer")
        throw CancellationError()
    }

    /// An answer for the scene sent comes back byte for byte. The request is that scene, posted as
    /// JSON to /v1/placements, and progress ends at 1.
    @Test func anAnswerForTheSceneSentIsReturned() async throws {
        let server = try LoopbackPlacementServer { request in
            .init(status: 200, body: (try? Self.answer(declaring: PacketFiles.sha256(request.body))) ?? Data())
        }
        let progress = Mutex<[Double]>([])
        let data = try await Self.client(server).submit(scene: Self.scene) { value in progress.withLock { $0.append(value) } }

        #expect(data == (try Self.answer(declaring: PacketFiles.sha256(Self.scene))))
        #expect(try PlacementResult.decode(data).decision == .manualReview)
        let requests = server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.path == "/v1/placements")
        #expect(requests.first?.headers["content-type"] == "application/json")
        #expect(requests.first?.body == Self.scene)
        #expect(progress.withLock { $0.last } == 1)
    }

    /// An answer that names another scene is never returned. It is an answer House Scan couldn't
    /// use, which the homeowner may ask for again, and the client doesn't ask again on its own.
    @Test func anAnswerForAnotherSceneIsNotReturned() async throws {
        let other = PacketFiles.sha256(Data("another scene".utf8))
        let server = try LoopbackPlacementServer { _ in .init(status: 200, body: (try? Self.answer(declaring: other)) ?? Data()) }
        let error = try await Self.failure(of: Self.client(server))

        #expect(error as? ResultBinding.Refusal == .mismatch(submitted: PacketFiles.sha256(Self.scene), declared: other))
        #expect(UploadFailureKind.classify(error) == .unreadableAnswer)
        #expect(UploadFailureKind.classify(error).retryable)
        #expect(server.requests.count == 1)
    }

    /// A 2xx without a readable input hash, or one that isn't JSON at all, is also unusable.
    @Test(arguments: ["no hash", "not JSON"])
    func anAnswerWithoutItsSceneIsNotReturned(_ kind: String) async throws {
        let body = kind == "no hash" ? try Self.answer(declaring: nil) : Data("<html>maintenance</html>".utf8)
        let server = try LoopbackPlacementServer { _ in .init(status: 200, body: body) }
        let error = try await Self.failure(of: Self.client(server))

        #expect(error as? ResultBinding.Refusal == .noInputHash)
        #expect(UploadFailureKind.classify(error) == .unreadableAnswer)
        #expect(server.requests.count == 1)
    }

    /// A status outside 2xx is the server's own word: a refusal sends the homeowner to the review,
    /// a server error or a busy server can be tried again. The body reaches the log, cut at 300 bytes.
    @Test(arguments: [
        (422, nil, UploadFailureKind.refused),
        (503, nil, UploadFailureKind.serverError),
        (429, "30", UploadFailureKind.busy(retryAfter: 30)),
    ] as [(Int, String?, UploadFailureKind)])
    func aStatusOutside2xxIsClassifiedByThatStatus(status: Int, retryAfter: String?, kind: UploadFailureKind) async throws {
        let body = Data(String(repeating: "x", count: 1000).utf8)
        let server = try LoopbackPlacementServer { _ in
            .init(status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:], body: body)
        }
        let error = try await Self.failure(of: Self.client(server))

        guard case .server(let sentStatus, let sentBody, let sentRetryAfter)? = error as? PlacementHTTPError else {
            Issue.record("expected a server error, got \(error)")
            return
        }
        #expect(sentStatus == status)
        #expect(sentBody.utf8.count == 300)
        #expect(sentRetryAfter == retryAfter)
        #expect(UploadFailureKind.classify(error) == kind)
        #expect(server.requests.count == 1)
    }

    /// Nothing listening: no server answered, so the homeowner can try again.
    @Test func noServerIsUnreachable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        // Port 9 (discard) has no listener on a test machine.
        let client = PlacementHTTPClient(serverURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: configuration))
        let error = try await Self.failure(of: client)

        #expect(error is URLError)
        #expect(UploadFailureKind.classify(error) == .unreachable)
    }
}
