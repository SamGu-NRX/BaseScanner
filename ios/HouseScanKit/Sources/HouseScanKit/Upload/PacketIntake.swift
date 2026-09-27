import Foundation

// What the packet upload needs from a server, without choosing one. The server's API isn't
// decided yet, so each candidate becomes one `PacketIntake` adapter: begin (or resume) a
// session, get an upload target per file, report files uploaded, finish. `PacketUploader` does
// the rest (retries, resuming, the file transfers) the same way for any of them.

/// Where packets go: `HOUSESCAN_PACKET_UPLOAD_URL` (Info.plist `HouseScanPacketUploadURL`) or the
/// `-packetUploadURL` launch argument, with an optional bearer key. No endpoint means the feature
/// is off: nothing is offered and nothing is sent.
public struct PacketUploadEndpoint: Sendable, Equatable {
    public let baseURL: URL
    /// For an adapter to send to its API; never sent to an upload target.
    public let bearerKey: String?

    /// Nil unless `text` is an http(s) URL with a host. An empty build setting leaves the plist
    /// value empty, and an unexpanded "$(HOUSESCAN_PACKET_UPLOAD_URL)" has no scheme: both are off.
    public init?(baseURL text: String?, bearerKey: String? = nil) {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else { return nil }
        baseURL = url
        let key = bearerKey?.trimmingCharacters(in: .whitespaces) ?? ""
        // An unexpanded "$(HOUSESCAN_PACKET_UPLOAD_KEY)" is no key either.
        self.bearerKey = key.isEmpty || key.hasPrefix("$(") ? nil : key
    }
}

/// The homeowner's yes: when it was given and which wording they saw.
public struct PacketUploadConsent: Codable, Sendable, Equatable {
    public var grantedAt: Date
    /// `PacketConsentWording.id` of the text on screen when they agreed.
    public var textID: String

    public init(grantedAt: Date, textID: String) {
        self.grantedAt = grantedAt
        self.textID = textID
    }
}

/// One file of the packet: its path in the packet, size, SHA-256 and content type.
public struct PacketUploadFile: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var bytes: Int
    public var sha256: String
    public var contentType: String

    public init(path: String, bytes: Int, sha256: String, contentType: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.contentType = contentType
    }
}

/// Everything an intake may need to open a session for one packet.
public struct PacketIntakeRequest: Codable, Sendable, Equatable {
    public var packetVersion: String
    /// A UUID the phone makes per scan.
    public var scanID: String
    /// SHA-256 of the scene.json sent to /v1/placements, which joins the packet to that request.
    public var sceneSHA256: String
    public var consent: PacketUploadConsent
    /// manifest.json, then every file it lists.
    public var files: [PacketUploadFile]

    public init(packetVersion: String, scanID: String, sceneSHA256: String, consent: PacketUploadConsent, files: [PacketUploadFile]) {
        self.packetVersion = packetVersion
        self.scanID = scanID
        self.sceneSHA256 = sceneSHA256
        self.consent = consent
        self.files = files
    }
}

/// Where and how to send one file: the uploader uses exactly this method, URL and headers, with
/// the file's bytes as the body and nothing added.
public struct PacketUploadTarget: Codable, Sendable, Equatable {
    public var path: String
    public var method: String
    public var url: URL
    public var headers: [String: String]

    public init(path: String, method: String = "PUT", url: URL, headers: [String: String] = [:]) {
        self.path = path
        self.method = method
        self.url = url
        self.headers = headers
    }
}

/// An open session: what the server already holds, and a target for each file it doesn't.
public struct PacketIntakeSession: Codable, Sendable, Equatable {
    /// The server's id for the session; `begin` gets it back to resume the same one.
    public var id: String
    /// When the targets stop working, if the server says.
    public var expiresAt: Date?
    /// Files the server holds and has checked.
    public var stored: Set<String>
    public var targets: [PacketUploadTarget]

    public init(id: String, expiresAt: Date?, stored: Set<String>, targets: [PacketUploadTarget]) {
        self.id = id
        self.expiresAt = expiresAt
        self.stored = stored
        self.targets = targets
    }
}

public enum PacketIntakeFinish: Sendable, Equatable {
    /// The server has the whole packet. `reference` is whatever it names the result by.
    case complete(reference: String?)
    /// The server is missing or rejected these files; they are sent again.
    case missing(Set<String>)
}

public enum PacketIntakeError: Error, Sendable, Equatable {
    /// The network, or a server answer a later try can change (5xx, 408, 429): tried again.
    case transient(String)
    /// The server won't take this packet; sending it again gets the same answer.
    case refused(String)
    /// The server no longer knows the session: `begin` opens it again.
    case sessionGone

    /// The usual reading of an HTTP status for an adapter: 2xx is nil, 404 the session gone,
    /// 408, 429 and 5xx transient, anything else refused.
    public static func classify(status: Int, body: String) -> PacketIntakeError? {
        switch status {
        case 200..<300: nil
        case 404: .sessionGone
        case 408, 429, 500..<600: .transient("\(status) \(body)")
        default: .refused("\(status) \(body)")
        }
    }
}

/// A server's side of the packet upload.
public protocol PacketIntake: Sendable {
    /// Opens a session for `request`, or resumes `resuming` (the id a previous `begin` gave), and
    /// returns what is stored and a target for every other file. Called again to resume after a
    /// relaunch, when targets are refused or expire, and after `finish` names missing files, so
    /// it must be safe to repeat.
    func begin(_ request: PacketIntakeRequest, resuming: String?) async throws(PacketIntakeError) -> PacketIntakeSession
    /// Tells the server these files were sent to their targets. Returns the ones it now holds;
    /// the rest are sent again. An intake that learns of uploads by itself returns `paths`.
    func commit(_ paths: Set<String>, in session: PacketIntakeSession) async throws(PacketIntakeError) -> Set<String>
    /// Asks the server to check the whole packet and take it.
    func finish(_ session: PacketIntakeSession) async throws(PacketIntakeError) -> PacketIntakeFinish
}
