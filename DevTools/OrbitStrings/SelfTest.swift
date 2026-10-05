import Foundation

/// Built-in checks for the scanner, the catalog merge and the formatters.
/// (The Orbit test target cannot link this executable target, so the logic is
/// verified here: `OrbitStrings self-test`.)
enum SelfTest {
    private struct Failure: Error {
        var message: String
    }

    static func run() -> Bool {
        var passed = 0
        var failures: [String] = []
        for (name, check) in checks {
            do {
                try check()
                passed += 1
            } catch let failure as Failure {
                failures.append("\(name): \(failure.message)")
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        for failure in failures { printError("FAIL \(failure)") }
        printOutput("self-test: \(passed) passed, \(failures.count) failed")
        return failures.isEmpty
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message: message()) }
    }

    private static func keys(_ source: String) -> [String] {
        LiteralScanner.scan(source: source, file: "Test.swift").map(\.key)
    }

    private static func expectKeys(_ source: String, _ expected: [String]) throws {
        let found = keys(source)
        try expect(found == expected, "\(source) → \(found), expected \(expected)")
    }

    private static let checks: [(String, @Sendable () throws -> Void)] = [
        ("initializers", {
            try expectKeys(#"Text("Hallo")"#, ["Hallo"])
            try expectKeys(#"Button("Abbrechen", role: .cancel) { cancel() }"#, ["Abbrechen"])
            try expectKeys(#"Label("Einstellungen", systemImage: "gear")"#, ["Einstellungen"])
            try expectKeys(#"Toggle("Beim Anmelden starten", isOn: $launch)"#, ["Beim Anmelden starten"])
            try expectKeys(#"Picker("Anbieter", selection: $provider) { }"#, ["Anbieter"])
            try expectKeys(#"TextField("Modell", text: $model, prompt: Text("z. B. gpt-oss:20b"))"#, ["Modell", "z. B. gpt-oss:20b"])
            try expectKeys(#"SecureField("API-Schlüssel", text: $key)"#, ["API-Schlüssel"])
            try expectKeys(#"Section("Allgemein") { }"#, ["Allgemein"])
            try expectKeys(#"Menu("Mehr") { }"#, ["Mehr"])
            try expectKeys(#"LabeledContent("Version", value: version)"#, ["Version"])
            try expectKeys(#"KeyboardShortcuts.Recorder("Tastenkürzel:", name: .togglePanel)"#, ["Tastenkürzel:"])
            try expectKeys(#"LocalizedStringKey("Schlüssel")"#, ["Schlüssel"])
            try expectKeys(#"SwiftUI.Text("Qualifiziert")"#, ["Qualifiziert"])
            try expectKeys("Button(\n    \"Mehrzeilig\",\n    action: run\n)", ["Mehrzeilig"])
        }),
        ("modifiers", {
            try expectKeys(#"view.help("Hilfe")"#, ["Hilfe"])
            try expectKeys(#"Image(systemName: "x").accessibilityLabel("Senden")"#, ["Senden"])
            try expectKeys(#".accessibilityLabel(Text("Senden"))"#, ["Senden"])
            try expectKeys(#".accessibilityHint("Öffnet die Einstellungen")"#, ["Öffnet die Einstellungen"])
            try expectKeys(#".navigationTitle("Einstellungen")"#, ["Einstellungen"])
            try expectKeys(#".confirmationDialog("Alle Chats löschen?", isPresented: $confirm) { }"#, ["Alle Chats löschen?"])
            try expectKeys(#".alert("Fehler", isPresented: $failed) { }"#, ["Fehler"])
            try expectKeys(#".searchable(text: $query, prompt: "Suchen")"#, ["Suchen"])
            try expectKeys(#"help("kein Modifier")"#, [])
        }),
        ("String(localized:)", {
            let found = LiteralScanner.scan(source: #"let s = String(localized: "Neuer Chat", comment: "Menü")"#, file: "A.swift")
            try expect(found.count == 1 && found[0].key == "Neuer Chat" && found[0].comment == "Menü", "\(found)")
            try expect(found[0].call == "String(localized:)", found[0].call)
            try expectKeys(#"String(format: String(localized: "%lld Nachrichten gefunden"), count)"#, ["%lld Nachrichten gefunden"])
            try expectKeys(#"String(localized: "x", table: "Other")"#, [])
            try expectKeys(#"String(localized: "y", table: "Localizable")"#, ["y"])
            try expectKeys(#"String(describing: "no")"#, [])
            try expectKeys(#"NSLocalizedString("Alt", comment: "c")"#, ["Alt"])
            let withDefault = LiteralScanner.scan(source: #"String(localized: "key.id", defaultValue: "Wert")"#, file: "A.swift")
            try expect(withDefault.first?.defaultValue == "Wert", "\(withDefault)")
        }),
        ("not localized", {
            try expectKeys(#"Text(verbatim: "Dateiname.pdf")"#, [])
            try expectKeys(#"Text(fileName)"#, [])
            try expectKeys(#"Text("a" + "b")"#, [])
            try expectKeys(#"Text("")"#, [])
            try expectKeys(#"Foo.Text("x")"#, [])
            try expectKeys(#"let label = "Text(\"nicht\")""#, [])
            try expectKeys("// Text(\"Kommentar\")\nText(\"Code\")", ["Code"])
            try expectKeys("/* Text(\"a\") /* nested */ Text(\"b\") */ Text(\"c\")", ["c"])
            try expectKeys("/// Doc: `Text(\"Beispiel\")`\nfunc f() {}", [])
        }),
        ("escapes and literal forms", {
            try expectKeys(#"Text("Sag \"Hallo\"")"#, [#"Sag "Hallo""#])
            try expectKeys(#"Text("Pfad \\ Ordner\tTab\nZeile")"#, ["Pfad \\ Ordner\tTab\nZeile"])
            try expectKeys(#"Text("\u{00E9}t\u{E9}")"#, ["\u{E9}t\u{E9}"])
            try expectKeys(##"Text(#"Roh "C:\"#)"##, [#"Roh "C:\"#])
            try expectKeys("String(localized: \"\"\"\n    Zeile 1\n      Zeile 2\n    \"\"\")", ["Zeile 1\n  Zeile 2"])
            try expectKeys("Text(\"Emoji 🚀 und Umlaute äöü\")", ["Emoji 🚀 und Umlaute äöü"])
        }),
        ("interpolation", {
            let found = LiteralScanner.scan(source: #"Text("Hallo \(name)")"#, file: "A.swift")
            try expect(found.count == 1 && found[0].hasInterpolation, "\(found)")
            let nested = LiteralScanner.scan(source: #"Text("a \(f("Text(\"x\")")) b")"#, file: "A.swift")
            try expect(nested.count == 1 && nested[0].hasInterpolation, "\(nested)")
            let raw = LiteralScanner.scan(source: ##"Text(#"a \(no) \#(yes)"#)"##, file: "A.swift")
            try expect(raw.count == 1 && raw[0].hasInterpolation, "\(raw)")
            let rawNone = LiteralScanner.scan(source: ##"Text(#"a \(no)"#)"##, file: "A.swift")
            try expect(rawNone.count == 1 && !rawNone[0].hasInterpolation && rawNone[0].key == #"a \(no)"#, "\(rawNone)")
            let escaped = LiteralScanner.scan(source: #"Text("kein \\(Aufruf)")"#, file: "A.swift")
            try expect(escaped.count == 1 && !escaped[0].hasInterpolation, "\(escaped)")
        }),
        ("inside interpolations", {
            try expectKeys(#"let s = "under '\(String(localized: "Permissions"))' tab""#, ["Permissions"])
            try expectKeys(#"Text(verbatim: "\(Text("Inner")) \(a("\(String(localized: "Deep"))"))")"#, ["Inner", "Deep"])
        }),
        ("line numbers", {
            let found = LiteralScanner.scan(source: "import SwiftUI\n\n/* x\n y */\nlet a = \"\"\"\n\n\"\"\"\nText(\"Zeile 8\")", file: "A.swift")
            try expect(found.first?.line == 8, "line \(String(describing: found.first?.line))")
        }),
        ("format specifiers", {
            try expect(FormatSpecifiers.arguments(in: "%lld Nachrichten") == [1: "long long int"], "lld")
            try expect(FormatSpecifiers.arguments(in: "%@ und %@") == [1: "@", 2: "@"], "@@")
            try expect(FormatSpecifiers.arguments(in: "%2$@ vor %1$@") == [1: "@", 2: "@"], "positional")
            try expect(FormatSpecifiers.arguments(in: "100 %% sicher") == [:], "%%")
            try expect(FormatSpecifiers.arguments(in: "%.1f MB") == [1: "double"], "%.1f")
            try expect(FormatSpecifiers.arguments(in: "%d") != FormatSpecifiers.arguments(in: "%lld"), "d vs lld")
            try expect(FormatSpecifiers.arguments(in: "Mit Auswahl: %@") == FormatSpecifiers.arguments(in: "With selection: %@"), "same")
            try expect(FormatSpecifiers.arguments(in: "kein Format") == [:], "none")
        }),
        (".strings escaping", {
            try expect(StringsFile.escape("a\"b\\c\nd\te") == #"a\"b\\c\nd\te"#, StringsFile.escape("a\"b\\c\nd\te"))
            try expect(StringsFile.escape("\u{1}") == #"\U0001"#, "control")
            let text = StringsFile.render(entries: [("Schlüssel \"x\"", "Wert", "Kommentar */ ende")], source: "T.xcstrings")
            try expect(text.contains(#""Schlüssel \"x\"" = "Wert";"#), text)
            try expect(text.contains("/* Kommentar * / ende */"), text)
            let plist = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: String]
            try expect(plist?["Schlüssel \"x\""] == "Wert", "parsed: \(String(describing: plist))")
        }),
        ("catalog merge", {
            var catalog = StringCatalog(sourceLanguage: "de")
            let literals = [
                LocalizableLiteral(key: "Neu", comment: nil, defaultValue: nil, hasInterpolation: false, file: "A.swift", line: 1, call: "Text"),
                LocalizableLiteral(key: "Alt", comment: "Kommentar", defaultValue: nil, hasInterpolation: false, file: "A.swift", line: 2, call: "Text"),
                LocalizableLiteral(key: "Hallo \\(x)", comment: nil, defaultValue: nil, hasInterpolation: true, file: "A.swift", line: 3, call: "Text"),
            ]
            let first = catalog.merge(literals)
            try expect(first.added == ["Alt", "Neu"], "added \(first.added)")
            catalog.setTranslation("New", for: "Neu", language: "en")
            let snapshot = try catalog.serialized()
            let second = catalog.merge(literals)
            try expect(second == StringCatalog.MergeResult(), "second merge \(second)")
            try expect(try catalog.serialized() == snapshot, "merge is not idempotent")
            try expect(catalog.comment("Alt") == "Kommentar", "comment")

            let third = catalog.merge(Array(literals.prefix(1)))
            try expect(third.markedStale == ["Alt"] && catalog.extractionState("Alt") == "stale", "stale \(third)")
            try expect(catalog.translation("Neu", language: "en") == "New", "translation kept")
            let fourth = catalog.merge(literals)
            try expect(fourth.revived == ["Alt"] && catalog.extractionState("Alt") == nil, "revived \(fourth)")

            catalog.setTranslation("Handarbeit", for: "Manuell", language: "de")
            var manual = catalog.entry("Manuell") ?? [:]
            manual["extractionState"] = "manual"
            var root = catalog.root
            var strings = root["strings"] as? [String: Any] ?? [:]
            strings["Manuell"] = manual
            root["strings"] = strings
            let reloaded = try StringCatalog(data: JSONSerialization.data(withJSONObject: root))
            var copy = reloaded
            _ = copy.merge(literals)
            try expect(copy.extractionState("Manuell") == "manual", "manual entries stay")
        }),
        ("compile rules", {
            var catalog = StringCatalog(sourceLanguage: "de")
            _ = catalog.merge([
                LocalizableLiteral(key: "Neu", comment: nil, defaultValue: nil, hasInterpolation: false, file: "A", line: 1, call: "Text"),
                LocalizableLiteral(key: "Offen", comment: nil, defaultValue: nil, hasInterpolation: false, file: "A", line: 2, call: "Text"),
            ])
            catalog.setTranslation("New", for: "Neu", language: "en")
            catalog.setTranslation("Draft", for: "Offen", language: "en", state: "new")
            try expect(catalog.resolvedValue("Neu", language: "de") == "Neu", "de = key")
            try expect(catalog.resolvedValue("Neu", language: "en") == "New", "en translated")
            try expect(catalog.resolvedValue("Offen", language: "en") == nil, "en state new is not a translation")
            catalog.setTranslation("Anzeigename", for: "CFBundleDisplayName", language: "de")
            try expect(catalog.resolvedValue("CFBundleDisplayName", language: "de") == "Anzeigename", "de translation wins")
        }),
    ]
}
