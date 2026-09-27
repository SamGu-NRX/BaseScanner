import Foundation

/// Whether this build and this homeowner allow a capture upload. No endpoint means nothing is
/// offered and nothing is sent; an endpoint without the homeowner's yes sends nothing either.
public enum CaptureUploadGate {
    public enum Decision: Sendable, Equatable {
        case off(String)
        case on(URL)
    }

    /// `endpoint` is the API base including `/v1`, from the build's Info.plist. An empty build
    /// setting, an unexpanded `$(...)`, or anything but https (http only to this machine, for
    /// tests) is off.
    public static func decide(endpoint: String?, consented: Bool) -> Decision {
        let text = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, !text.hasPrefix("$(") else { return .off("no capture endpoint in this build") }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host(), url.user == nil, url.password == nil else {
            return .off("capture endpoint is not a URL")
        }
        let local = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && local) else { return .off("capture endpoint must be https") }
        guard consented else { return .off("the homeowner has not agreed to send the capture") }
        return .on(url)
    }
}
