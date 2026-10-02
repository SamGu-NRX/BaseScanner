import Foundation
import HouseScanKit
import Testing

/// A placement answer from the server is shown only for the scene that was sent: its
/// `stats.input_sha256` must be present, in the schema's form, and the SHA-256 of those exact
/// bytes. Built from a real server answer to the synthetic replay.
@Suite struct ResultBindingTests {
    static let scene = Data(#"{"note":"the bytes this phone sent"}"#.utf8)
    static let fixtureHash = "2cb165cd4d4e9340496d90a589678ccbbe8ae6720d9d73bcae427a6b22075cb7"
    static let hashLine = "\"input_sha256\": \"\(fixtureHash)\","

    static func answer() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.contains(hashLine))
        return text
    }

    /// The real answer with its `input_sha256` line replaced by `line` (empty removes it).
    static func answer(replacingHashLineWith line: String) throws -> Data {
        Data(try answer().replacingOccurrences(of: hashLine, with: line).utf8)
    }

    static func answer(declaring hash: String) throws -> Data {
        try answer(replacingHashLineWith: "\"input_sha256\": \"\(hash)\",")
    }

    static func refusal(_ data: Data) throws -> ResultBinding.Refusal {
        let refusal = try #require(throws: ResultBinding.Refusal.self) {
            try ResultBinding.check(answer: data, submittedScene: Self.scene)
        }
        // Every refusal is the "couldn't read the answer" failure: back to the review, no retry.
        #expect(UploadFailureKind.classify(refusal) == .unreadableAnswer)
        #expect(!UploadFailureKind.classify(refusal).retryable)
        return refusal
    }

    @Test func anAnswerForTheSceneSentPassesAndDecodes() throws {
        let data = try Self.answer(declaring: PacketFiles.sha256(Self.scene))
        try ResultBinding.check(answer: data, submittedScene: Self.scene)
        #expect(try PlacementResult.decode(data).decision == .manualReview)
    }

    @Test func anAnswerForAnotherSceneIsRefused() throws {
        let other = PacketFiles.sha256(Data("another scene".utf8))
        #expect(try Self.refusal(Self.answer(declaring: other)) == .mismatch(submitted: PacketFiles.sha256(Self.scene), declared: other))
    }

    /// No readable hash refuses the answer, whatever the general decoder would make of it.
    @Test(arguments: [
        ("absent", ""),
        ("null", "\"input_sha256\": null,"),
        ("a number", "\"input_sha256\": 7,"),
    ])
    func anAnswerWithoutAHashIsRefused(_ kind: String, line: String) throws {
        #expect(try Self.refusal(Self.answer(replacingHashLineWith: line)) == .noInputHash)
    }

    /// The schema's form is 64 lowercase hex digits; the right digits in capitals, or too few,
    /// are refused rather than compared.
    @Test(arguments: ["UPPER", "short", "notHex"])
    func aMalformedHashIsRefused(_ kind: String) throws {
        let good = PacketFiles.sha256(Self.scene)
        let value = switch kind {
        case "UPPER": good.uppercased()
        case "short": String(good.dropLast())
        default: String(good.dropLast()) + "z"
        }
        #expect(try Self.refusal(Self.answer(declaring: value)) == .malformedInputHash(value))
    }

    @Test func anAnswerThatIsNotJSONIsRefused() throws {
        #expect(try Self.refusal(Data("not json".utf8)) == .noInputHash)
    }

    /// A field this check doesn't read can't make it skip the comparison: an answer for another
    /// scene that also carries a number too large for a Double is still refused.
    @Test func anUnusualIgnoredFieldDoesNotSkipTheCheck() throws {
        let other = PacketFiles.sha256(Data("another scene".utf8))
        let text = try Self.answer().replacingOccurrences(of: Self.hashLine, with: "\"input_sha256\": \"\(other)\", \"extra\": 1e400,")
        #expect(throws: ResultBinding.Refusal.self) {
            try ResultBinding.check(answer: Data(text.utf8), submittedScene: Self.scene)
        }
    }
}
