import Foundation
import Network
import Synchronization

/// A placement server on 127.0.0.1 for client tests: real HTTP, so the tests drive the actual
/// `URLSession` transport. Each request gets the reply `respond` builds from it, and every request
/// is kept for the test to inspect. It speaks only what these tests need: one request per
/// connection, a `Content-Length` body, and the reply closes the connection.
final class LoopbackPlacementServer: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-placement-server")
    private let respond: @Sendable (Request) -> Reply
    private let log = Mutex<[Request]>([])

    var requests: [Request] { log.withLock { $0 } }
    var base: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")! }

    init(respond: @escaping @Sendable (Request) -> Reply) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data()) { request in self.answer(request, on: connection) }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else { throw URLError(.cannotConnectToHost) }
    }

    deinit { listener.cancel() }

    private func answer(_ request: Request, on connection: NWConnection) {
        log.withLock { $0.append(request) }
        let reply = respond(request)
        var head = "HTTP/1.1 \(reply.status) Reply\r\nContent-Type: application/json\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func receive(_ connection: NWConnection, buffer: Data, handler: @escaping @Sendable (Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) { return handler(request) }
            if done || error != nil { return connection.cancel() }
            receive(connection, buffer: buffer, handler: handler)
        }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let line = head[0].split(separator: " ")
        guard line.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for field in head.dropFirst() {
            guard let colon = field.firstIndex(of: ":") else { continue }
            headers[field[..<colon].lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(line[0]), path: String(line[1]), headers: headers, body: Data(body.prefix(length)))
    }
}
