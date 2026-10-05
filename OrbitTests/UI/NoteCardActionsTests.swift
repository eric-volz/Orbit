import Foundation
import Testing
@testable import Orbit

@Suite("Note cards open notes in Notes")
@MainActor
struct NoteCardActionsTests {
    static let note = NoteItem(id: "x-coredata://T/ICNote/p1", title: "Umzug")

    static func actions(_ runner: MockAppleScriptRunner) -> NoteCardActions {
        NoteCardActions(notes: NotesService(runner: runner, trashFolderNames: []))
    }

    @Test func aClickRunsTheOpenScript() async {
        let runner = MockAppleScriptRunner(output: #"{"opened":true,"name":"Umzug"}"#)
        let actions = Self.actions(runner)
        await actions.open(Self.note).value
        #expect(runner.runs == [.init(script: "notes-open", arguments: ["x-coredata://T/ICNote/p1"])])
        #expect(actions.openFailure == nil)
    }

    @Test func failuresAreExplainedUnderTheInput() async {
        let runner = MockAppleScriptRunner(output: #"{"error":"notFound"}"#)
        let actions = Self.actions(runner)
        await actions.open(Self.note).value
        #expect(actions.openFailure == NoteCardActions.OpenFailure(title: "Umzug", reason: .notFound, count: 1))
        #expect(InputHint(noteFailure: actions.openFailure!).text
            == "The note “Umzug” was not found in Notes. It may have been deleted.")

        runner.respond { _, _ in throw AppleScriptError.notAuthorized(.notes) }
        await actions.open(Self.note).value
        #expect(actions.openFailure?.reason == .notPermitted)
        #expect(actions.openFailure?.count == 2, "a repeated failure is reported again")
        #expect(InputHint(noteFailure: actions.openFailure!) == .notesNotPermitted)

        runner.respond { _, _ in throw AppleScriptError.appUnavailable(.notes) }
        await actions.open(NoteItem(id: "x-coredata://T/ICNote/p2", title: "")).value
        #expect(InputHint(noteFailure: actions.openFailure!) == .noteNotOpened(title: "New Note"))
        #expect(InputHint(noteFailure: actions.openFailure!).text == "The note “New Note” could not be opened in Notes.")
    }

    @Test func aDeniedAutomationHintPointsToTheSettings() {
        #expect(InputHint.notesNotPermitted.text.contains("Permissions"))
    }
}
