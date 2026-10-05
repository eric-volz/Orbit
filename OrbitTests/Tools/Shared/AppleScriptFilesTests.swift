import Foundation
import Testing
@testable import Orbit

/// The scripts in Orbit/Resources/AppleScripts: safe by construction (static
/// checks), syntactically valid (`osacompile`: Notes, Mail, Photos, Finder
/// and System Events ship scripting dictionaries, so compiling never launches
/// them; checked here too), and
/// the parts that do not talk to the app actually work: their handlers run
/// with osascript in a test script that targets no app. `.serialized`, like the
/// Mail scripts' tests: one osascript or osacompile run at a time.
@Suite("Orbit's AppleScripts", .serialized)
struct AppleScriptFilesTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let folder = repository.appendingPathComponent("Orbit/Resources/AppleScripts", isDirectory: true)
    /// Apps whose bundles contain an .sdef: compiling a script for them reads it
    /// and does not launch the app. Scripts may target only these.
    static let compilableApps: Set<String> = ["Notes", "Mail", "Photos", "Finder", "System Events"]
    /// Finder and System Events can do far more than Orbit asks of them
    /// (moving files, GUI scripting): each may be addressed only by the one
    /// script that needs it, allowed per script, not per app.
    static let restrictedApps: [String: Set<String>] = [
        "Finder": ["finder-selection"],
        "System Events": ["system-appearance"],
    ]

    static func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "applescript" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("\(name).applescript"), encoding: .utf8)
    }

    /// The apps a script addresses with `application "…"`.
    static func targets(in source: String) -> Set<String> {
        var targets = Set<String>()
        var rest = source[...]
        while let range = rest.range(of: "application \"") {
            let name = rest[range.upperBound...].prefix { $0 != "\"" }
            targets.insert(String(name))
            rest = rest[range.upperBound...]
        }
        return targets
    }

    // MARK: Files

    @Test func everyBundledScriptHasItsFileAndNoOtherFileIsThere() throws {
        let files = Set(try Self.files().map { $0.deletingPathExtension().lastPathComponent })
        let declared = Set(AppleScript.bundled.map(\.name))
        #expect(!declared.isEmpty)
        #expect(files == declared)
        for script in AppleScript.bundled {
            #expect(script.timeout < .seconds(90), "\(script.name) must stop before the agent loop's tool deadline")
            #expect(script.timeout >= .seconds(20), "\(script.name) needs time for a first launch and the permission prompt")
        }
    }

    @Test func scriptsTakeTheirParametersOnlyThroughArgvAndTargetOnlyTheirApp() throws {
        for script in AppleScript.bundled {
            let source = try Self.source(script.name)
            // ASCII only (no encoding surprises), except the chevrons of a raw
            // AppleScript code («class mssg»), which osascript and osacompile read
            // from UTF-8 source as such (verified with and without a byte order mark).
            let isASCII = source.unicodeScalars.allSatisfy { $0.isASCII || $0 == "«" || $0 == "»" }
            #expect(isASCII, "\(script.name): ASCII only (no encoding surprises)")
            #expect(source.contains("on run argv"), "\(script.name)")
            // "System Events" only in the one script allowed to address it.
            let allowedRestricted = Self.restrictedApps.filter { $0.value.contains(script.name) }.keys
            var forbiddenWords = ["do shell script", "run script", "load script", "store script", "osascript",
                                  "display dialog", "application id", "property "]
            if !allowedRestricted.contains("System Events") { forbiddenWords.append("System Events") }
            for forbidden in forbiddenWords {
                #expect(!source.localizedCaseInsensitiveContains(forbidden), "\(script.name) must not use \(forbidden)")
            }
            let targets = Self.targets(in: source)
            #expect(targets.isSubset(of: Self.compilableApps), "\(script.name) targets \(targets)")
            #expect(targets == Set([script.app?.name].compactMap { $0 }), "\(script.name) talks only to its own app")
            for (app, scripts) in Self.restrictedApps where targets.contains(app) {
                #expect(scripts.contains(script.name), "\(script.name) is not allowed to address \(app)")
            }
        }
    }

    @Test func everyScriptCompilesWithoutLaunchingItsApp() async throws {
        let output = try ClaudeCodeTest.makeDirectory("orbit-osacompile")
        defer { ClaudeCodeTest.removeDirectory(output) }
        let runningBefore = Self.compilableApps.filter(Self.isRunning)
        for file in try Self.files() {
            let source = try String(contentsOf: file, encoding: .utf8)
            try #require(Self.targets(in: source).isSubset(of: Self.compilableApps), "never compile scripts for other apps")
            let compiled = output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".scpt")
            let result = try await ChildProcess.run(
                ChildProcess.Launch(executable: "/usr/bin/osacompile", arguments: ["-o", compiled.path, file.path],
                                    environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/"),
                timeout: .seconds(60), outputLimit: 64 * 1024)
            #expect(result.exit == .exited(0),
                    "\(file.lastPathComponent): \(String(decoding: result.stderr, as: UTF8.self))")
        }
        for app in Self.compilableApps where !runningBefore.contains(app) {
            #expect(!Self.isRunning(app), "compiling must not launch \(app)")
        }
    }

    /// Whether an app with this process name runs (pgrep lists process names only).
    static func isRunning(_ app: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", app]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: Handlers that do not talk to the app

    /// The source of handlers `names` from `source` ("on name(" … "end name").
    static func handlers(_ names: [String], from source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        return try names.map { name in
            guard let start = lines.firstIndex(where: { $0.hasPrefix("on \(name)(") }),
                  let end = lines[start...].firstIndex(of: "end \(name)") else {
                throw HandlerMissing(name: name)
            }
            return lines[start...end].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    struct HandlerMissing: Error {
        var name: String
    }

    /// Runs `handlers` with a test `on run argv` body in a script that targets
    /// no app, and returns what it printed. A script that mentions an app is
    /// never run (the test fails instead).
    static func runHandlers(_ handlers: String, body: String, arguments: [String] = []) async throws -> String {
        let script = """
            use AppleScript version "2.7"
            use framework "Foundation"
            use scripting additions

            \(handlers)

            on run argv
            \(body)
            end run
            """
        try #require(!script.contains("tell application"), "the harness must not talk to any app")
        try #require(Self.targets(in: script).isEmpty, "the harness must not address any app")
        let folder = try ClaudeCodeTest.makeDirectory("orbit-handlers")
        defer { ClaudeCodeTest.removeDirectory(folder) }
        let name = "handlers-\(UUID().uuidString)"
        try script.write(to: folder.appendingPathComponent("\(name).applescript"), atomically: true, encoding: .utf8)
        let runner = LiveAppleScriptRunner(scriptsDirectory: folder)
        return try await runner.run(AppleScript(name: name, app: nil, timeout: .seconds(30)), arguments: arguments)
    }

    /// The guards stop the run: a script that mentions an app (here only in a
    /// string and in a comment, so even a run would send no Apple Event) is
    /// never started.
    @Test(arguments: ["return \"tell application\"", "-- application \"Mail\"\nreturn \"ran\""])
    func theHarnessNeverRunsAScriptThatMentionsAnApp(body: String) async {
        var output: String?
        await withKnownIssue("the guard records why it stopped") {
            output = try await Self.runHandlers("", body: body)
        }
        #expect(output == nil, "the script must not have run")
    }

    private struct SearchHandlers: Decodable {
        var order: [String]
        var all: [String]
        var nothing: [String]
        var dateOfA: Double
        var row: NoteSummary
        var lines: [String]
        var short: String
        var emoji: String
        var whole: String
        var none: String
        var now: Double
        var fatal: [Bool]
        var fits: [Bool]
    }

    @Test func notesSearchRanksFiltersAndFormatsRows() async throws {
        let handlers = try Self.handlers(["rankedMatches", "textSearchFits", "rowDictionary", "isFatal", "nonEmptyLines", "prefix",
                                          "toJSON"], from: try Self.source("notes-search"))
        let output = try await Self.runHandlers(handlers, body: """
                set now to current date
                set {ranked, datesByID} to my rankedMatches({"a", "b", "c", "d", "b"}, {now - 300, now - 100, now - 200, now - 50, now - 10}, current application's NSSet's setWithArray:{"d"}, {current application's NSSet's setWithArray:{"a", "b", "c"}, current application's NSSet's setWithArray:{"a", "b", "x"}})
                set dateOfA to ((datesByID's objectForKey:"a")'s timeIntervalSince1970()) as real
                set {everything, ignored} to my rankedMatches({"x", "y", "z"}, {now - 10, now - 5, now - 20}, current application's NSSet's |set|(), {})
                set {nothing, ignored} to my rankedMatches({}, {}, current application's NSSet's |set|(), {current application's NSSet's setWithArray:{"x"}})
                set row to my rowDictionary("x-coredata://T/ICNote/p1", item 1 of argv, "Notizen", now, true, my prefix(item 2 of argv, 5))
                set someLines to my nonEmptyLines("eins" & linefeed & linefeed & "zwei" & return & "drei" & linefeed)
                set fatal to {}
                repeat with errorNumber in {-1743, -1744, -600, -609, -1712, -128, -10000, -1728, -1700, 1002}
                    set end of fatal to my isFatal(contents of errorNumber)
                end repeat
                set fits to {my textSearchFits(1, 50, 0, 35, false), my textSearchFits(2, 10, 20, 35, false), my textSearchFits(2, 20, 20, 35, false), my textSearchFits(3, 35, 0, 35, false), my textSearchFits(3, 36, 0, 35, false), my textSearchFits(3, 1, 1, 35, true), my textSearchFits(1, 0, 0, 35, true)}
                set payload to current application's NSDictionary's dictionaryWithObjects:{ranked, everything, nothing, dateOfA, row, someLines, my prefix("Hallo", 0), my prefix(item 3 of argv, 3), my prefix("Hallo", 10), my prefix("", 3), (current application's NSDate's |date|()'s timeIntervalSince1970()), fatal, fits} forKeys:{"order", "all", "nothing", "dateOfA", "row", "lines", "short", "emoji", "whole", "none", "now", "fatal", "fits"}
                return my toJSON(payload)
            """, arguments: ["Umzug „Kisten“ ä", "Hallo Welt", "ab👨‍👩‍👧cd"])
        let result = try JSONDecoder().decode(SearchHandlers.self, from: Data(output.utf8))
        #expect(result.order == ["b", "a"], "d excluded, c not in every required set, b once, newest first")
        #expect(result.all == ["y", "x", "z"])
        #expect(result.nothing.isEmpty)
        #expect(abs(result.dateOfA + 300 - result.now) < 5, "each id keeps its date")
        // The first term is always searched in the notes' text; a further one only while
        // the time spent plus the longest text search so far stays within the budget, and
        // never after a term that was looked for in the titles only.
        #expect(result.fits == [true, true, false, true, false, false, true])
        #expect(result.row.id == "x-coredata://T/ICNote/p1")
        #expect(result.row.name == "Umzug „Kisten“ ä")
        #expect(result.row.folder == "Notizen")
        #expect(result.row.isLocked)
        #expect(result.row.start == "Hallo")
        let modified = try #require(result.row.modified?.timeIntervalSince1970)
        #expect(abs(modified - result.now) < 5)
        #expect(result.lines == ["eins", "zwei", "drei"])
        #expect(result.short == "")
        #expect(result.emoji == "ab👨‍👩‍👧", "a character is never split")
        #expect(result.whole == "Hallo")
        #expect(result.none == "")
        // Only these errors end the search; others make it fall back to the titles.
        #expect(result.fatal == [true, true, true, true, true, true, false, false, false, false])
    }

    /// notes-search's real term loop (taken from the script as it is) with its
    /// real `textSearchFits`, a clock that only moves when a search runs, and a
    /// stand-in for `idsMatching` whose text searches take `costs` seconds one
    /// after the other (a search of the names only: 1 s). For each scenario: the
    /// terms looked for in the titles only, and the seconds the loop took. One
    /// osascript run; no app is involved.
    static func runTermLoop(_ scenarios: [(costs: [Int], budget: Int)]) async throws -> [(titleOnly: [String], seconds: Int)] {
        let source = try Self.source("notes-search")
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "\tset requiredSets to {}"))
        let end = try #require(lines[start...].firstIndex(
            of: "\tset {ranked, datesByID} to my rankedMatches(scopeIDs, scopeDates, excludedIDs, requiredSets)"))
        let loop = lines[start..<end].joined(separator: "\n").replacingOccurrences(of: "current date", with: "my clock()")
        try #require(!loop.contains("tell application"))
        let harness = """
            on idsMatching(theFolder, term, namesOnly)
                global gNow, gCosts, gTextSearches
                if namesOnly then
                    set gNow to gNow + 1
                else
                    set gTextSearches to gTextSearches + 1
                    set gNow to gNow + (item gTextSearches of gCosts)
                end if
                return {{term}, true}
            end idsMatching

            on clock()
                global gNow
                return gNow
            end clock

            on searchTerms(terms, textBudget)
                global gNow
                set startTime to gNow
                set scopes to {missing value}
            \(loop)
                set AppleScript's text item delimiters to ","
                return (titleOnlyTerms as text) & "|" & ((gNow - startTime) as integer)
            end searchTerms

            on splitText(theText)
                set AppleScript's text item delimiters to ","
                set parts to text items of theText
                set AppleScript's text item delimiters to ""
                return parts
            end splitText
            """
        let handlers = try Self.handlers(["textSearchFits"], from: source) + "\n\n" + harness
        let output = try await Self.runHandlers(handlers, body: """
                global gNow, gCosts, gTextSearches
                set outputs to {}
                repeat with i from 1 to count of argv by 2
                    set gNow to 1000
                    set gTextSearches to 0
                    set gCosts to {}
                    repeat with cost in my splitText(item i of argv)
                        set end of gCosts to (contents of cost) as integer
                    end repeat
                    set end of outputs to my searchTerms({"eins", "zwei", "drei", "vier"}, (item (i + 1) of argv) as integer)
                end repeat
                set AppleScript's text item delimiters to linefeed
                return outputs as text
            """, arguments: scenarios.flatMap { [$0.costs.map(String.init).joined(separator: ","), String($0.budget)] })
        let printed = output.components(separatedBy: "\n")
        try #require(printed.count == scenarios.count, "\(output)")
        return try printed.map { line in
            let parts = line.components(separatedBy: "|")
            try #require(parts.count == 2, "\(line)")
            return (parts[0].isEmpty ? [] : parts[0].components(separatedBy: ","), try #require(Int(parts[1])))
        }
    }

    /// NOTES2-BUDGET: a word that had to be looked for in the titles only says
    /// nothing about how long a search of the texts takes (the longest text
    /// search so far does), and once one word was cut short, so is every word
    /// after it; the searches end within the budget instead of running into
    /// the script's time limit.
    @Test func notesSearchKeepsToItsBudgetOnceAWordWasSearchedInTitlesOnly() async throws {
        let results = try await Self.runTermLoop([
            // One search of the texts takes 30 s: "zwei" in titles only (30 + 30 > 35), and so "drei" and "vier".
            (costs: [30, 30, 30, 30], budget: 35),
            // 17 s, then 2 s (Notes may have the texts at hand): "drei" could take 17 s again (19 + 17 > 35).
            (costs: [17, 2, 17, 17], budget: 35),
            // Quick searches: every word in the texts.
            (costs: [2, 2, 2, 2], budget: 35),
        ])
        #expect(results[0].titleOnly == ["zwei", "drei", "vier"])
        #expect(results[0].seconds == 33, "30 s for the texts, then the titles only")
        #expect(results[1].titleOnly == ["drei", "vier"])
        #expect(results[1].seconds == 21)
        #expect(results[2].titleOnly.isEmpty)
        #expect(results[2].seconds == 8)
        for result in results {
            #expect(result.seconds < 60, "within the script's time limit (NotesService: 60 s)")
        }
    }

    /// notes-search looks at the notes' text once per term (ids only), in the
    /// notes it searches (a folder's when one is given), and reads dates
    /// without a text filter.
    @Test func notesSearchLooksAtTheTextOncePerTermAndOnlyWhereItSearches() throws {
        let code = try MailScriptTests.code("notes-search")
        #expect(code.components(separatedBy: "plaintext contains term").count - 1 == 2,
                "one text search per term: of all notes, or of a folder")
        #expect(code.contains("set noteIDs to id of every note whose name contains term or plaintext contains term"))
        #expect(code.contains("set noteIDs to id of every note of theFolder whose name contains term or plaintext contains term"))
        #expect(!code.contains("date of every note whose"), "dates come from a read without a text filter")
        #expect(!code.contains("date of every note of theFolder whose"))
        #expect(code.contains("set {foundIDs, foundInText} to my idsMatching(item j of scopes, term, namesOnly)"),
                "every term in the same notes as the first")
    }

    /// When nothing matched in all folders, notes-search also returns the names of the folders (people name
    /// a note by its folder: "my recipe note"), but not after searching one folder, and only while time is left.
    @Test func notesSearchNamesTheFoldersWhenNothingMatchedAnywhere() throws {
        let code = try MailScriptTests.code("notes-search")
        #expect(code.contains("if total = 0 and folderName is \"\" and ((current date) - startTime) < textBudget then"))
        #expect(code.components(separatedBy: "set {folderRefs, folderNames} to my allFolders()").count - 1 == 2,
                "for a folder to search, and for the answer")
        #expect(code.contains("set end of resultKeys to \"folders\""))
        #expect(code.contains("return my toJSON(current application's NSDictionary's dictionaryWithObjects:resultValues forKeys:resultKeys)"))
    }

    @Test func notesReadBuildsTheNoteWithACutBody() async throws {
        let handlers = try Self.handlers(["noteDictionary", "withoutEmbeddedData", "prefix", "toJSON"],
                                         from: try Self.source("notes-read"))
        let output = try await Self.runHandlers(handlers, body: """
                set now to current date
                return my toJSON(my noteDictionary("x-coredata://T/ICNote/p7", item 1 of argv, "Privat", now - 3600, now, false, item 2 of argv, 10))
            """, arguments: ["Tagebuch ü", "<div>Hallo 👨‍👩‍👧 Welt</div>"])
        let note = try JSONDecoder().decode(NoteContent.self, from: Data(output.utf8))
        #expect(note.id == "x-coredata://T/ICNote/p7")
        #expect(note.name == "Tagebuch ü")
        #expect(note.folder == "Privat")
        #expect(note.body == "<div>Hallo")
        #expect(note.bodyLength == "<div>Hallo 👨‍👩‍👧 Welt</div>".count)
        #expect(!note.isLocked)
        let created = try #require(note.created)
        let modified = try #require(note.modified)
        #expect(abs(modified.timeIntervalSince(created) - 3600) < 1)
    }

    /// Notes puts images and other embedded files into the body as data: URLs;
    /// their data goes before the body is measured and cut. Everything else stays.
    @Test func notesReadDropsTheDataOfEmbeddedImagesAndFiles() async throws {
        let handlers = try Self.handlers(["withoutEmbeddedData", "toJSON"], from: try Self.source("notes-read"))
        let samples: [(html: String, cleaned: String)] = [
            ("<div><img style=\"max-width: 100%; max-height: 100%;\" src=\"data:image/jpeg;base64,QUJD\"></div><div>Zutaten</div>",
             "<div><img style=\"max-width: 100%; max-height: 100%;\" src=\"\"></div><div>Zutaten</div>"),
            ("<img SRC='data:image/png;base64,QUJD' alt='Foto'>", "<img SRC=\"\" alt='Foto'>"),
            ("<picture><source srcset=\"data:image/x-apple-adaptive-glyph;base64,QUJD 1x\" type=\"image/x-apple-adaptive-glyph\"><img src=\"data:image/png;base64,QUJD\" alt=\"🙂\"></picture>",
             "<picture><source srcset=\"\" type=\"image/x-apple-adaptive-glyph\"><img src=\"\" alt=\"🙂\"></picture>"),
            ("<object name=\"a.pdf\" data=data:application/pdf;base64,QUJD type=x></object>",
             "<object name=\"a.pdf\" data=\"\" type=x></object>"),
            ("<a href = \"data:text/html,<b>x</b>\">Link</a> <a href=\"https://example.com\">Web</a>",
             "<a href=\"\">Link</a> <a href=\"https://example.com\">Web</a>"),
            ("<div>Text über data: URLs, src=\"x\" und <img src=\"bild.png\"></div>",
             "<div>Text über data: URLs, src=\"x\" und <img src=\"bild.png\"></div>"),
            ("<div>Ohne Bild</div>", "<div>Ohne Bild</div>"),
        ]
        let output = try await Self.runHandlers(handlers, body: """
                set cleaned to {}
                repeat with i from 1 to count of argv
                    set end of cleaned to my withoutEmbeddedData(item i of argv)
                end repeat
                return my toJSON(cleaned)
            """, arguments: samples.map(\.html))
        let cleaned = try JSONDecoder().decode([String].self, from: Data(output.utf8))
        #expect(cleaned == samples.map(\.cleaned))
        #expect(NoteText.plainText(fromHTML: cleaned[0]) == "[image]\nZutaten")
    }

    private struct CreateHandlers: Decodable {
        var first: Int
        var excluded: Int
        var missing: Int
        var allowed: [String]
    }

    @Test func notesCreateFindsTheFolderAndListsTheAllowedOnes() async throws {
        let handlers = try Self.handlers(["folderIndex", "allowedNames", "nonEmptyLines", "toJSON"],
                                         from: try Self.source("notes-create"))
        let output = try await Self.runHandlers(handlers, body: """
                set names to {"Notizen", "Rezepte", item 1 of argv, "rezepte", "Arbeit"}
                set excluded to my nonEmptyLines(item 1 of argv & linefeed & "Recently Deleted")
                set payload to current application's NSDictionary's dictionaryWithObjects:{my folderIndex(names, "REZEPTE", excluded), my folderIndex(names, item 1 of argv, excluded), my folderIndex(names, "Fehlt", excluded), my allowedNames(names, excluded)} forKeys:{"first", "excluded", "missing", "allowed"}
                return my toJSON(payload)
            """, arguments: ["Zuletzt gelöscht"])
        let result = try JSONDecoder().decode(CreateHandlers.self, from: Data(output.utf8))
        #expect(result.first == 2, "the first match, ignoring case")
        #expect(result.excluded == 0, "never the trash")
        #expect(result.missing == 0)
        #expect(result.allowed == ["Notizen", "Rezepte", "Arbeit"])
    }
}
