import AppKit
import Foundation
import Testing
@testable import Orbit

/// What VoiceOver hears of a request while the keyboard stays in the input
/// (D3): each tool's outcome, a waiting confirmation card, the complete answer
/// (helpful, not chatty): nothing per streamed word, no running steps, no text
/// written before a tool call, and a failure only once (as its notice).
@Suite("Chat announcements")
@MainActor
struct ChatAnnouncementTests {
    @Test func aToolsOutcomeThenTheAnswerAreRead() async throws {
        let call = MockScript.call("toolu_1", "search_files", ["query": "Rechnung"])
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: MockToolLog())], scripts: [
            MockScript.toolCalls([call], text: "Ich suche."),
            MockScript.answer("Ich habe **2 Rechnungen** gefunden."),
        ])
        await harness.send("Finde meine Rechnungen")
        // Not "Ich suche." (written before the call), not the streamed pieces.
        #expect(harness.announcer.announcements == ["2 Dateien gefunden", "Ich habe 2 Rechnungen gefunden."])
        #expect(harness.announcer.priorities == [.medium, .medium], "queued after what VoiceOver is saying")
    }

    @Test func aResultWithoutItsOwnLineOrAFailureNamesTheTool() async throws {
        let failing = MockFailingTool(name: "search_mail", error: ToolError.timedOut)
        let harness = AgentHarness(tools: [failing], scripts: [
            MockScript.toolCalls([MockScript.call("c1", "search_mail")]),
            MockScript.answer("Das hat zu lange gedauert."),
        ])
        await harness.send("Mails von Lisa")
        #expect(harness.announcer.announcements == ["search_mail: Timed out", "Das hat zu lange gedauert."])
        #expect(ChatAnnouncement.toolFinished(toolName: "Open file", status: "Completed", failed: false, hasSummary: false)
            == "Open file: Completed")
        #expect(ChatAnnouncement.toolFinished(toolName: "Mails suchen", status: "3 Nachrichten gefunden", failed: false, hasSummary: true)
            == "3 Nachrichten gefunden")
    }

    /// A reply in Mail: the panel says where its text is when Mail's window takes the keyboard, not twice.
    @Test func aReplyInMailIsAnnouncedByThePanelOnly() {
        let reply = MailDraftItem(to: ["lisa@example.com"], cc: [], subject: "Re: Projekt", body: "Passt.", isOpenInMail: true,
                                  draftID: 1, reply: MailReplyInfo(toAll: false, isTextOnClipboard: true))
        #expect(ChatAnnouncement.isAnnouncedByThePanel(.mailDraft(reply)))
        var draft = reply
        draft.reply = nil
        #expect(!ChatAnnouncement.isAnnouncedByThePanel(.mailDraft(draft)), "a new draft's window is Mail's: its line is read")
        #expect(!ChatAnnouncement.isAnnouncedByThePanel(.files([])) && !ChatAnnouncement.isAnnouncedByThePanel(nil))
    }

    /// A refused permission is said once, by its notice, not by the status line too.
    @Test func aMissingPermissionIsAnnouncedOnceAsItsNotice() async throws {
        let failing = MockFailingTool(name: "search_mail", error: ToolError.permissionDenied(.automationMail))
        let harness = AgentHarness(tools: [failing], scripts: [
            MockScript.toolCalls([MockScript.call("c1", "search_mail")]),
            MockScript.answer("Orbit is not allowed to control Mail."),
        ])
        await harness.send("Mails von Lisa")
        #expect(harness.announcer.announcements == [AgentLoop.permissionNotice(for: .automationMail), "Orbit is not allowed to control Mail."])
    }

    /// ERR-4: a call Orbit did not run is an outcome too: switched off in Settings (the chat's frozen tool
    /// list still offers it), or refused by the tool before its card: VoiceOver hears its line like a failure.
    @Test func aCallThatDidNotRunIsReadLikeAFailure() async throws {
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: MockToolLog())], scripts: [
            MockScript.answer("Hallo."),
            MockScript.toolCalls([MockScript.call("c1", "search_files", ["query": "Rechnung"])]),
            MockScript.answer("Die Dateisuche ist ausgeschaltet."),
        ])
        await harness.send("Hallo")
        harness.settings.disabledToolNames = ["search_files"]
        await harness.send("Finde die Rechnung")
        #expect(harness.statuses.map(\.text) == ["Turned off in Settings"])
        #expect(harness.announcer.announcements
            == ["Hallo.", "search_files: Turned off in Settings", "Die Dateisuche ist ausgeschaltet."])

        let refusing = AgentHarness(tools: [RefusingNoteTool()], scripts: [
            MockScript.toolCalls([MockScript.call("c1", "create_note", ["title": "Einkauf"])]),
            MockScript.answer("Den Ordner gibt es nicht."),
        ])
        await refusing.send("Leg die Notiz im Ordner Rezepte an")
        #expect(refusing.confirmations.isEmpty, "refused before its card")
        #expect(refusing.announcer.announcements == ["create_note: Not found", "Den Ordner gibt es nicht."])
    }

    /// A call the loop refuses for a missing permission is said once, by its notice, not by its line too.
    @Test func aCallWithoutItsPermissionIsAnnouncedOnceAsItsNotice() async throws {
        let harness = AgentHarness(tools: [MockSearchMailTool(log: MockToolLog())], scripts: [
            MockScript.toolCalls([MockScript.call("c1", "search_mail", ["query": "Lisa"])]),
            MockScript.answer("Orbit is not allowed to control Mail."),
        ])
        harness.permissions.set(.denied, for: .automationMail)
        await harness.send("Mails von Lisa")
        #expect(harness.statuses.map(\.text) == ["Missing permission: Automation: Mail"])
        #expect(harness.announcer.announcements == [AgentLoop.permissionNotice(for: .automationMail), "Orbit is not allowed to control Mail."])
    }

    @Test func aWaitingConfirmationIsReadAtOnceWithItsKeys() async throws {
        let call = MockScript.call("c1", "create_note", ["title": "Einkauf", "body": "Milch"])
        let harness = AgentHarness(tools: [MockCreateNoteTool(log: MockToolLog())], scripts: [
            MockScript.toolCalls([call]),
            MockScript.answer("Notiz angelegt."),
        ])
        harness.agent.send("Schreib mir eine Einkaufsnotiz")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        #expect(harness.announcer.announcements == ["Confirmation needed: Create note. ⌘↩ runs the action, ⌘. cancels it."])
        #expect(harness.announcer.priorities == [.high], "the request waits for the user")
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(harness.announcer.announcements.suffix(2) == ["Notiz erstellt", "Notiz angelegt."])
    }

    /// A11Y-1: the user switched to another app while Orbit worked, so the panel is hidden; ⌘↩ and ⌘. would
    /// reach that app (send a mail, stop a command). The card is announced without them, and with them once
    /// the panel has the keyboard again (`PanelState.keyboardDidReturn`, see AppEnvironmentTests).
    @Test func aCardThatWaitsWhileThePanelIsHiddenNamesItsKeysOnceItIsShown() async throws {
        let call = MockScript.call("c1", "create_note", ["title": "Einkauf", "body": "Milch"])
        let harness = AgentHarness(tools: [MockCreateNoteTool(log: MockToolLog())], scripts: [
            MockScript.toolCalls([call]),
            MockScript.answer("Notiz angelegt."),
        ])
        harness.panelHasKeyboard = false
        harness.agent.send("Schreib mir eine Einkaufsnotiz")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        #expect(harness.announcer.announcements
            == ["Confirmation needed: Create note. Open Orbit to run or cancel the action."])
        #expect(harness.announcer.priorities == [.high], "the request waits for the user")

        harness.panelHasKeyboard = true
        harness.agent.announcePendingConfirmation()
        #expect(harness.announcer.announcements.last == "Confirmation needed: Create note. ⌘↩ runs the action, ⌘. cancels it.")
        #expect(harness.announcer.priorities.last == .high)

        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        let count = harness.announcer.announcements.count
        harness.agent.announcePendingConfirmation()
        #expect(harness.announcer.announcements.count == count, "no card waits: showing the panel says nothing")
    }

    /// A failed request is said once, as its notice, never a half-written answer.
    @Test func aFailedRequestOnlyAnnouncesItsNotice() async throws {
        let harness = AgentHarness(scripts: [[.text("Ich fange an"), .fail(LLMError.overloaded)]])
        await harness.send("Hallo")
        #expect(harness.announcer.announcements == [LLMError.overloaded.userMessage])
    }

    /// Claude Code runs the tools itself: the answer after the last tool call is read.
    @Test func aProviderManagedRunReadsTheAnswerAfterItsTools() async throws {
        let provider = MockLLMProvider(kind: .claudeCode, scripts: [
            MockScript.managedRun([MockScript.call("toolu_1", "search_files", ["query": "Rechnung"])],
                                  before: "Ich suche.", answer: "Zwei Rechnungen."),
        ], executesToolsInternally: true)
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: MockToolLog())], apiKey: nil, provider: provider)
        harness.settings.providerKind = .claudeCode
        await harness.send("Finde meine Rechnungen")
        #expect(harness.announcer.announcements == ["2 Dateien gefunden", "Zwei Rechnungen."])
    }

    @Test func aLongAnswerIsReadUpToItsLimit() throws {
        let long = String(repeating: "Wort ", count: 1_000)
        let spoken = try #require(ChatAnnouncement.answer(long))
        #expect(spoken.hasSuffix(" … The full answer is in the chat."))
        #expect(spoken.count < ChatAnnouncement.maxAnswerCharacters + 60)
        #expect(ChatAnnouncement.answer("  \n ") == nil)
        #expect(ChatAnnouncement.answer("Kurz.") == "Kurz.")
    }

    /// ERR-3: only the start of a long answer becomes plain text; the main thread does not convert 100,000
    /// characters of Markdown for the 2,000 VoiceOver reads. Where the Markdown was cut, the note says the rest is
    /// in the chat, also when its start reads shorter than the limit (links shrink to their text).
    @Test func onlyTheStartOfALongAnswerIsConverted() throws {
        let links = (1...1_500).map { "- [Rechnung \($0)](https://example.com/rechnungen/2026/rechnung-\($0).pdf)" }
        let spoken = try #require(ChatAnnouncement.answer(links.joined(separator: "\n")))
        #expect(spoken.hasPrefix("Rechnung 1\nRechnung 2\n"))
        #expect(spoken.hasSuffix(" … The full answer is in the chat."))
        #expect(spoken.count < ChatAnnouncement.maxAnswerCharacters, "read up to where the converted start ends")
        #expect(!spoken.contains("Rechnung 150"))

        // An answer that fits is read in full, without the note.
        let short = links.prefix(20).joined(separator: "\n")
        #expect(ChatAnnouncement.answer(short) == (1...20).map { "Rechnung \($0)" }.joined(separator: "\n"))
    }

    @Test func answersAreReadWithoutTheirMarkup() {
        let markdown = """
            ## Morgen

            Du hast **zwei** Termine, siehe [Kalender](https://example.com) und `Notiz`.

            1. Zahnarzt
            2. Team-Meeting

            - [x] Brot
            - [ ] Milch

            > Zitat

            | Zeit | Titel |
            |---|---|
            | 10:00 | Zahnarzt |

            ```
            let x = 1
            ```
            """
        #expect(MarkdownPlainText.text(from: markdown) == """
            Morgen
            Du hast zwei Termine, siehe Kalender und Notiz.
            1. Zahnarzt
            2. Team-Meeting
            Completed: Brot
            Not completed: Milch
            Zitat
            Zeit, Titel
            10:00, Zahnarzt
            let x = 1
            """)
    }

    /// A write tool whose check before the card finds no folder of that name.
    private struct RefusingNoteTool: Tool {
        var name = "create_note"
        var description = "Creates a note."
        var inputSchema: JSONSchema = .object(properties: ["title": .string(description: "Title.", minLength: 1)], required: ["title"])
        var riskLevel: ToolRiskLevel = .write
        var category: ToolCategory = .notes

        func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
            throw ToolError.notFound("No folder named 'Rezepte'.")
        }

        func run(arguments: ToolArguments) async throws -> ToolResult {
            ToolResult(text: "Created the note.")
        }
    }

    @Test func theAnnouncementsReadNaturallyInEnglish() {
        do {
            #expect(ChatAnnouncement.confirmation(title: "Create event")
                == "Confirmation needed: Create event. ⌘↩ runs the action, ⌘. cancels it.")
            #expect(ChatAnnouncement.confirmation(title: "Create event", hasKeyboard: false)
                == "Confirmation needed: Create event. Open Orbit to run or cancel the action.")
            #expect(ChatAnnouncement.answer(String(repeating: "word ", count: 600))?.hasSuffix(" … The full answer is in the chat.") == true)
        }
    }
}
