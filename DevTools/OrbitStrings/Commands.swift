import Foundation

/// Command-line options: `--name value` pairs and `--flag` switches.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, flags knownFlags: Set<String> = []) throws {
        var remaining = arguments
        while let argument = remaining.popFirst() {
            guard argument.hasPrefix("--") else { throw ToolError.usage("unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            if knownFlags.contains(name) {
                flags.insert(name)
            } else {
                guard let value = remaining.popFirst() else { throw ToolError.usage("\(argument) needs a value") }
                values[name] = value
            }
        }
    }

    func value(_ name: String) -> String? { values[name] }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw ToolError.usage("missing --\(name)") }
        return value
    }

    func url(_ name: String) throws -> URL {
        URL(fileURLWithPath: try required(name))
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message), .failed(let message): message
        }
    }
}

/// Collects diagnostics in the `file:line: error: message` format Xcode and
/// most editors understand.
struct Diagnostics {
    private(set) var errors = 0
    private(set) var warnings = 0

    mutating func error(_ message: String, file: String? = nil, line: Int? = nil) {
        errors += 1
        printError(Self.format("error", message, file: file, line: line))
    }

    mutating func warning(_ message: String, file: String? = nil, line: Int? = nil) {
        warnings += 1
        printError(Self.format("warning", message, file: file, line: line))
    }

    private static func format(_ kind: String, _ message: String, file: String?, line: Int?) -> String {
        switch (file, line) {
        case let (file?, line?): "\(file):\(line): \(kind): \(message)"
        case let (file?, nil): "\(file): \(kind): \(message)"
        default: "\(kind): \(message)"
        }
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printOutput(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

/// Shortens a key for messages.
func excerpt(_ key: String) -> String {
    let flat = key.replacingOccurrences(of: "\n", with: "⏎")
    return flat.count > 60 ? "\"\(flat.prefix(57))…\"" : "\"\(flat)\""
}

// MARK: - extract

enum ExtractCommand {
    static func run(_ options: Options) throws {
        let sources = try options.url("sources")
        let catalogURL = try options.url("catalog")
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let literals = try LiteralScanner.scan(directory: sources, relativeTo: base)

        var catalog: StringCatalog
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            catalog = try StringCatalog(contentsOf: catalogURL)
        } else {
            catalog = StringCatalog(sourceLanguage: options.value("source-language") ?? "en")
        }
        let result = catalog.merge(literals)
        let wrote = try catalog.write(to: catalogURL)

        let interpolated = literals.filter(\.hasInterpolation)
        for literal in interpolated {
            printError("\(literal.file):\(literal.line): warning: skipped \(literal.call) literal with string interpolation (see lint)")
        }
        for key in result.added { printOutput("+ \(excerpt(key))") }
        for key in result.revived { printOutput("↺ \(excerpt(key)) (used again)") }
        for key in result.markedStale { printOutput("- \(excerpt(key)) (stale: no longer in the sources)") }
        let keyCount = Set(literals.filter { !$0.hasInterpolation }.map(\.key)).count
        printOutput("\(catalogURL.lastPathComponent): \(keyCount) keys in \(sources.lastPathComponent)/, "
            + "\(result.added.count) added, \(result.markedStale.count) marked stale"
            + (wrote ? "" : ", unchanged"))
    }
}

// MARK: - compile

enum CompileCommand {
    static func run(_ options: Options) throws {
        let catalogURL = try options.url("catalog")
        let output = try options.url("output")
        let table = options.value("table") ?? catalogURL.deletingPathExtension().lastPathComponent
        let catalog = try StringCatalog(contentsOf: catalogURL)

        var languages: [String]
        if let list = options.value("languages") {
            languages = languageList(list)
        } else {
            var found = Set([catalog.sourceLanguage] + StringCatalog.shippedLanguages)
            for key in catalog.keys {
                if let localizations = catalog.entry(key)?["localizations"] as? [String: Any] {
                    found.formUnion(localizations.keys)
                }
            }
            languages = found.sorted()
        }

        for language in languages {
            var entries: [(key: String, value: String, comment: String?)] = []
            for key in catalog.keys {
                if catalog.hasVariations(key, language: language) {
                    printError("warning: \(excerpt(key)) uses variations, which .strings cannot express; skipped for \(language)")
                    continue
                }
                guard let value = catalog.resolvedValue(key, language: language) else { continue }
                entries.append((key, value, catalog.comment(key)))
            }
            let directory = output.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(table).strings")
            let text = StringsFile.render(entries: entries, source: catalogURL.lastPathComponent)
            try Data(text.utf8).write(to: file, options: .atomic)
            printOutput("\(language).lproj/\(table).strings: \(entries.count) of \(catalog.keys.count) strings")
        }
    }
}

// MARK: - lint

enum LintCommand {
    /// Returns whether the check passed (no errors; with --strict no warnings).
    static func run(_ options: Options) throws -> Bool {
        let catalogURL = try options.url("catalog")
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        // Without --sources only the catalog itself is checked (e.g. InfoPlist.xcstrings).
        let literals = try options.value("sources").map {
            try LiteralScanner.scan(directory: URL(fileURLWithPath: $0), relativeTo: base)
        } ?? []
        let catalog = try StringCatalog(contentsOf: catalogURL)
        let targetLanguages = (options.value("languages").map(languageList) ?? StringCatalog.shippedLanguages)
            .filter { $0 != catalog.sourceLanguage }
        var diagnostics = Diagnostics()

        for literal in literals where literal.hasInterpolation {
            diagnostics.error(
                "localized \(literal.call) literal contains string interpolation: \(excerpt(literal.key)). "
                    + "Use a format specifier (String(format: String(localized: \"… %@\"), value)) or Text(verbatim:) for non-translatable text.",
                file: literal.file, line: literal.line)
        }

        var firstLocation: [String: LocalizableLiteral] = [:]
        for literal in literals where !literal.hasInterpolation && firstLocation[literal.key] == nil {
            firstLocation[literal.key] = literal
        }
        for (key, literal) in firstLocation.sorted(by: { $0.key < $1.key }) where !catalog.contains(key) {
            diagnostics.warning("\(excerpt(key)) is not in \(catalogURL.lastPathComponent); run OrbitStrings extract",
                                file: literal.file, line: literal.line)
        }

        for key in catalog.keys {
            let isStale = catalog.extractionState(key) == "stale"
            let sourceArguments = FormatSpecifiers.arguments(in: catalog.resolvedValue(key, language: catalog.sourceLanguage) ?? key)
            for language in languages(of: catalog, key: key) where language != catalog.sourceLanguage {
                guard let translation = catalog.translation(key, language: language) else { continue }
                let translatedArguments = FormatSpecifiers.arguments(in: translation)
                if translatedArguments != sourceArguments {
                    diagnostics.error("format specifiers of the \(language) translation of \(excerpt(key)) do not match the key "
                        + "(\(describe(sourceArguments)) vs. \(describe(translatedArguments)))", file: catalogURL.path)
                }
            }
            for language in targetLanguages where !isStale && catalog.shouldTranslate(key)
                && catalog.translation(key, language: language) == nil {
                let location = firstLocation[key]
                diagnostics.warning("\(excerpt(key)) has no \(language) translation", file: location?.file ?? catalogURL.path,
                                    line: location?.line)
            }
            // Orbit's texts do without dashes as punctuation: no en dash, no em dash.
            for (language, text) in [(catalog.sourceLanguage, key)] + languages(of: catalog, key: key).compactMap({ language in
                catalog.stringUnit(key, language: language).map { (language, $0.value) }
            }) where text.unicodeScalars.contains(where: Self.dashes.contains) {
                diagnostics.error("the \(language) text of \(excerpt(key)) contains a dash (U+2013 or U+2014); "
                    + "rephrase it with a comma, colon, period or parentheses", file: catalogURL.path)
            }
        }

        let strict = options.has("strict")
        let passed = diagnostics.errors == 0 && (!strict || diagnostics.warnings == 0)
        printOutput("lint: \(Set(literals.map(\.key)).count) localized literals, \(catalog.keys.count) catalog keys, "
            + "\(diagnostics.errors) errors, \(diagnostics.warnings) warnings")
        return passed
    }

    /// En dash and em dash.
    static let dashes: Set<Unicode.Scalar> = ["\u{2013}", "\u{2014}"]

    private static func languages(of catalog: StringCatalog, key: String) -> [String] {
        ((catalog.entry(key)?["localizations"] as? [String: Any])?.keys).map { Array($0).sorted() } ?? []
    }

    private static func describe(_ arguments: [Int: String]) -> String {
        arguments.isEmpty ? "none" : arguments.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }
}

// MARK: - untranslated / translate

enum UntranslatedCommand {
    /// Prints `{"key": ""}` for every key without a translation, ready to be
    /// filled in and passed to `translate`.
    static func run(_ options: Options) throws {
        let catalog = try StringCatalog(contentsOf: try options.url("catalog"))
        let language = options.value("language") ?? catalog.defaultTargetLanguage
        var missing: [String: String] = [:]
        for key in catalog.keys where catalog.extractionState(key) != "stale" && catalog.shouldTranslate(key)
            && catalog.translation(key, language: language) == nil {
            missing[key] = ""
        }
        let data = try JSONSerialization.data(withJSONObject: missing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        printOutput(String(decoding: data, as: UTF8.self))
    }
}

enum TranslateCommand {
    /// Merges `{"key": "translation"}` from a JSON file (or `-` for stdin).
    static func run(_ options: Options) throws {
        let catalogURL = try options.url("catalog")
        let input = try options.required("input")
        let data = input == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: input))
        guard let translations = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ToolError.failed("--input must be a JSON object of strings")
        }
        var catalog = try StringCatalog(contentsOf: catalogURL)
        let language = options.value("language") ?? catalog.defaultTargetLanguage
        var applied = 0
        for (key, value) in translations.sorted(by: { $0.key < $1.key }) {
            guard catalog.contains(key) else { throw ToolError.failed("unknown key \(excerpt(key)); run extract first") }
            guard !value.isEmpty else { continue }
            catalog.setTranslation(value, for: key, language: language)
            applied += 1
        }
        try catalog.write(to: catalogURL)
        printOutput("\(catalogURL.lastPathComponent): \(applied) \(language) translations applied")
    }
}

/// Splits a comma-separated language list ("de,en").
func languageList(_ list: String) -> [String] {
    list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - rekey

enum RekeyCommand {
    /// Replaces localized literals in Swift sources by new keys from a JSON
    /// object {"old key": "new key"}, e.g. when the source language changes.
    /// Literals elsewhere that equal an old key are only listed, unless
    /// --all-literals replaces them too (for tests that compare texts).
    static func run(_ options: Options) throws {
        let sources = try options.url("sources")
        let data = try Data(contentsOf: try options.url("map"))
        guard let map = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ToolError.failed("--map must be a JSON object of strings")
        }
        // A new key that is also an old key would be replaced again by a second
        // run ("Beginn" → "Start", then "Start" → "Startup"): run such a map once only.
        for (old, new) in map.sorted(by: { $0.key < $1.key }) where new != old {
            if let next = map[new], next != new {
                printError("warning: \(excerpt(old)) → \(excerpt(new)) → \(excerpt(next)): run this map only once")
            }
        }
        let allLiterals = options.has("all-literals")
        let dryRun = options.has("dry-run")
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var localizedCount = 0
        var otherCount = 0
        var changedFiles = 0

        for file in try LiteralScanner.swiftFiles(in: sources) {
            let path = LiteralScanner.relativePath(of: file, to: base)
            let source = try String(contentsOf: file, encoding: .utf8)
            var replacements: [(range: Range<Int>, key: String)] = []
            var localizedStarts: Set<Int> = []
            for literal in LiteralScanner.scan(source: source, file: path) where !literal.hasInterpolation {
                guard let range = literal.range, let key = map[literal.key] else { continue }
                localizedStarts.insert(range.lowerBound)
                guard key != literal.key else { continue }
                replacements.append((range, key))
                localizedCount += 1
            }
            for token in SwiftLexer.tokenizeIncludingInterpolations(source).joined() {
                guard case .string(let literal) = token, !literal.hasInterpolation,
                      !localizedStarts.contains(literal.range.lowerBound),
                      let key = map[literal.value], key != literal.value else { continue }
                if allLiterals {
                    replacements.append((literal.range, key))
                    otherCount += 1
                    printOutput("\(path):\(literal.line): replaced \(excerpt(literal.value)) (not a localized position)")
                } else {
                    printOutput("\(path):\(literal.line): note: \(excerpt(literal.value)) equals a key outside a localized position, kept")
                }
            }
            guard !replacements.isEmpty else { continue }
            changedFiles += 1
            var scalars = Array(source.unicodeScalars)
            for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                scalars.replaceSubrange(replacement.range, with: Array(swiftLiteral(replacement.key).unicodeScalars))
            }
            if !dryRun {
                var text = ""
                text.unicodeScalars.append(contentsOf: scalars)
                try Data(text.utf8).write(to: file, options: .atomic)
            }
        }
        printOutput("rekey: \(localizedCount) localized literals and \(otherCount) other literals in \(changedFiles) files"
            + (dryRun ? " (dry run, nothing written)" : ""))
    }

    /// `value` as a single-line Swift string literal.
    static func swiftLiteral(_ value: String) -> String {
        var literal = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case "\t": literal += "\\t"
            case let control where control.value < 0x20 || control.value == 0x7F:
                literal += "\\u{\(String(control.value, radix: 16, uppercase: true))}"
            default:
                literal.unicodeScalars.append(scalar)
            }
        }
        return literal + "\""
    }
}
