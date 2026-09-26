import CryptoKit
import Foundation
import Testing

/// Vendored copies of the server's contracts, byte for byte from origin/t3/server at e0ee8d3
/// (server/schemas/*.schema.json and server/tests/fixtures/example-scene.json). That revision
/// added `out_ft` to missing_evidence requests and defined `out_ft` for facing and overhead
/// coverage. `vendoredCopiesMatchServer` fails if the server's files change and these are not
/// refreshed; `vendoredCopiesAreTheRecordedRevision` fails if a copy is edited by hand.
enum SceneSchemas {
    static let vendored: [(name: String, serverPath: String, sha256: String)] = [
        ("scene.schema.json", "server/schemas/scene.schema.json",
         "e47dd28ad55dd415159ea61f0cca285f71c01e93a489cf646460f47858b27aec"),
        ("result.schema.json", "server/schemas/result.schema.json",
         "f5efaf372eb00426798af8e1b60bdd580af4bf04601af3e7ee3fca5261dd047f"),
        ("example-scene.json", "server/tests/fixtures/example-scene.json",
         "07bda024c682be365f0f7a6ad7a83fb44c0726344193e7a8b2d8d79499b4bef0"),
    ]

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Schemas") else {
            throw JSONSchemaValidator.SchemaError(description: "Schemas/\(name) is missing from the test bundle")
        }
        return try Data(contentsOf: url)
    }

    static func scene() throws -> JSONSchemaValidator { try JSONSchemaValidator(schema: data("scene.schema.json")) }
    static func result() throws -> JSONSchemaValidator { try JSONSchemaValidator(schema: data("result.schema.json")) }

    /// Walks up from this file to the first directory holding `server/schemas` or `.git`.
    static func repoRoot(from file: String = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("server/schemas").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

@Suite struct JSONSchemaValidatorTests {
    private func validator(_ json: String) throws -> JSONSchemaValidator {
        try JSONSchemaValidator(schema: Data(json.utf8))
    }

    private func errors(_ v: JSONSchemaValidator, _ json: String) throws -> [String] {
        try v.validate(Data(json.utf8))
    }

    @Test func typesIncludingIntegerAndTypeLists() throws {
        let v = try validator(#"{"type": "object", "properties": {"n": {"type": "integer"}, "s": {"type": ["string", "null"]}}}"#)
        #expect(try errors(v, #"{"n": 3, "s": null}"#).isEmpty)
        #expect(try errors(v, #"{"n": 3.0, "s": "x"}"#).isEmpty)
        #expect(try errors(v, #"{"n": 3.5}"#) == ["$.n: expected type integer, got number"])
        #expect(try errors(v, #"{"s": 1}"#) == ["$.s: expected type string or null, got number"])
        #expect(try errors(v, #"{"n": true}"#) == ["$.n: expected type integer, got boolean"])
    }

    @Test func requiredAndAdditionalProperties() throws {
        let v = try validator(#"{"type": "object", "required": ["a"], "additionalProperties": false, "properties": {"a": {}}}"#)
        #expect(try errors(v, #"{"a": 1}"#).isEmpty)
        #expect(try errors(v, #"{}"#) == [#"$: missing required property "a""#])
        #expect(try errors(v, #"{"a": 1, "b": 2}"#) == [#"$: unexpected property "b""#])

        let map = try validator(#"{"type": "object", "additionalProperties": {"type": "string"}}"#)
        #expect(try errors(map, #"{"x": "y"}"#).isEmpty)
        #expect(try errors(map, #"{"x": 1}"#) == ["$.x: expected type string, got number"])
    }

    @Test func arraysAndNumbers() throws {
        let v = try validator(#"{"type": "array", "minItems": 2, "maxItems": 2, "items": {"type": "number", "minimum": 0, "maximum": 10}}"#)
        #expect(try errors(v, "[0, 10]").isEmpty)
        #expect(try errors(v, "[1]") == ["$: 1 items, fewer than minItems 2"])
        #expect(try errors(v, "[1, 2, 3]") == ["$: 3 items, more than maxItems 2"])
        #expect(try errors(v, "[-1, 11]") == ["$[0]: -1.0 is below minimum 0.0", "$[1]: 11.0 is above maximum 10.0"])

        let positive = try validator(#"{"exclusiveMinimum": 0}"#)
        #expect(try errors(positive, "0.1").isEmpty)
        #expect(try errors(positive, "0") == ["$: 0.0 is not above exclusiveMinimum 0.0"])
    }

    @Test func enumConstIncludingNull() throws {
        let v = try validator(#"{"enum": ["a", null]}"#)
        #expect(try errors(v, #""a""#).isEmpty)
        #expect(try errors(v, "null").isEmpty)
        #expect(try errors(v, #""b""#) == [#"$: "b" is not one of "a", null"#])

        let c = try validator(#"{"const": "1.0"}"#)
        #expect(try errors(c, #""1.0""#).isEmpty)
        #expect(try errors(c, #""1.1""#) == [#"$: "1.1" is not "1.0""#])
    }

    @Test func stringsPatternAndMinLength() throws {
        let v = try validator(#"{"type": "string", "minLength": 1, "pattern": "^[0-9a-f]{4}$"}"#)
        #expect(try errors(v, #""0a9f""#).isEmpty)
        #expect(try errors(v, #""0A9F""#) == [#"$: "0A9F" does not match pattern ^[0-9a-f]{4}$"#])
        #expect(try errors(v, #""""#).count == 2)
    }

    @Test func refOneOfAndIfThen() throws {
        let v = try validator(#"""
        {"type": "object",
         "properties": {"p": {"oneOf": [{"type": "null"}, {"$ref": "#/$defs/pt"}]},
                        "b": {"type": "object",
                              "properties": {"band": {"enum": ["wall", "ground"]}, "out": {"type": "number"}},
                              "if": {"properties": {"band": {"const": "ground"}}},
                              "then": {"required": ["out"]}}},
         "$defs": {"pt": {"type": "array", "minItems": 2, "maxItems": 2}}}
        """#)
        #expect(try errors(v, #"{"p": null, "b": {"band": "wall"}}"#).isEmpty)
        #expect(try errors(v, #"{"p": [1, 2], "b": {"band": "ground", "out": 1}}"#).isEmpty)
        #expect(try errors(v, #"{"p": [1]}"#) == ["$.p: matches 0 oneOf options, expected exactly 1"])
        #expect(try errors(v, #"{"b": {"band": "ground"}}"#) == [#"$.b: missing required property "out""#])
    }

    /// The manifest's `stream` def: allOf a `$ref` plus sibling constraints, all of which apply.
    @Test func allOfAppliesEverySubschemaAndFormatOnlyAnnotates() throws {
        let v = try validator(#"""
        {"$defs": {"file": {"type": "object", "required": ["path"], "properties": {"path": {"type": "string"}}}},
         "allOf": [{"$ref": "#/$defs/file"}, {"properties": {"path": {"minLength": 2}}}],
         "required": ["rows"],
         "properties": {"at": {"type": "string", "format": "date-time"}}}
        """#)
        #expect(try errors(v, #"{"path": "ab", "rows": 1, "at": "not a date"}"#).isEmpty)
        #expect(try errors(v, #"{"rows": 1}"#) == [#"$: missing required property "path""#])
        #expect(try errors(v, #"{"path": "a"}"#) == [#"$: missing required property "rows""#, "$.path: string shorter than minLength 2"])
        #expect(throws: JSONSchemaValidator.SchemaError.self) { try validator(#"{"allOf": []}"#) }
    }

    @Test func unsupportedKeywordAndBadRefThrow() {
        #expect(throws: JSONSchemaValidator.SchemaError.self) { try validator(#"{"anyOf": [{}]}"#) }
        #expect(throws: JSONSchemaValidator.SchemaError.self) { try validator(#"{"properties": {"a": {"uniqueItems": true}}}"#) }
        #expect(throws: JSONSchemaValidator.SchemaError.self) { try validator(##"{"$ref": "#/$defs/missing"}"##) }
    }

    @Test func serverExampleSceneIsValid() throws {
        #expect(try SceneSchemas.scene().validate(SceneSchemas.data("example-scene.json")) == [])
    }

    @Test func vendoredCopiesMatchServer() throws {
        // Without the server tree (before the server branch is merged) there is nothing to compare;
        // the vendored copies then stand as taken from origin/t3/server e0ee8d3.
        guard let root = SceneSchemas.repoRoot() else { return }
        for (name, serverPath, _) in SceneSchemas.vendored {
            let serverFile = root.appendingPathComponent(serverPath)
            guard FileManager.default.fileExists(atPath: serverFile.path) else { continue }
            let vendored = try SceneSchemas.data(name)
            #expect(try Data(contentsOf: serverFile) == vendored, "Tests/HouseScanKitTests/Schemas/\(name) differs from \(serverPath); copy the server's file over it")
        }
    }

    /// The hashes are of `git show e0ee8d3:<serverPath>`, so a copy edited by hand (or refreshed
    /// without updating the provenance above) fails here even where the server tree is absent.
    @Test func vendoredCopiesAreTheRecordedRevision() throws {
        for (name, _, sha256) in SceneSchemas.vendored {
            let digest = SHA256.hash(data: try SceneSchemas.data(name)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == sha256, "Schemas/\(name) is not the copy taken from origin/t3/server e0ee8d3")
        }
    }

    /// The e0ee8d3 contract: requests carry `out_ft`, and facing and overhead coverage may too.
    @Test func vendoredContractCarriesOutFtOnRequestsAndCoverage() throws {
        // A real server answer (see PlacementResultTests) with out_ft added to its requests.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        var answer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let requests = try #require(answer["missing_evidence"] as? [[String: Any]])
        answer["missing_evidence"] = requests.map { item -> [String: Any] in
            var item = item
            if item["band"] != nil, item["band"] as? String != "wall" { item["out_ft"] = 5.13 }
            return item
        }
        #expect(try SceneSchemas.result().validate(JSONSerialization.data(withJSONObject: answer)) == [])
        let scene = #"{"meter":{"pos":[0,5,0],"wall_id":"w"},"walls":[{"id":"w","baseline":[[-5,0],[5,0]]}],"coverage":{"observed":[{"band":"facing","span_ft":[-1,1],"out_ft":5.2},{"band":"overhead","span_ft":[-1,1],"out_ft":9.1}]}}"#
        #expect(try SceneSchemas.scene().validate(Data(scene.utf8)) == [])
    }
}
