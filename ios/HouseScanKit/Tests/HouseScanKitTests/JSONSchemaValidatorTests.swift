import Foundation
import Testing

/// Vendored copies of the server's contracts. They came from origin/t3/server at 6fdb440
/// (server/schemas/*.schema.json and server/tests/fixtures/example-scene.json);
/// `vendoredCopiesMatchServer` fails if the server's files change and these are not refreshed.
enum SceneSchemas {
    static let vendored: [(name: String, serverPath: String)] = [
        ("scene.schema.json", "server/schemas/scene.schema.json"),
        ("result.schema.json", "server/schemas/result.schema.json"),
        ("example-scene.json", "server/tests/fixtures/example-scene.json"),
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
        // the vendored copies then stand as taken from origin/t3/server 6fdb440.
        guard let root = SceneSchemas.repoRoot() else { return }
        for (name, serverPath) in SceneSchemas.vendored {
            let serverFile = root.appendingPathComponent(serverPath)
            guard FileManager.default.fileExists(atPath: serverFile.path) else { continue }
            let vendored = try SceneSchemas.data(name)
            #expect(try Data(contentsOf: serverFile) == vendored, "Tests/HouseScanKitTests/Schemas/\(name) differs from \(serverPath); copy the server's file over it")
        }
    }
}
