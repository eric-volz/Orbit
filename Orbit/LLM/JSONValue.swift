import Foundation

/// A Sendable representation of arbitrary JSON, used for tool arguments, JSON
/// schemas and provider wire formats.
///
/// Serialization is deterministic (sorted keys, no escaped slashes). This matters
/// for the Anthropic API: earlier turns must be sent back byte-for-byte identical
/// on every request, otherwise cached prefixes and thinking blocks are invalidated.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The value as an integer, if it is a number without a fractional part that
    /// fits into `Int` (2^63 does not, although `Double(Int.max)` rounds up to it).
    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// A short name of the JSON type, for validation messages ("string", "object", …).
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number(let value): value.rounded() == value ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Encode whole numbers as integers so `20` never becomes `20.0`.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Parsing and serialization

extension JSONValue {
    enum ParseError: Error, Equatable {
        case invalidJSON(String)
    }

    /// Parses JSON text. Top-level scalars are allowed.
    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    static func parse(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ParseError.invalidJSON(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// Deterministic JSON data (sorted keys, unescaped slashes).
    func jsonData(prettyPrinted: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a JSONValue cannot fail: every case maps to a JSON primitive.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    /// Deterministic JSON text (sorted keys, unescaped slashes).
    func jsonString(prettyPrinted: Bool = false) -> String {
        String(decoding: jsonData(prettyPrinted: prettyPrinted), as: UTF8.self)
    }

    /// Converts a value produced by `JSONSerialization` (or plain Swift collections).
    init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber bridges Bool; distinguish by the Objective-C type encoding.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var result: [JSONValue] = []
            result.reserveCapacity(array.count)
            for element in array {
                guard let converted = JSONValue(any: element) else { return nil }
                result.append(converted)
            }
            self = .array(result)
        case let dictionary as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, element) in dictionary {
                guard let converted = JSONValue(any: element) else { return nil }
                result[key] = converted
            }
            self = .object(result)
        default:
            return nil
        }
    }
}
