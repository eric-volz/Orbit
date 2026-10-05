import Foundation

/// A minimal JSON value for the fake server. Objects keep their key order, so
/// responses read like the real APIs (`"type"` first), and serialization is
/// compact and deterministic (one line, no escaped slashes).
enum JSON: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([(key: String, value: JSON)])
}

// MARK: - Accessors

extension JSON {
    subscript(key: String) -> JSON? {
        guard case .object(let members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 9e15 else { return nil }
        return Int(value)
    }

    var arrayValue: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

// MARK: - Literals

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(elements.map { (key: $0.0, value: $0.1) })
    }

    static func int(_ value: Int) -> JSON { .number(Double(value)) }

    /// `.string(value)` or `.null`.
    static func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
}

// MARK: - Parsing

extension JSON {
    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    /// Parses JSON text (top-level scalars allowed). Object keys are sorted,
    /// since Foundation's parser does not preserve their order.
    static func parse(_ data: Data) throws -> JSON {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ParseError(description: "invalid JSON")
        }
        guard let value = JSON(foundation: object) else { throw ParseError(description: "unsupported JSON value") }
        return value
    }

    private init?(foundation value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber bridges booleans; tell them apart by their CF type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var elements: [JSON] = []
            elements.reserveCapacity(array.count)
            for element in array {
                guard let converted = JSON(foundation: element) else { return nil }
                elements.append(converted)
            }
            self = .array(elements)
        case let dictionary as [String: Any]:
            var members: [(key: String, value: JSON)] = []
            for key in dictionary.keys.sorted() {
                guard let converted = JSON(foundation: dictionary[key] as Any) else { return nil }
                members.append((key: key, value: converted))
            }
            self = .object(members)
        default:
            return nil
        }
    }
}

// MARK: - Serialization

extension JSON {
    /// Compact single-line JSON text.
    var serialized: String {
        var output = ""
        write(to: &output)
        return output
    }

    var serializedData: Data { Data(serialized.utf8) }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let value):
            output += Self.format(value)
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                element.write(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                Self.writeString(member.key, to: &output)
                output += ":"
                member.value.write(to: &output)
            }
            output += "}"
        }
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case let control where control.value < 0x20:
                output += String(format: "\\u%04x", control.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
