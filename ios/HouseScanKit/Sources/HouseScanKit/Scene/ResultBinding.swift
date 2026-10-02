import Foundation

/// Ties a placement answer to the scene this phone sent. The server writes the SHA-256 of the
/// scene bytes it parsed into `stats.input_sha256`: for a bare scene.json that is the request body
/// itself (server/api.py `_parse` passes the body to `parse_scene`, which hashes it). The result
/// schema requires the field as 64 lowercase hex digits (server/schemas/result.schema.json).
///
/// An answer is accepted only when it carries that hash and the hash is of the bytes sent. An
/// answer for another scene, or one whose hash is missing or unreadable, is never shown. This is
/// a defence against a mismatched response; nothing shows the current server sending one.
public enum ResultBinding {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// The answer has no `stats.input_sha256` string, or isn't JSON this check can read.
        case noInputHash
        /// `stats.input_sha256` isn't 64 lowercase hex digits.
        case malformedInputHash(String)
        /// The answer names another scene. Both hashes are lowercase hex.
        case mismatch(submitted: String, declared: String)

        public var description: String {
            switch self {
            case .noInputHash: "answer has no readable stats.input_sha256"
            case .malformedInputHash(let value): "answer's stats.input_sha256 is malformed: \(value.prefix(80))"
            case .mismatch(let submitted, let declared): "answer is for scene \(declared), not the scene sent (\(submitted))"
            }
        }
    }

    /// Throws a `Refusal` unless `answer` declares `stats.input_sha256` as the SHA-256 of `scene`.
    /// Anything this can't read refuses the answer: a check that skipped unreadable metadata would
    /// let a mismatched answer through whenever the general decoder is more lenient than this one.
    public static func check(answer: Data, submittedScene scene: Data) throws {
        let declared: String
        do {
            declared = try JSONDecoder().decode(Answer.self, from: answer).stats.inputSHA256
        } catch {
            throw Refusal.noInputHash
        }
        guard isSHA256Hex(declared) else { throw Refusal.malformedInputHash(declared) }
        let submitted = PacketFiles.sha256(scene)
        guard declared == submitted else { throw Refusal.mismatch(submitted: submitted, declared: declared) }
    }

    /// The schema's form for the field, `^[0-9a-f]{64}$`.
    static func isSHA256Hex(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private struct Answer: Decodable {
        struct Stats: Decodable {
            var inputSHA256: String
            enum CodingKeys: String, CodingKey { case inputSHA256 = "input_sha256" }
        }
        var stats: Stats
    }
}
