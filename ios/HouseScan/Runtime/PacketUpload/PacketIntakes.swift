import Foundation
import HouseScanKit

/// Picks the `PacketIntake` the app sends packets through.
///
/// None is selected for a real server yet: which API the phone speaks to Base's survey pipeline
/// is still being decided between teams. Until an adapter for it is added here, a configured
/// endpoint only turns on the consent screen and the progress card, and Send reports that it
/// couldn't send. Nothing leaves the phone.
enum PacketIntakes {
    static func make(_ options: LaunchOptions) -> (any PacketIntake)? {
        guard let endpoint = options.packetUpload else { return nil }
        #if DEBUG
        if options.packetIntake == "localTest" { return LocalTestIntake(endpoint: endpoint) }
        #endif
        _ = endpoint
        return nil
    }
}

#if DEBUG
/// For tests only, in Debug builds: speaks to ios/Tools/packet-intake-test-stub.py, whose calls
/// mirror `PacketIntake` one to one with HouseScanKit's own types as JSON. It stands for no real
/// server's API. It exists to run the background uploads, relaunch and resume end to end in the
/// Simulator.
struct LocalTestIntake: PacketIntake {
    let endpoint: PacketUploadEndpoint
    private let session = URLSession(configuration: .ephemeral)

    private struct Begin: Encodable {
        var request: PacketIntakeRequest
        var resuming: String?
    }

    private struct Commit: Codable {
        var session: String
        var paths: Set<String>
    }

    private struct Finish: Codable {
        var complete: Bool
        var reference: String?
        var missing: Set<String>?
    }

    func begin(_ request: PacketIntakeRequest, resuming: String?) async throws(PacketIntakeError) -> PacketIntakeSession {
        try await call("begin", Begin(request: request, resuming: resuming))
    }

    func commit(_ paths: Set<String>, in session: PacketIntakeSession) async throws(PacketIntakeError) -> Set<String> {
        let answer: Commit = try await call("commit", Commit(session: session.id, paths: paths))
        return answer.paths
    }

    func finish(_ session: PacketIntakeSession) async throws(PacketIntakeError) -> PacketIntakeFinish {
        let answer: Finish = try await call("finish", Commit(session: session.id, paths: []))
        return answer.complete ? .complete(reference: answer.reference) : .missing(answer.missing ?? [])
    }

    private func call<Body: Encodable, Answer: Decodable>(_ name: String, _ body: Body) async throws(PacketIntakeError) -> Answer {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var request = URLRequest(url: endpoint.baseURL.appending(path: "test-intake").appending(path: name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.bearerKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data: Data
        do {
            let (answer, response) = try await session.upload(for: request, from: try encoder.encode(body))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = PacketIntakeError.classify(status: status, body: String(decoding: answer.prefix(300), as: UTF8.self)) { throw error }
            data = answer
        } catch let error as PacketIntakeError {
            throw error
        } catch {
            throw .transient(String(describing: error))
        }
        do {
            return try decoder.decode(Answer.self, from: data)
        } catch {
            throw .refused("\(name) answer unreadable: \(error)")
        }
    }
}
#endif
