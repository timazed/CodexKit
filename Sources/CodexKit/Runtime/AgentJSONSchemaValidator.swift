import Foundation

/// Validates the SDK schema vocabulary and a documented subset of raw JSON
/// Schema. Unsupported assertions fail explicitly instead of being ignored.
enum AgentJSONSchemaValidator {
    static func validateSchema(_ schema: JSONSchema) throws {
        let root = schema.jsonValue
        var remaining = AgentStoreLimits.maximumEmbeddedPayloadNodeCount
        var references = Set<String>()
        try checkSchema(root, root: root, depth: 0, remaining: &remaining, references: &references)
    }

    static func validate(_ value: JSONValue, schema: JSONSchema, partial: Bool = false) throws {
        let root = schema.jsonValue
        var remaining = AgentStoreLimits.maximumEmbeddedPayloadNodeCount
        try checkValue(value, schema: root, root: root, path: "$", partial: partial, depth: 0, remaining: &remaining)
    }

    private static func consumeBudget(depth: Int, remaining: inout Int) throws {
        guard depth <= AgentStoreLimits.maximumEmbeddedPayloadDepth, remaining > 0 else {
            throw AgentRuntimeError(code: .structuredOutputValidationLimit, message: "Schema validation exceeded its nesting or work limit.")
        }
        remaining -= 1
    }

    private static func checkSchema(_ schema: JSONValue, root: JSONValue, depth: Int, remaining: inout Int, references: inout Set<String>) throws {
        try consumeBudget(depth: depth, remaining: &remaining)
        if case .bool = schema { return }
        guard let object = schema.objectValue else { throw invalid("A schema must be an object or Boolean.") }
        for key in object.keys where JSONSchemaKeyword(rawValue: key) == nil {
            throw AgentRuntimeError(code: .unsupportedSchemaKeyword, message: "Local schema validation does not support '\(key)'.")
        }
        if let type = object["type"] {
            _ = try parseTypes(type)
        }
        if let reference = object["$ref"] {
            let target = try resolve(reference, root: root)
            if let pointer = reference.stringValue, references.insert(pointer).inserted {
                try checkSchema(target, root: root, depth: depth + 1, remaining: &remaining, references: &references)
            }
        }
        for key in ["properties", "$defs", "definitions"] {
            if let value = object[key] {
                guard let children = value.objectValue else { throw invalid("\(key) must be an object.") }
                for child in children.values { try checkSchema(child, root: root, depth: depth + 1, remaining: &remaining, references: &references) }
            }
        }
        for key in ["items", "additionalProperties", "not"] {
            if let child = object[key] { try checkSchema(child, root: root, depth: depth + 1, remaining: &remaining, references: &references) }
        }
        for key in JSONSchemaComposition.allCases {
            if let value = object[key.rawValue] {
                guard let children = value.arrayValue, !children.isEmpty else { throw invalid("\(key.rawValue) must be a nonempty array.") }
                for child in children { try checkSchema(child, root: root, depth: depth + 1, remaining: &remaining, references: &references) }
            }
        }
        if let required = object["required"] {
            guard let keys = required.arrayValue, keys.allSatisfy({ $0.stringValue != nil }), Set(keys).count == keys.count else {
                throw invalid("required must contain unique property names.")
            }
        }
        if let values = object["enum"], values.arrayValue?.isEmpty != false { throw invalid("enum must be a nonempty array.") }
        for key in ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"] {
            if let value = object[key] {
                guard case let .number(number) = value, number.isFinite, number >= 0, number.rounded() == number else {
                    throw invalid("\(key) must be a nonnegative integer.")
                }
            }
        }
        for key in JSONSchemaNumericBound.allCases {
            if let value = object[key.rawValue] {
                guard case let .number(number) = value, number.isFinite, key != .multipleOf || number > 0 else {
                    throw invalid("\(key.rawValue) must be a valid numeric bound.")
                }
            }
        }
        if let value = object["uniqueItems"], case .bool = value { } else if object["uniqueItems"] != nil {
            throw invalid("uniqueItems must be a Boolean.")
        }

    }

    private static func checkValue(
        _ value: JSONValue, schema: JSONValue, root: JSONValue, path: String,
        partial: Bool, depth: Int, remaining: inout Int
    ) throws {
        try consumeBudget(depth: depth, remaining: &remaining)
        if case let .bool(allowed) = schema {
            if !allowed { throw invalid("\(path) is not permitted.") }
            return
        }
        guard let object = schema.objectValue else { throw invalid("Invalid schema at \(path).") }
        if let reference = object["$ref"] {
            try checkValue(value, schema: resolve(reference, root: root), root: root, path: path,
                partial: partial, depth: depth + 1, remaining: &remaining)
        }
        if let type = object["type"] {
            let names = try parseTypes(type)
            guard names.contains(where: { matches(value, type: $0) }) else { throw invalid("\(path) has the wrong type.") }
        }
        if let values = object["enum"]?.arrayValue, !values.contains(value) { throw invalid("\(path) is outside the permitted enum.") }
        if let constant = object["const"], constant != value { throw invalid("\(path) differs from the required constant.") }
        for key in JSONSchemaComposition.allCases {
            guard let branches = object[key.rawValue]?.arrayValue else { continue }
            var matches = 0
            for branch in branches {
                do {
                    try checkValue(value, schema: branch, root: root, path: path, partial: partial,
                        depth: depth + 1, remaining: &remaining)
                    matches += 1
                } catch {
                    if (error as? AgentRuntimeError)?.knownCode != .structuredOutputSchemaInvalid { throw error }
                }
            }
            let valid = key.accepts(matches: matches, branchCount: branches.count)
            if !valid { throw invalid("\(path) does not satisfy \(key.rawValue).") }
        }
        if let excluded = object["not"] {
            var excludedMatches = true
            do {
                try checkValue(value, schema: excluded, root: root, path: path, partial: partial,
                    depth: depth + 1, remaining: &remaining)
            } catch {
                if (error as? AgentRuntimeError)?.knownCode != .structuredOutputSchemaInvalid { throw error }
                excludedMatches = false
            }
            if excludedMatches { throw invalid("\(path) matches an excluded schema.") }
        }
        switch value {
        case let .object(properties):
            if !partial {
                for name in object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where properties[name] == nil {
                    throw invalid("\(path).\(name) is required.")
                }
            }
            try checkCount(properties.count, minimum: partial ? nil : object["minProperties"], maximum: object["maxProperties"], path: path)
            let declared = object["properties"]?.objectValue ?? [:]
            for (name, child) in properties {
                let childSchema = declared[name] ?? object["additionalProperties"] ?? .bool(true)
                try checkValue(child, schema: childSchema, root: root, path: "\(path).\(name)",
                    partial: partial, depth: depth + 1, remaining: &remaining)
            }
        case let .array(values):
            try checkCount(values.count, minimum: partial ? nil : object["minItems"], maximum: object["maxItems"], path: path)
            if object["uniqueItems"] == .bool(true), Set(values).count != values.count { throw invalid("\(path) contains duplicate items.") }
            for (index, child) in values.enumerated() {
                try checkValue(child, schema: object["items"] ?? .bool(true), root: root, path: "\(path)[\(index)]",
                    partial: partial, depth: depth + 1, remaining: &remaining)
            }
        case let .string(text):
            try checkCount(text.unicodeScalars.count, minimum: partial ? nil : object["minLength"], maximum: object["maxLength"], path: path)

        case let .number(number):
            guard number.isFinite else { throw invalid("\(path) must be finite.") }
            for (key, bound) in object {
                guard case let .number(limit) = bound else { continue }
                guard let constraint = JSONSchemaNumericBound(rawValue: key) else { continue }
                let valid = constraint.accepts(number, limit: limit)
                if !valid { throw invalid("\(path) violates \(key).") }
            }
        case .bool, .null: break
        }
    }

    private static func checkCount(_ count: Int, minimum: JSONValue?, maximum: JSONValue?, path: String) throws {
        if case let .number(limit) = minimum, Double(count) < limit { throw invalid("\(path) is below its minimum size.") }
        if case let .number(limit) = maximum, Double(count) > limit { throw invalid("\(path) exceeds its maximum size.") }
    }

    private static func parseTypes(_ value: JSONValue) throws -> [JSONSchemaValueType] {
        let values = value.arrayValue ?? [value]
        guard !values.isEmpty else { throw invalid("Invalid schema type.") }
        return try values.map { value in
            guard case let .string(name) = value,
                  let type = JSONSchemaValueType(rawValue: name) else {
                throw invalid("Invalid schema type.")
            }
            return type
        }
    }

    private static func matches(_ value: JSONValue, type: JSONSchemaValueType) -> Bool {
        switch (value, type) {
        case (.string, .string), (.number, .number), (.bool, .boolean), (.object, .object), (.array, .array), (.null, .null): true
        case let (.number(value), .integer): value.isFinite && value.rounded() == value
        default: false
        }
    }

    private static func resolve(_ reference: JSONValue, root: JSONValue) throws -> JSONValue {
        guard let path = reference.stringValue else { throw invalid("$ref must be a local JSON pointer.") }
        if path == "#" { return root }
        guard path.hasPrefix("#/") else { throw invalid("Only local JSON schema references are supported.") }
        var value = root
        for component in path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let next = value.objectValue?[key] {
                value = next
            } else if let items = value.arrayValue, let index = Int(key), String(index) == key, items.indices.contains(index) {
                value = items[index]
            } else {
                throw invalid("Unresolved schema reference \(path).")
            }
        }
        return value
    }

    private static func invalid(_ message: String) -> AgentRuntimeError {
        .init(code: .structuredOutputSchemaInvalid, message: message)
    }
}
