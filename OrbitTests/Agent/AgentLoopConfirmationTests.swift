import Foundation
import Testing
@testable import Orbit

@Suite("AgentLoop: confirmations")
@MainActor
struct AgentLoopConfirmationTests {
    let log = MockToolLog()

    func makeHarness(extraScripts: [[MockLLMProvider.Step]] = [MockScript.answer("Erledigt.")]) -> AgentHarness {
        let call = MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"])
        return AgentHarness(tools: [MockCreateNoteTool(log: log)],
                            scripts: [MockScript.toolCalls([call], text: "Ich lege die Notiz an.")] + extraScripts)
    }

    /// Sends and waits for the confirmation card.
    func sendAndWaitForConfirmation(_ harness: AgentHarness) async throws -> ConfirmationRequest {
        harness.agent.send("Notiz Einkauf: Milch")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        return try #require(harness.agent.pendingConfirmation)
    }

    @Test func approvalWithEditsRunsTheToolWithTheEditedValues() async throws {
        let harness = makeHarness()
        let request = try await sendAndWaitForConfirmation(harness)

        #expect(request.toolCallID == "n1")
        #expect(request.toolName == "create_note")
        #expect(request.riskLevel == .write, "the tool's level wins over what its card claims")
        #expect(request.fields.map(\.value) == ["Einkauf", "Milch"])
        #expect(harness.agent.isRunning)
        #expect(log.entries.isEmpty, "nothing runs before the user decides")
        #expect(harness.statuses.isEmpty)

        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": "Einkaufsliste"]))
        await harness.agent.waitUntilIdle()

        #expect(log.arguments(of: "create_note") == [ToolArguments(["title": "Einkaufsliste", "body": "Milch"])])
        let state = try #require(harness.confirmations.first)
        #expect(state.status == .approved)
        #expect(state.request.fields.map(\.value) == ["Einkaufsliste", "Milch"])
        #expect(harness.statuses.map(\.state) == [.succeeded])
        #expect(harness.statuses.first?.text == "Notiz erstellt")
        #expect(harness.cards == [.info(InfoItem(title: "Einkaufsliste", detail: "Notiz erstellt", systemImage: "note.text"))])

        let result = try #require(harness.result(for: "n1"))
        #expect(!result.isError)
        #expect(result.content.hasPrefix(#"The user edited the proposed values before confirming; the action ran with: {"title":"Einkaufsliste"}"#))
        #expect(result.content.hasSuffix("Created the note 'Einkaufsliste'."))
        #expect(harness.assistantTexts.last == "Erledigt.")
        harness.expectValidHistory()
    }

    @Test func approvalWithoutEditsRunsTheProposal() async throws {
        let harness = makeHarness()
        let request = try await sendAndWaitForConfirmation(harness)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(log.arguments(of: "create_note") == [ToolArguments(["title": "Einkauf", "body": "Milch"])])
        #expect(harness.result(for: "n1")?.content == "Created the note 'Einkauf'.")
    }

    @Test func declineTellsTheModelAndRunsNothing() async throws {
        let harness = makeHarness(extraScripts: [MockScript.answer("Alles klar, nichts angelegt.")])
        let request = try await sendAndWaitForConfirmation(harness)
        harness.agent.resolveConfirmation(request.id, decision: .cancelled)
        await harness.agent.waitUntilIdle()

        #expect(log.entries.isEmpty)
        #expect(harness.confirmations.map(\.status) == [.cancelled])
        #expect(harness.result(for: "n1") == ToolResultBlock(toolCallID: "n1", content: "The user declined this action. Nothing was changed.", isError: false))
        #expect(harness.statuses.map(\.state) == [.cancelled])
        #expect(harness.statuses.first?.text == "Not run")
        #expect(harness.assistantTexts.last == "Alles klar, nichts angelegt.")
        harness.expectValidHistory()
    }

    @Test func invalidEditsAreNotRun() async throws {
        let harness = makeHarness()
        let request = try await sendAndWaitForConfirmation(harness)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": ""]))
        await harness.agent.waitUntilIdle()

        #expect(log.entries.isEmpty)
        let result = try #require(harness.result(for: "n1"))
        #expect(result.isError)
        #expect(result.content.contains("'title' must have at least 1 characters."))
        #expect(harness.statuses.map(\.state) == [.failed])
        harness.expectValidHistory()
    }

    @Test func stopWhilePendingExpiresTheCardAndClosesTheCall() async throws {
        let harness = makeHarness(extraScripts: [MockScript.answer("Neue Antwort.")])
        let request = try await sendAndWaitForConfirmation(harness)
        harness.agent.cancel()

        #expect(!harness.agent.isRunning)
        #expect(harness.agent.pendingConfirmation == nil)
        #expect(harness.confirmations.map(\.status) == [.expired])
        #expect(harness.notices.last == Notice(style: .info, message: "Canceled."))
        #expect(harness.result(for: "n1") == ToolResultBlock(toolCallID: "n1", content: "Cancelled by the user.", isError: true))
        #expect(HistoryCheck.problems(in: harness.messages) == [])

        // A late click on the old card changes nothing.
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(log.entries.isEmpty)

        // The next message joins the trailing tool-result message.
        await harness.send("Lass es")
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(harness.messages[2].toolResults.count == 1)
        #expect(harness.messages[2].textBlocks.last == "Lass es")
        harness.expectValidHistory()
    }

    @Test func newChatWhilePendingStoresTheExpiredCard() async throws {
        let harness = makeHarness()
        let request = try await sendAndWaitForConfirmation(harness)
        let oldID = harness.agent.conversationID
        harness.agent.newChat()
        await harness.agent.waitForPendingSaves()

        #expect(harness.agent.items.isEmpty)
        #expect(harness.agent.conversationID != oldID)
        let stored = try #require(await harness.store.conversation(oldID))
        let states = stored.items.compactMap { item -> ConfirmationState? in
            if case .confirmation(let state) = item.kind { return state }
            return nil
        }
        #expect(states.map(\.request.id) == [request.id])
        #expect(states.map(\.status) == [.expired])
        #expect(HistoryCheck.problems(in: stored.messages) == [])
    }

    @Test func readCallsInTheSameBatchAsAWriteRunInOrder() async throws {
        let tracker = MockConcurrencyTracker()
        let calls = [
            MockScript.call("r1", "search_files", ["query": "Einkauf"]),
            MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"]),
            MockScript.call("r2", "slow_read"),
        ]
        let harness = AgentHarness(tools: [
            MockSearchFilesTool(log: log), MockCreateNoteTool(log: log),
            MockSlowReadTool(name: "slow_read", delay: .milliseconds(10), tracker: tracker, log: log),
        ], scripts: [MockScript.toolCalls(calls), MockScript.answer("Fertig.")])

        harness.agent.send("Suche und notiere")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        // The call before the confirmation already ran, the one after did not.
        #expect(log.entries.map(\.tool) == ["search_files"])
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(log.entries.map(\.tool) == ["search_files", "create_note", "slow_read"])
        #expect(harness.messages[2].toolResults.map(\.toolCallID) == ["r1", "n1", "r2"])
        harness.expectValidHistory()
    }
}
