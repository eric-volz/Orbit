import Foundation
import Testing
@testable import Orbit

/// finder-selection.applescript and system-appearance.applescript: static
/// checks (each reads or changes only what it is for: no GUI scripting, no
/// file operations), their handlers run with osascript in a script that
/// addresses no app, and the services' handling of their answers (mock
/// runner). Both are compiled with the others in `AppleScriptFilesTests`;
/// Finder and System Events ship scripting dictionaries, so compiling never
/// launches them. No Apple Event is ever sent to Finder or System Events here.
@Suite("Finder and System Events scripts", .serialized)
struct SystemScriptTests {
    // MARK: finder-selection

    @Test func theFinderScriptOnlyReadsTheSelection() throws {
        let code = try MailScriptTests.code("finder-selection")
        #expect(FinderService.selectionScript.app == .finder && ScriptedApp.finder.name == "Finder")
        #expect(ScriptedApp.finder.permission == .automationFinder)
        #expect(AppleScriptFilesTests.targets(in: code) == ["Finder"])
        #expect(code.contains("set theSelection to (get selection)"))
        #expect(code.contains("as alias"))
        for word in ["delete", "move", "duplicate", "make", "open", "reveal", "select", "set selection", "empty", "eject",
                     "rename", "set name", "comment", "label", "trash", "quit", "activate", "update", "sort"] {
            #expect(!MailScriptTests.matches("\\b\(word)\\b", in: code), "finder-selection must not use '\(word)'")
        }
        #expect(!code.contains("use framework"), "no AppleScriptObjC: a run takes hundredths of a second")
        #expect(AppleScript.bundled.contains(FinderService.selectionScript))
    }

    @Test func theFinderHandlersWorkWithoutFinder() async throws {
        let handlers = try AppleScriptFilesTests.handlers(["itemLimit", "smaller", "posixPaths", "selectionOutput"],
                                                          from: try AppleScriptFilesTests.source("finder-selection"))
        let folder = try TemporaryFolder("orbit-finder-script")
        defer { folder.remove() }
        let file = try folder.write("Angebot „Garten“.pdf", "x")
        let subfolder = try folder.makeFolder("Fotos 2025")
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set theAliases to {}
                repeat with i from 1 to count of argv
                    set end of theAliases to (POSIX file (item i of argv)) as alias
                end repeat
                set limits to (my itemLimit("x") as text) & "," & (my itemLimit("0") as text) & "," & (my itemLimit("20") as text) & "," & (my smaller(25, 20) as text)
                return limits & linefeed & my selectionOutput(25, my posixPaths(theAliases))
            """, arguments: [file.path, subfolder.path])
        let lines = output.split(separator: "\n", maxSplits: 1).map(String.init)
        try #require(lines.count == 2)
        #expect(lines[0] == "1,1,20,20", "a bad limit counts as 1")
        let selection = try #require(FinderService.parse(lines[1]))
        #expect(selection.total == 25)
        #expect(selection.paths == [FilePath.canonical(file.path), FilePath.canonical(subfolder.path) + "/"],
                "POSIX paths; folders end with a slash")
    }

    @Test func theFinderServicePassesTheLimitAndReadsTheAnswer() async throws {
        let runner = MockAppleScriptRunner(output: "3\u{0}/Users/orbit-test/a.pdf\u{0}/Users/orbit-test/b/")
        let selection = try await FinderService(runner: runner).selection(maxItems: 20)
        #expect(runner.runs == [.init(script: "finder-selection", arguments: ["20"])])
        #expect(selection == .init(total: 3, paths: ["/Users/orbit-test/a.pdf", "/Users/orbit-test/b/"]))
        await #expect(throws: AppleScriptError.invalidOutput) {
            try await FinderService(runner: MockAppleScriptRunner(output: "{\"paths\": []}")).selection(maxItems: 20)
        }
        #expect(OsascriptFailure.error(number: -1743, message: "", app: .finder).toolError(for: FinderService.selectionScript)
            == .permissionDenied(.automationFinder))
    }

    // MARK: system-appearance

    @Test func theAppearanceScriptOnlySwitchesDarkMode() throws {
        let code = try MailScriptTests.code("system-appearance")
        #expect(SystemEventsService.appearanceScript.app == .systemEvents && ScriptedApp.systemEvents.name == "System Events")
        #expect(ScriptedApp.systemEvents.permission == .automationSystemEvents)
        #expect(AppleScriptFilesTests.targets(in: code) == ["System Events"])
        #expect(code.contains("tell appearance preferences"))
        #expect(code.components(separatedBy: "set dark mode to").count - 1 == 1, "dark mode is the only thing it sets")
        for word in ["keystroke", "key code", "click", "UI element", "process", "menu", "button", "window", "login item",
                     "delete", "make", "quit", "log out", "restart", "shut down", "sleep", "screen saver", "desktop",
                     "volume", "do shell script"] {
            #expect(!MailScriptTests.matches("\\b\(word)\\b", in: code), "system-appearance must not use '\(word)' (no GUI scripting)")
        }
        #expect(SystemEventsService.appearanceScript.timeout == .seconds(30), "time for the first prompt, within the tool deadline")
        #expect(AppleScript.bundled.contains(SystemEventsService.appearanceScript))
    }

    @Test func theAppearanceHandlersWorkWithoutSystemEvents() async throws {
        let handlers = try AppleScriptFilesTests.handlers(["wantsDarkMode", "answer"],
                                                          from: try AppleScriptFilesTests.source("system-appearance"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set results to {my answer(my wantsDarkMode("dark"), true), my answer(my wantsDarkMode("Light"), false)}
                try
                    my wantsDarkMode("blau")
                    set end of results to "accepted"
                on error message number errorNumber
                    set end of results to (errorNumber as text)
                end try
                set AppleScript's text item delimiters to linefeed
                return results as text
            """)
        let lines = output.components(separatedBy: "\n")
        try #require(lines.count == 3)
        #expect(try JSONDecoder().decode(SystemEventsService.AppearanceAnswer.self, from: Data(lines[0].utf8)) == .init(dark: true, changed: true))
        #expect(try JSONDecoder().decode(SystemEventsService.AppearanceAnswer.self, from: Data(lines[1].utf8)) == .init(dark: false, changed: false))
        #expect(lines[2] == "1001", "anything but dark or light is refused")
    }

    @Test func theServicePassesDarkOrLight() async throws {
        let runner = MockAppleScriptRunner(output: #"{"dark":false,"changed":true}"#)
        let answer = try await SystemEventsService(runner: runner).setAppearance(dark: false)
        #expect(answer == .init(dark: false, changed: true))
        #expect(runner.runs == [.init(script: "system-appearance", arguments: ["light"])])
    }
}
