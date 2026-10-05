import Foundation
import Testing

/// Checks the String Catalogs and the localizable literals in the sources.
/// Self-contained on purpose: the OrbitStrings tool is an executable target
/// the test target cannot link (`OrbitStrings lint` performs the same checks).
@Suite("Localization")
struct LocalizationTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let resources = repository.appendingPathComponent("Orbit/Resources")

    // MARK: Catalogs

    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func catalogIsValidWithEnglishSource(name: String) throws {
        let catalog = try Self.catalog(name)
        #expect(catalog["sourceLanguage"] as? String == "en")
        #expect(catalog["version"] as? String == "1.0")
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(!strings.isEmpty)
        for (key, value) in strings {
            let entry = try #require(value as? [String: Any], "\(key): entry must be an object")
            guard let localizations = entry["localizations"] as? [String: Any] else { continue }
            for (language, localization) in localizations {
                let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["value"] is String, "\(name): \(key) [\(language)] needs stringUnit.value")
                #expect(unit?["state"] is String, "\(name): \(key) [\(language)] needs stringUnit.state")
            }
        }
    }

    @Test func infoPlistCatalogMatchesInfoPlist() throws {
        let data = try Data(contentsOf: Self.repository.appendingPathComponent("Config/Info.plist"))
        let infoPlist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let strings = try #require(try Self.catalog("InfoPlist.xcstrings")["strings"] as? [String: Any])

        let localizedKeys = infoPlist.keys.filter { $0.hasSuffix("UsageDescription") } + ["CFBundleDisplayName"]
        for key in localizedKeys {
            let english = Self.value(in: strings, key: key, language: "en")
            #expect(english == infoPlist[key] as? String, "InfoPlist.xcstrings \(key) [en] must equal Config/Info.plist")
            let german = try #require(Self.value(in: strings, key: key, language: "de"), "\(key) needs a German translation")
            #expect(!german.isEmpty)
        }
        for key in strings.keys {
            #expect(infoPlist[key] != nil, "\(key) is not a key of Config/Info.plist")
        }
    }

    /// Instant search looks at files in these folders while the user types, so
    /// macOS may ask for access then. The reason must say so.
    @Test func folderAccessReasonsMentionSearchingWhileTyping() throws {
        let strings = try #require(try Self.catalog("InfoPlist.xcstrings")["strings"] as? [String: Any])
        for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription"] {
            let german = try #require(Self.value(in: strings, key: key, language: "de"))
            let english = try #require(Self.value(in: strings, key: key, language: "en"))
            #expect(german.contains("durchsucht") && german.contains("schon beim Tippen"), "\(key)")
            #expect(english.contains("searches") && english.contains("as you type"), "\(key)")
        }
    }

    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func translationsKeepTheFormatSpecifiers(name: String) throws {
        let strings = try #require(try Self.catalog(name)["strings"] as? [String: Any])
        for key in strings.keys.sorted() {
            let source = Self.value(in: strings, key: key, language: "en") ?? key
            guard let german = Self.value(in: strings, key: key, language: "de") else { continue }
            #expect(Self.formatArguments(german) == Self.formatArguments(source),
                    "\(name): format specifiers of \"\(german)\" differ from \"\(source)\"")
        }
    }

    /// Every text the interface can show has a German value (`OrbitStrings lint` warns about the same).
    @Test func everyKeyHasAGermanTranslation() throws {
        let strings = try #require(try Self.catalog("Localizable.xcstrings")["strings"] as? [String: Any])
        var missing: [String] = []
        for (key, value) in strings {
            let entry = value as? [String: Any]
            guard entry?["extractionState"] as? String != "stale", entry?["shouldTranslate"] as? Bool != false else { continue }
            let unit = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let state = unit?["state"] as? String ?? "translated"
            if (unit?["value"] as? String ?? "").isEmpty || !["translated", "needs_review"].contains(state) {
                missing.append(key)
            }
        }
        #expect(missing.sorted() == [], "keys without a German value")
    }

    /// English follows macOS's conventions: "…" right after the word, curly
    /// quotes and apostrophes, "50%", none of the German typography. The
    /// English text is the key, or its own value where the key disambiguates.
    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func englishUsesEnglishTypography(name: String) throws {
        let strings = try #require(try Self.catalog(name)["strings"] as? [String: Any])
        for key in strings.keys.sorted() {
            let english = Self.value(in: strings, key: key, language: "en") ?? key
            #expect(!english.contains("„") && !english.contains("‚"), "\(name): German quotes in \"\(english)\"")
            #expect(!english.contains(" …") && !english.contains("..."), "\(name): \"\(english)\": write “Word…”")
            #expect(!english.contains("'") && !english.contains("\""), "\(name): straight quotes in \"\(english)\"")
            #expect(!english.contains(" %%"), "\(name): \"\(english)\": English writes “50%”")
        }
    }

    /// Orbit's texts do without en and em dashes, in both languages
    /// (`OrbitStrings lint` fails on them as well).
    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func noTextUsesADash(name: String) throws {
        let strings = try #require(try Self.catalog(name)["strings"] as? [String: Any])
        let dashes = CharacterSet(charactersIn: "\u{2013}\u{2014}")
        for key in strings.keys.sorted() {
            var texts = [key]
            for language in ["en", "de"] {
                if let value = Self.value(in: strings, key: key, language: language) { texts.append(value) }
            }
            for text in texts {
                #expect(text.rangeOfCharacter(from: dashes) == nil, "\(name): dash in \"\(text)\"")
            }
        }
    }

    // MARK: Sources

    /// German text reaches the interface only through the catalog's German
    /// translations: the sources hold English keys. A literal with German
    /// letters or quotes is a mistake unless it describes a tool or parameter
    /// to the model (English, quoting what users say: "Nicht stören an"). The
    /// files listed hold data, not interface text: names Mail, Notes and HTML
    /// use, quote characters a parser strips, invented sample data.
    @Test func germanTextStaysInTheCatalog() throws {
        let allowed: Set<String> = [
            "MailText.swift",            // mailbox names in many languages, quote characters
            "NotesService.swift",        // "Recently Deleted" in many languages
            "FileTextExtractor.swift",   // HTML character entities
            "FilePath.swift",            // quote characters around pasted paths
            "SearchTerms.swift",         // quote characters around phrases
            "LinkOrigin.swift",          // punctuation around links
        ]
        let accepted = ["description:String{", "description=", "description:"]
        let sources = Self.repository.appendingPathComponent("Orbit")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checkedFiles = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            checkedFiles += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for literal in Self.stringLiterals(in: source) where literal.text.rangeOfCharacter(from: Self.germanCharacters) != nil {
                let localized = accepted.contains { literal.context.hasSuffix($0) }
                #expect(localized, "\(url.lastPathComponent):\(literal.line): German text in the sources: \"\(literal.text)\"")
            }
        }
        #expect(checkedFiles > 100)
    }

    @Test func germanTextScannerFindsGermanLiterals() {
        let source = """
            Text("Öffnen")
            let a = String(localized: "Schließen")
            let title = "Übersicht"
            label: "Größe",
            // "Kommentar ä"
            Text(verbatim: "Grüße \\(name)")
            Text("Open")
            """
        let found = Self.stringLiterals(in: source).filter { literal in
            literal.text.rangeOfCharacter(from: Self.germanCharacters) != nil
        }
        #expect(found.map(\.line) == [1, 2, 3, 4, 6])
        #expect(found.first?.text == "Öffnen")
    }

    @Test func localizedLiteralsHaveNoInterpolation() throws {
        let sources = Self.repository.appendingPathComponent("Orbit")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checkedFiles = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            checkedFiles += 1
            for finding in Self.interpolatedLocalizedLiterals(in: source) {
                Issue.record("""
                    \(url.lastPathComponent):\(finding.line): localized literal with string interpolation after \(finding.call). \
                    Use String(format: String(localized: "… %@"), value) or Text(verbatim:).
                    """)
            }
        }
        #expect(checkedFiles > 0)
    }

    @Test func interpolationScannerFindsViolations() {
        let bad = """
            let a = String(localized: "Hallo \\(name)")
            Text("Treffer: \\(count)")
            view.help("Öffnet \\(file)")
            """
        #expect(Self.interpolatedLocalizedLiterals(in: bad).map(\.line) == [1, 2, 3])

        let fine = """
            // String(localized: "Kommentar \\(x)")
            /* Text("Block \\(x)") */
            Text(verbatim: "Datei \\(name)")
            let s = String(format: String(localized: "%lld Dateien"), count)
            Log.app.info("Gestartet \\(value)")
            let t = "Text(\\"x\\") \\(y)"
            myText("kein SwiftUI \\(x)")
            Text(#"roh \\(kein)"#)
            Text("escaped \\\\(kein)")
            """
        #expect(Self.interpolatedLocalizedLiterals(in: fine).isEmpty)
    }

    @Test func formatArgumentParsing() {
        #expect(Self.formatArguments("%lld Nachrichten") == [1: "llint"])
        #expect(Self.formatArguments("%2$@ vor %1$@") == [1: "@", 2: "@"])
        #expect(Self.formatArguments("100 %% sicher") == [:])
        #expect(Self.formatArguments("%d") != Self.formatArguments("%ld"))
    }

    // MARK: Helpers

    static func catalog(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: resources.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(name) is not a JSON object")
    }

    static func value(in strings: [String: Any], key: String, language: String) -> String? {
        let entry = strings[key] as? [String: Any]
        let localization = (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
        return (localization?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    /// printf-style arguments by position → normalized type ("@", "int", "llint", "double", …).
    static func formatArguments(_ string: String) -> [Int: String] {
        let pattern = #"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp%])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let text = string as NSString
        var result: [Int: String] = [:]
        var next = 1
        for match in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) {
            let conversion = text.substring(with: match.range(at: 3))
            if conversion == "%" { continue }
            let length = match.range(at: 2).location == NSNotFound ? "" : text.substring(with: match.range(at: 2))
            let position = match.range(at: 1).location == NSNotFound ? next : Int(text.substring(with: match.range(at: 1))) ?? next
            let type: String
            switch conversion {
            case "@": type = "@"
            case "d", "D", "i", "u", "U", "x", "X", "o", "O": type = (length == "q" ? "ll" : length) + "int"
            case "c", "C", "s", "S", "p": type = conversion.lowercased()
            default: type = length + "double"
            }
            result[position] = type
            next = position + 1
        }
        return result
    }

    /// Calls whose first string argument is localized (subset of OrbitStrings' list).
    static let localizedCalls = [
        "String(localized:", "LocalizedStringKey(", "LocalizedStringResource(", "Text(", "Button(", "Label(", "Toggle(",
        "Picker(", "TextField(", "SecureField(", "Section(", "Menu(", "LabeledContent(", "Recorder(", ".help(",
        ".navigationTitle(", ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(", ".confirmationDialog(",
        ".alert(",
    ]

    /// Finds string literals with `\(…)` passed directly to a localized call.
    static func interpolatedLocalizedLiterals(in source: String) -> [(line: Int, call: String)] {
        stringLiterals(in: source).compactMap { literal in
            guard literal.isInterpolated, let call = localizedCalls.first(where: { call in
                guard literal.context.hasSuffix(call) else { return false }
                // The call name must not be the end of a longer identifier (myText(…)).
                let before = literal.context.dropLast(call.count).last
                return call.hasPrefix(".") || before == nil || !(before!.isLetter || before!.isNumber || before! == "_")
            }) else { return nil }
            return (literal.line, call)
        }
    }

    /// German letters and quotes: a literal with one is German text (or data).
    static let germanCharacters = CharacterSet(charactersIn: "äöüÄÖÜß„")

    /// A string literal: its line, its text without interpolations, whether it
    /// has one, and the code right before it (whitespace removed).
    struct StringLiteral {
        var line: Int
        var text: String
        var isInterpolated: Bool
        var context: String
    }

    /// Every string literal of `source`. Understands comments, raw strings and
    /// nested interpolations.
    static func stringLiterals(in source: String) -> [StringLiteral] {
        let characters = Array(source)
        var literals: [StringLiteral] = []
        var recentCode = "" // code outside strings/comments, whitespace removed
        var line = 1
        var index = 0

        func at(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        /// Skips a string literal starting at `index` (at its first `#` or quote);
        /// returns its text and whether it contains an interpolation.
        func skipString() -> (text: String, interpolated: Bool) {
            var hashes = 0
            while at(0) == "#" { hashes += 1; index += 1 }
            let multiline = at(0) == "\"" && at(1) == "\"" && at(2) == "\""
            index += multiline ? 3 : 1
            let closing = String(repeating: "\"", count: multiline ? 3 : 1) + String(repeating: "#", count: hashes)
            var text = ""
            var interpolated = false
            while index < characters.count {
                if String(characters[index..<min(characters.count, index + closing.count)]) == closing {
                    index += closing.count
                    return (text, interpolated)
                }
                let character = characters[index]
                if character == "\n" { line += 1 }
                if character == "\\", (0..<hashes).allSatisfy({ at(1 + $0) == "#" }) {
                    index += 1 + hashes
                    if at(0) == "(" {
                        interpolated = true
                        var depth = 0
                        while index < characters.count {
                            let inner = characters[index]
                            if inner == "\"" || (inner == "#" && at(1) == "\"") {
                                _ = skipString()
                                continue
                            }
                            if inner == "\n" { line += 1 }
                            if inner == "(" { depth += 1 }
                            if inner == ")" {
                                depth -= 1
                                if depth == 0 { index += 1; break }
                            }
                            index += 1
                        }
                        continue
                    }
                    if let escaped = at(0) { text.append(escaped) }
                    index += 1 // escaped character
                    continue
                }
                text.append(character)
                index += 1
            }
            return (text, interpolated)
        }

        while index < characters.count {
            let character = characters[index]
            if character == "/" && at(1) == "/" {
                while index < characters.count && characters[index] != "\n" { index += 1 }
            } else if character == "/" && at(1) == "*" {
                var depth = 0
                repeat {
                    if at(0) == "/" && at(1) == "*" { depth += 1; index += 2 }
                    else if at(0) == "*" && at(1) == "/" { depth -= 1; index += 2 }
                    else { if at(0) == "\n" { line += 1 }; index += 1 }
                } while depth > 0 && index < characters.count
            } else if character == "\"" || (character == "#" && (at(1) == "\"" || at(1) == "#")) {
                let startLine = line
                let context = recentCode
                let (text, interpolated) = skipString()
                literals.append(StringLiteral(line: startLine, text: text, isInterpolated: interpolated, context: context))
                recentCode += "\""
            } else {
                if character == "\n" { line += 1 }
                if !character.isWhitespace { recentCode.append(character) }
                index += 1
            }
            if recentCode.count > 200 { recentCode = String(recentCode.suffix(100)) }
        }
        return literals
    }
}
