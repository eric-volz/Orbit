import Foundation

/// A String Catalog (`.xcstrings`). The JSON is kept as dictionaries so fields
/// this tool does not know (variations, substitutions, …) survive unchanged.
struct StringCatalog {
    enum CatalogError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let reason): reason
            }
        }
    }

    /// Translation states that count as translated (Xcode writes these).
    static let translatedStates: Set<String> = ["translated", "needs_review"]

    private(set) var root: [String: Any]

    init(sourceLanguage: String) {
        root = ["sourceLanguage": sourceLanguage, "strings": [String: Any](), "version": "1.0"]
    }

    init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalid("not a JSON object")
        }
        guard object["sourceLanguage"] is String else { throw CatalogError.invalid("missing sourceLanguage") }
        guard object["strings"] == nil || object["strings"] is [String: Any] else {
            throw CatalogError.invalid("strings must be an object")
        }
        root = object
        if root["strings"] == nil { root["strings"] = [String: Any]() }
    }

    init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CatalogError.invalid("cannot read \(url.path)")
        }
        do {
            try self.init(data: data)
        } catch let error as CatalogError {
            throw CatalogError.invalid("\(url.lastPathComponent): \(error)")
        }
    }

    /// The languages Orbit ships (Config/Info.plist, CFBundleLocalizations).
    static let shippedLanguages = ["en", "de"]

    var sourceLanguage: String { root["sourceLanguage"] as? String ?? "en" }

    /// The language `untranslated` and `translate` work on by default: the
    /// first shipped language that is not the source language.
    var defaultTargetLanguage: String {
        Self.shippedLanguages.first { $0 != sourceLanguage } ?? "de"
    }

    private var strings: [String: Any] {
        get { root["strings"] as? [String: Any] ?? [:] }
        set { root["strings"] = newValue }
    }

    var keys: [String] { strings.keys.sorted() }

    func contains(_ key: String) -> Bool { strings[key] != nil }

    func entry(_ key: String) -> [String: Any]? { strings[key] as? [String: Any] }

    private mutating func updateEntry(_ key: String, _ update: (inout [String: Any]) -> Void) {
        var entry = self.entry(key) ?? [:]
        update(&entry)
        strings[key] = entry
    }

    // MARK: Entry fields

    func extractionState(_ key: String) -> String? { entry(key)?["extractionState"] as? String }

    func comment(_ key: String) -> String? { entry(key)?["comment"] as? String }

    func shouldTranslate(_ key: String) -> Bool { entry(key)?["shouldTranslate"] as? Bool ?? true }

    /// The string unit of `language`, if the entry has one.
    func stringUnit(_ key: String, language: String) -> (value: String, state: String?)? {
        guard let localizations = entry(key)?["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String else { return nil }
        return (value, unit["state"] as? String)
    }

    /// Whether the entry uses plural/device variations (not expressible in .strings).
    func hasVariations(_ key: String, language: String) -> Bool {
        guard let localizations = entry(key)?["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any] else { return false }
        return localization["variations"] != nil || localization["substitutions"] != nil
    }

    /// The translation for `language`: a non-empty value in a translated state
    /// (or without a state, as in hand-written catalogs).
    func translation(_ key: String, language: String) -> String? {
        guard let unit = stringUnit(key, language: language), !unit.value.isEmpty else { return nil }
        if let state = unit.state, !Self.translatedStates.contains(state) { return nil }
        return unit.value
    }

    /// The text shown for `key` in `language`, following the compile rules.
    func resolvedValue(_ key: String, language: String) -> String? {
        if language == sourceLanguage || !shouldTranslate(key) {
            return stringUnit(key, language: sourceLanguage).map(\.value).flatMap { $0.isEmpty ? nil : $0 } ?? key
        }
        return translation(key, language: language)
    }

    mutating func setTranslation(_ value: String, for key: String, language: String, state: String = "translated") {
        updateEntry(key) { entry in
            var localizations = entry["localizations"] as? [String: Any] ?? [:]
            var localization = localizations[language] as? [String: Any] ?? [:]
            localization["stringUnit"] = ["state": state, "value": value]
            localizations[language] = localization
            entry["localizations"] = localizations
        }
    }

    // MARK: Extraction

    struct MergeResult: Equatable {
        var added: [String] = []
        var markedStale: [String] = []
        var revived: [String] = []
    }

    /// Adds keys found in the sources and marks keys that disappeared as
    /// stale. Translations are never touched; entries marked `manual` are kept
    /// as they are. Running it twice gives the same catalog.
    mutating func merge(_ literals: [LocalizableLiteral]) -> MergeResult {
        var result = MergeResult()
        var found: [String: LocalizableLiteral] = [:]
        for literal in literals where !literal.hasInterpolation {
            if var existing = found[literal.key] {
                existing.comment = existing.comment ?? literal.comment
                existing.defaultValue = existing.defaultValue ?? literal.defaultValue
                found[literal.key] = existing
            } else {
                found[literal.key] = literal
            }
        }

        for (key, literal) in found.sorted(by: { $0.key < $1.key }) {
            let isNew = !contains(key)
            if isNew { result.added.append(key) }
            if extractionState(key) == "stale" { result.revived.append(key) }
            updateEntry(key) { entry in
                if entry["extractionState"] as? String == "stale" {
                    entry["extractionState"] = nil
                }
                if let comment = literal.comment {
                    entry["comment"] = comment
                }
                if literal.defaultValue != nil, entry["extractionState"] == nil {
                    entry["extractionState"] = "extracted_with_value"
                }
            }
            if let defaultValue = literal.defaultValue, stringUnit(key, language: sourceLanguage) == nil {
                setTranslation(defaultValue, for: key, language: sourceLanguage, state: "new")
            }
        }

        for key in keys where found[key] == nil {
            let state = extractionState(key)
            guard state != "manual", state != "stale" else { continue }
            updateEntry(key) { $0["extractionState"] = "stale" }
            result.markedStale.append(key)
        }
        return result
    }

    // MARK: Serialization

    /// Xcode's formatting: two-space indentation, `"key" : value`, sorted keys.
    func serialized() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Writes the catalog if its content changed. Returns whether it wrote.
    @discardableResult
    func write(to url: URL) throws -> Bool {
        let data = try serialized()
        if let existing = try? Data(contentsOf: url), existing == data { return false }
        try data.write(to: url, options: .atomic)
        return true
    }
}

// MARK: - .strings files

enum StringsFile {
    /// A `.strings` file (UTF-8) with one `"key" = "value";` line per entry.
    static func render(entries: [(key: String, value: String, comment: String?)], source: String) -> String {
        var text = "/* Generated by OrbitStrings from \(source). Do not edit. */\n"
        for entry in entries {
            text += "\n"
            if let comment = entry.comment, !comment.isEmpty {
                text += "/* \(comment.replacingOccurrences(of: "*/", with: "* /")) */\n"
            }
            text += "\"\(escape(entry.key))\" = \"\(escape(entry.value))\";\n"
        }
        return text
    }

    /// Escapes a string for the old-style property list syntax of `.strings`.
    static func escape(_ string: String) -> String {
        var escaped = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case let control where control.value < 0x20 || control.value == 0x7F:
                escaped += String(format: "\\U%04X", control.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

// MARK: - Format specifiers

enum FormatSpecifiers {
    /// The printf-style arguments of a format string by 1-based position, as
    /// normalized types ("@", "int", "long long int", "double", …). `%%` is a
    /// literal percent sign.
    static func arguments(in string: String) -> [Int: String] {
        let characters = Array(string)
        var result: [Int: String] = [:]
        var nextPosition = 1
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else {
                index += 1
                continue
            }
            var cursor = index + 1
            if cursor < characters.count, characters[cursor] == "%" {
                index = cursor + 1
                continue
            }
            // Optional "n$" position.
            var position: Int?
            var digits = ""
            var lookahead = cursor
            while lookahead < characters.count, characters[lookahead].isASCII, characters[lookahead].isNumber {
                digits.append(characters[lookahead])
                lookahead += 1
            }
            if !digits.isEmpty, lookahead < characters.count, characters[lookahead] == "$" {
                position = Int(digits)
                cursor = lookahead + 1
            }
            while cursor < characters.count, "-+ #0'".contains(characters[cursor]) { cursor += 1 }
            while cursor < characters.count, characters[cursor] == "*" || (characters[cursor].isASCII && characters[cursor].isNumber) {
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "." {
                cursor += 1
                while cursor < characters.count, characters[cursor] == "*" || (characters[cursor].isASCII && characters[cursor].isNumber) {
                    cursor += 1
                }
            }
            var length = ""
            while cursor < characters.count, "hlqLztj".contains(characters[cursor]) {
                length.append(characters[cursor])
                cursor += 1
            }
            guard cursor < characters.count, let type = normalizedType(conversion: characters[cursor], length: length) else {
                index += 1
                continue
            }
            let argument = position ?? nextPosition
            result[argument] = type
            nextPosition = argument + 1
            index = cursor + 1
        }
        return result
    }

    private static func normalizedType(conversion: Character, length: String) -> String? {
        let size: String
        switch length {
        case "": size = ""
        case "hh": size = "char "
        case "h": size = "short "
        case "l": size = "long "
        case "ll", "q": size = "long long "
        case "L": size = "long double "
        case "z": size = "size "
        case "t": size = "ptrdiff "
        case "j": size = "intmax "
        default: return nil
        }
        switch conversion {
        case "@": return "@"
        case "d", "i", "D", "u", "U", "x", "X", "o", "O": return size + "int"
        case "f", "F", "e", "E", "g", "G", "a", "A": return size + "double"
        case "c", "C": return "char"
        case "s", "S": return "cstring"
        case "p": return "pointer"
        default: return nil
        }
    }
}
