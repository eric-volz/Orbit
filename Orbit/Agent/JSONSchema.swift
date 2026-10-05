import Foundation

/// The subset of JSON Schema Orbit's tools use, with validation and lenient
/// normalization of model-produced arguments.
///
/// Example:
/// ```swift
/// .object(properties: [
///     "query": .string(description: "Words to search for."),
///     "kind": .string(description: "File type.", enumValues: ["pdf", "image"]),
///     "limit": .integer(description: "Max results.", minimum: 1, maximum: 50),
///     "modified_after": .string(description: "ISO 8601 date.", format: .dateTime),
/// ], required: ["query"])
/// ```
indirect enum JSONSchema: Sendable, Hashable {
    enum StringFormat: String, Sendable, Hashable {
        /// A date with optional time, see `FlexibleDate`.
        case dateTime = "date-time"
        case uri
    }

    case string(description: String? = nil, enumValues: [String]? = nil, format: StringFormat? = nil,
                minLength: Int? = nil, maxLength: Int? = nil)
    case integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil)
    case number(description: String? = nil, minimum: Double? = nil, maximum: Double? = nil)
    case boolean(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil, minItems: Int? = nil, maxItems: Int? = nil)
    case object(properties: [String: JSONSchema], required: [String] = [], description: String? = nil)

    /// An object schema with no parameters.
    static var empty: JSONSchema { .object(properties: [:]) }

    // MARK: JSON representation

    /// The schema as sent to the model (`input_schema` / `parameters`).
    var jsonValue: JSONValue {
        var result: [String: JSONValue] = [:]
        switch self {
        case let .string(description, enumValues, format, minLength, maxLength):
            result["type"] = "string"
            if let description { result["description"] = .string(description) }
            if let enumValues { result["enum"] = .array(enumValues.map(JSONValue.string)) }
            if let format {
                // "date-time" in JSON Schema requires a full timestamp; we accept more,
                // so describe the format instead of declaring it.
                if format == .uri { result["format"] = "uri" }
            }
            if let minLength { result["minLength"] = .number(Double(minLength)) }
            if let maxLength { result["maxLength"] = .number(Double(maxLength)) }
        case let .integer(description, minimum, maximum):
            result["type"] = "integer"
            if let description { result["description"] = .string(description) }
            if let minimum { result["minimum"] = .number(Double(minimum)) }
            if let maximum { result["maximum"] = .number(Double(maximum)) }
        case let .number(description, minimum, maximum):
            result["type"] = "number"
            if let description { result["description"] = .string(description) }
            if let minimum { result["minimum"] = .number(minimum) }
            if let maximum { result["maximum"] = .number(maximum) }
        case let .boolean(description):
            result["type"] = "boolean"
            if let description { result["description"] = .string(description) }
        case let .array(items, description, minItems, maxItems):
            result["type"] = "array"
            result["items"] = items.jsonValue
            if let description { result["description"] = .string(description) }
            if let minItems { result["minItems"] = .number(Double(minItems)) }
            if let maxItems { result["maxItems"] = .number(Double(maxItems)) }
        case let .object(properties, required, description):
            result["type"] = "object"
            result["properties"] = .object(properties.mapValues(\.jsonValue))
            if !required.isEmpty { result["required"] = .array(required.sorted().map(JSONValue.string)) }
            if let description { result["description"] = .string(description) }
            result["additionalProperties"] = false
        }
        return .object(result)
    }

    // MARK: Validation

    struct ValidationResult: Sendable, Hashable {
        /// The normalized value (renamed keys, coerced scalars, nulls removed).
        var value: JSONValue
        /// Human-readable problems, phrased for the model. Empty when valid.
        var errors: [String]

        var isValid: Bool { errors.isEmpty }
    }

    /// Validates `value`, first normalizing what a model plausibly meant:
    /// - property names differing only in case, `_`/`-` or camelCase are renamed,
    /// - `null` for optional properties is treated as absent,
    /// - numeric strings become numbers, "true"/"false" become booleans,
    /// - a single value where an array is expected becomes a one-element array.
    func validate(_ value: JSONValue) -> ValidationResult {
        var errors: [String] = []
        let normalized = normalize(value, path: "", errors: &errors)
        return ValidationResult(value: normalized, errors: errors)
    }

    private func normalize(_ value: JSONValue, path: String, errors: inout [String]) -> JSONValue {
        let location = path.isEmpty ? "input" : "'\(path)'"
        switch self {
        case let .string(_, enumValues, format, minLength, maxLength):
            var text: String
            switch value {
            case .string(let string): text = string
            case .number, .bool:
                // Accept scalars where a string is expected ("limit": 5 → "5").
                text = value.jsonString()
            default:
                errors.append("\(location) must be a string, got \(value.typeName).")
                return value
            }
            if let enumValues {
                if !enumValues.contains(text) {
                    if let match = enumValues.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                        text = match
                    } else {
                        errors.append("\(location) must be one of: \(enumValues.joined(separator: ", ")). Got '\(text)'.")
                    }
                }
            }
            if format == .dateTime, FlexibleDate.parse(text) == nil {
                errors.append("\(location) must be an ISO 8601 date like 2026-03-01 or 2026-03-01T14:30:00. Got '\(text)'.")
            }
            if format == .uri, URL(string: text)?.scheme == nil {
                errors.append("\(location) must be an absolute URL. Got '\(text)'.")
            }
            if let minLength, text.count < minLength {
                errors.append("\(location) must have at least \(minLength) characters.")
            }
            if let maxLength, text.count > maxLength {
                errors.append("\(location) must have at most \(maxLength) characters.")
            }
            return .string(text)

        case let .integer(_, minimum, maximum):
            let number: Double?
            switch value {
            case .number(let double): number = double
            case .string(let string): number = Double(string.trimmingCharacters(in: .whitespaces))
            default: number = nil
            }
            guard let number, number.rounded() == number else {
                errors.append("\(location) must be an integer, got \(value.typeName).")
                return value
            }
            if let minimum, number < Double(minimum) {
                errors.append("\(location) must be at least \(minimum).")
            }
            if let maximum, number > Double(maximum) {
                errors.append("\(location) must be at most \(maximum).")
            }
            return .number(number)

        case let .number(_, minimum, maximum):
            let number: Double?
            switch value {
            case .number(let double): number = double
            case .string(let string): number = Double(string.trimmingCharacters(in: .whitespaces))
            default: number = nil
            }
            guard let number, number.isFinite else {
                errors.append("\(location) must be a number, got \(value.typeName).")
                return value
            }
            if let minimum, number < minimum {
                errors.append("\(location) must be at least \(minimum).")
            }
            if let maximum, number > maximum {
                errors.append("\(location) must be at most \(maximum).")
            }
            return .number(number)

        case .boolean:
            switch value {
            case .bool: return value
            case .string(let string) where ["true", "false"].contains(string.lowercased()):
                return .bool(string.lowercased() == "true")
            case .number(let number) where number == 0 || number == 1:
                return .bool(number == 1)
            default:
                errors.append("\(location) must be a boolean, got \(value.typeName).")
                return value
            }

        case let .array(items, _, minItems, maxItems):
            let elements: [JSONValue]
            switch value {
            case .array(let array): elements = array
            case .null:
                errors.append("\(location) must be an array, got null.")
                return value
            default: elements = [value]
            }
            if let minItems, elements.count < minItems {
                errors.append("\(location) must have at least \(minItems) items.")
            }
            if let maxItems, elements.count > maxItems {
                errors.append("\(location) must have at most \(maxItems) items.")
            }
            return .array(elements.enumerated().map { index, element in
                items.normalize(element, path: "\(path)[\(index)]", errors: &errors)
            })

        case let .object(properties, required, _):
            let object: [String: JSONValue]
            switch value {
            case .object(let dictionary): object = dictionary
            case .null where path.isEmpty: object = [:]
            case .string(let string) where path.isEmpty:
                // Some models double-encode the arguments object as a string.
                if case .object(let decoded)? = try? JSONValue.parse(string) {
                    object = decoded
                } else {
                    errors.append("\(location) must be an object, got string.")
                    return value
                }
            default:
                errors.append("\(location) must be an object, got \(value.typeName).")
                return value
            }

            var result: [String: JSONValue] = [:]
            for (key, element) in object {
                let resolvedKey: String
                if properties[key] != nil {
                    resolvedKey = key
                } else if let match = Self.matchPropertyName(key, in: Array(properties.keys)) {
                    resolvedKey = match
                } else {
                    let known = properties.keys.sorted().joined(separator: ", ")
                    errors.append("Unknown parameter '\(Self.join(path, key))'." + (known.isEmpty ? " This tool takes no parameters." : " Expected parameters: \(known)."))
                    continue
                }
                if element.isNull && !required.contains(resolvedKey) { continue }
                guard let schema = properties[resolvedKey] else { continue }
                result[resolvedKey] = schema.normalize(element, path: Self.join(path, resolvedKey), errors: &errors)
            }
            for key in required.sorted() where result[key] == nil || result[key]?.isNull == true {
                errors.append("Missing required parameter '\(Self.join(path, key))'.")
            }
            return .object(result)
        }
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    /// Finds the property a slightly misspelled key most plausibly means:
    /// same letters ignoring case, underscores, dashes and spaces. Returns nil
    /// when the match is missing or ambiguous.
    static func matchPropertyName(_ key: String, in candidates: [String]) -> String? {
        func canonical(_ string: String) -> String {
            string.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let target = canonical(key)
        let matches = candidates.filter { canonical($0) == target }
        return matches.count == 1 ? matches[0] : nil
    }
}
