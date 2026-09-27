import Foundation
@testable import HouseScanKit
import Testing

/// `ServerErrorDefaults` against the server's current server/rules.yaml: the tree's copy once
/// t3/server is merged, else origin/t3/server. Skipped where neither can be read, except under
/// HOUSESCAN_REQUIRE_UPSTREAM=1 (CI), where that fails.
@Suite struct ServerErrorDefaultsTests {
    /// The `errors:` block's `key: {value: N, ...}` lines, strictly: a key must appear once, on a
    /// line of its own two spaces in, with a number as its value. Nothing else is parsed.
    static func errorValues(_ yaml: String) throws -> [String: Double] {
        var values: [String: Double] = [:]
        var inErrors = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("errors:") { inErrors = true; continue }
            guard inErrors else { continue }
            if let first = line.first, !first.isWhitespace, first != "#" { break }
            guard line.hasPrefix("  "), !line.hasPrefix("   "), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.hasPrefix("#") else { continue }
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("{value:") else { throw Unreadable(line: line) }
            let number = rest.dropFirst("{value:".count).prefix { $0 != "," && $0 != "}" }.trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), values[key] == nil else { throw Unreadable(line: line) }
            values[key] = value
        }
        return values
    }

    struct Unreadable: Error, CustomStringConvertible {
        let line: String
        var description: String { "rules.yaml errors line not read: \(line)" }
    }

    static var rules: Data? { SceneSchemas.upstream("server/rules.yaml", branch: SceneSchemas.serverBranch) }

    @Test(.enabled(if: SceneSchemas.requireUpstream || ServerErrorDefaultsTests.rules != nil, "server/rules.yaml is not available to compare against"))
    func mirroredValuesMatchTheServersRules() throws {
        let data = try #require(Self.rules, "server/rules.yaml is not on \(SceneSchemas.serverBranch)")
        let values = try Self.errorValues(String(decoding: data, as: UTF8.self))
        for (key, mirrored) in ServerErrorDefaults.mirrored {
            let server = try #require(values[key], "errors.\(key) is missing from the server's rules.yaml")
            #expect(server == mirrored, "errors.\(key) is \(server) on the server; ServerErrorDefaults mirrors \(mirrored)")
        }
    }

    /// The parser reads exactly the block's values and refuses what it can't read.
    @Test func theParserIsStrict() throws {
        let yaml = """
        battery:
          width_ft: {value: 9, source: "x"}
        errors:
          tap_ft: {value: 0.3, source: "a"}
          # a comment
          mesh_ft: {value: 0.5, source: "b", placeholder: true}
        sweep:
          step_ft: {value: 0.2, source: "c"}
        """
        #expect(try Self.errorValues(yaml) == ["tap_ft": 0.3, "mesh_ft": 0.5])
        #expect(throws: Unreadable.self) { try Self.errorValues("errors:\n  tap_ft: 0.3\n") }
        #expect(throws: Unreadable.self) { try Self.errorValues("errors:\n  tap_ft: {value: 0.3}\n  tap_ft: {value: 0.4}\n") }
    }

    /// A drifted mirror is caught: the comparison against a changed value fails.
    @Test func aDifferentValueIsCaught() throws {
        let values = try Self.errorValues("errors:\n  tap_ft: {value: 0.35, source: \"x\"}\n")
        #expect(values["tap_ft"] != ServerErrorDefaults.mirrored.first { $0.key == "tap_ft" }?.value)
    }
}
