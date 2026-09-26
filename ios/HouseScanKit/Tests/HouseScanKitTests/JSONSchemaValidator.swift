import Foundation

/// A JSON Schema (draft 2020-12) validator for exactly the keywords scene.schema.json and
/// result.schema.json use. Any other keyword makes `init` throw, so a schema change that needs a new
/// keyword fails the tests instead of being silently ignored.
struct JSONSchemaValidator {
    /// Parsed JSON. Numbers are Doubles; "integer" means a Double with no fractional part, as the
    /// spec defines it.
    enum Value: Decodable, Equatable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let a = try? c.decode([Value].self) {
                self = .array(a)
            } else {
                self = .object(try c.decode([String: Value].self))
            }
        }

        static func parse(_ data: Data) throws -> Value {
            try JSONDecoder().decode(Value.self, from: data)
        }

        subscript(key: String) -> Value? {
            if case .object(let o) = self { return o[key] }
            return nil
        }

        subscript(index: Int) -> Value? {
            if case .array(let a) = self, a.indices.contains(index) { return a[index] }
            return nil
        }

        var number: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var array: [Value]? {
            if case .array(let a) = self { return a }
            return nil
        }

        var object: [String: Value]? {
            if case .object(let o) = self { return o }
            return nil
        }

        var numbers: [Double]? { array?.compactMap(\.number) }
    }

    struct SchemaError: Error, CustomStringConvertible {
        let description: String
    }

    private static let supported: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "minItems", "maxItems",
        "enum", "const", "$ref", "oneOf", "pattern", "minimum", "maximum", "exclusiveMinimum",
        "minLength", "if", "then",
    ]
    /// Keywords that only annotate and never affect validation.
    private static let annotations: Set<String> = ["$schema", "$id", "$defs", "$comment", "title", "description"]

    let root: Value

    init(schema data: Data) throws {
        root = try Value.parse(data)
        try checkSchema(root, path: "#")
    }

    /// Error messages, each prefixed with the instance's JSON path. Empty means valid.
    func validate(_ data: Data) throws -> [String] {
        validate(try Value.parse(data))
    }

    func validate(_ instance: Value) -> [String] {
        var errors: [String] = []
        check(instance, against: root, path: "$", errors: &errors)
        return errors
    }

    // MARK: Schema check

    /// Rejects unsupported keywords and unresolvable $refs anywhere a subschema can appear.
    private func checkSchema(_ schema: Value, path: String) throws {
        if case .bool = schema { return }
        guard let object = schema.object else { throw SchemaError(description: "\(path): schema is not an object or boolean") }
        for (keyword, value) in object {
            let here = "\(path)/\(keyword)"
            guard Self.supported.contains(keyword) || Self.annotations.contains(keyword) else {
                throw SchemaError(description: "\(here): unsupported keyword \"\(keyword)\"")
            }
            switch keyword {
            case "properties", "$defs":
                guard let members = value.object else { throw SchemaError(description: "\(here): not an object") }
                for (name, sub) in members { try checkSchema(sub, path: "\(here)/\(name)") }
            case "additionalProperties", "items", "if", "then":
                try checkSchema(value, path: here)
            case "oneOf":
                guard let list = value.array, !list.isEmpty else { throw SchemaError(description: "\(here): not a non-empty array") }
                for (i, sub) in list.enumerated() { try checkSchema(sub, path: "\(here)/\(i)") }
            case "$ref":
                guard let ref = value.string, resolve(ref) != nil else {
                    throw SchemaError(description: "\(here): cannot resolve \(value)")
                }
            case "pattern":
                guard let p = value.string, (try? NSRegularExpression(pattern: p)) != nil else {
                    throw SchemaError(description: "\(here): invalid pattern")
                }
            default:
                break
            }
        }
    }

    /// Resolves "#" and "#/a/b" JSON pointers within this document; other refs are unsupported.
    private func resolve(_ ref: String) -> Value? {
        guard ref.hasPrefix("#") else { return nil }
        var node = root
        for token in ref.dropFirst().split(separator: "/", omittingEmptySubsequences: true) {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = node[key] else { return nil }
            node = next
        }
        return node
    }

    // MARK: Validation

    private func check(_ instance: Value, against schema: Value, path: String, errors: inout [String]) {
        if case .bool(let allowed) = schema {
            if !allowed { errors.append("\(path): no value is allowed here") }
            return
        }
        guard let s = schema.object else { return }

        if let ref = s["$ref"]?.string, let target = resolve(ref) {
            check(instance, against: target, path: path, errors: &errors)
        }

        if let type = s["type"] {
            let names = type.array?.compactMap(\.string) ?? [type.string].compactMap { $0 }
            if !names.contains(where: { matches(instance, type: $0) }) {
                errors.append("\(path): expected type \(names.joined(separator: " or ")), got \(typeName(instance))")
            }
        }
        // Value's == is JSON equality: numbers are Doubles, so 1 equals 1.0.
        if let options = s["enum"]?.array, !options.contains(instance) {
            errors.append("\(path): \(render(instance)) is not one of \(options.map(render).joined(separator: ", "))")
        }
        if let constant = s["const"], constant != instance {
            errors.append("\(path): \(render(instance)) is not \(render(constant))")
        }

        if case .object(let members) = instance {
            for name in s["required"]?.array?.compactMap(\.string) ?? [] where members[name] == nil {
                errors.append("\(path): missing required property \"\(name)\"")
            }
            let properties = s["properties"]?.object ?? [:]
            for (name, value) in members.sorted(by: { $0.key < $1.key }) {
                let childPath = "\(path).\(name)"
                if let sub = properties[name] {
                    check(value, against: sub, path: childPath, errors: &errors)
                } else if let additional = s["additionalProperties"] {
                    if case .bool(false) = additional {
                        errors.append("\(path): unexpected property \"\(name)\"")
                    } else {
                        check(value, against: additional, path: childPath, errors: &errors)
                    }
                }
            }
        }

        if case .array(let items) = instance {
            if let min = s["minItems"]?.number, Double(items.count) < min {
                errors.append("\(path): \(items.count) items, fewer than minItems \(Int(min))")
            }
            if let max = s["maxItems"]?.number, Double(items.count) > max {
                errors.append("\(path): \(items.count) items, more than maxItems \(Int(max))")
            }
            if let itemSchema = s["items"] {
                for (i, item) in items.enumerated() {
                    check(item, against: itemSchema, path: "\(path)[\(i)]", errors: &errors)
                }
            }
        }

        if case .number(let n) = instance {
            if let min = s["minimum"]?.number, n < min { errors.append("\(path): \(n) is below minimum \(min)") }
            if let max = s["maximum"]?.number, n > max { errors.append("\(path): \(n) is above maximum \(max)") }
            if let bound = s["exclusiveMinimum"]?.number, n <= bound {
                errors.append("\(path): \(n) is not above exclusiveMinimum \(bound)")
            }
        }

        if case .string(let text) = instance {
            if let min = s["minLength"]?.number, Double(text.unicodeScalars.count) < min {
                errors.append("\(path): string shorter than minLength \(Int(min))")
            }
            if let pattern = s["pattern"]?.string, let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
                errors.append("\(path): \"\(text)\" does not match pattern \(pattern)")
            }
        }

        if let options = s["oneOf"]?.array {
            let passing = options.filter { option in
                var sub: [String] = []
                check(instance, against: option, path: path, errors: &sub)
                return sub.isEmpty
            }.count
            if passing != 1 { errors.append("\(path): matches \(passing) oneOf options, expected exactly 1") }
        }

        if let condition = s["if"] {
            var sub: [String] = []
            check(instance, against: condition, path: path, errors: &sub)
            if sub.isEmpty, let then = s["then"] {
                check(instance, against: then, path: path, errors: &errors)
            }
        }
    }

    private func matches(_ value: Value, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string),
             ("array", .array), ("object", .object):
            true
        case ("integer", .number(let n)):
            n.rounded() == n
        default:
            false
        }
    }

    private func typeName(_ value: Value) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private func render(_ value: Value) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): String(b)
        case .number(let n): String(n)
        case .string(let s): "\"\(s)\""
        case .array: "[...]"
        case .object: "{...}"
        }
    }
}
