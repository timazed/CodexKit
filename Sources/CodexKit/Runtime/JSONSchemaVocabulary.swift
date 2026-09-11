enum JSONSchemaValueType: String {
    case string, integer, number, boolean, array, object, null
}

enum JSONSchemaKeyword: String {
    case schema = "$schema"
    case id = "$id"
    case comment = "$comment"
    case title, description, `default`, examples, deprecated, readOnly, writeOnly
    case type, properties, required, additionalProperties, items, `enum`, const
    case anyOf, oneOf, allOf, not
    case defs = "$defs"
    case definitions
    case ref = "$ref"
    case minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf
    case minLength, maxLength, minItems, maxItems, uniqueItems, minProperties, maxProperties
}

enum JSONSchemaComposition: String, CaseIterable {
    case allOf, anyOf, oneOf

    func accepts(matches: Int, branchCount: Int) -> Bool {
        switch self {
        case .allOf: matches == branchCount
        case .anyOf: matches > 0
        case .oneOf: matches == 1
        }
    }
}

enum JSONSchemaNumericBound: String, CaseIterable {
    case minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf

    func accepts(_ number: Double, limit: Double) -> Bool {
        switch self {
        case .minimum: return number >= limit
        case .maximum: return number <= limit
        case .exclusiveMinimum: return number > limit
        case .exclusiveMaximum: return number < limit
        case .multipleOf:
            let quotient = number / limit
            return quotient.isFinite && abs(quotient - quotient.rounded()) <= max(1, abs(quotient)) * 1e-12
        }
    }
}
