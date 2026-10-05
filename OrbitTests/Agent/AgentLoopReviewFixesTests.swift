import Foundation
import Testing
@testable import Orbit

/// Regression tests for the findings of the Phase 1 review (round 2).
@Suite("AgentLoop: review fixes")
@MainActor
struct AgentLoopReviewFixesTests {
    let log = MockToolLog()

    // MARK: AGENT-1: actions that may still happen

    @Test func stoppingAnExecutingActionReportsAnUnknownOutcome() async throws {
        let release = AsyncGate()
        let call = MockScript.call("d1", "stuck_tool")
        let harness = AgentHarness(tools: [MockStuckTool(release: release, riskLevel: .draft)],
                                   scripts: [MockScript.toolCalls([call])])
        harness.agent.send("Leg los")
        #expect(await AgentHarness.eventually { harness.statuses.first?.state == .running })
        harness.agent.cancel()
        release.open()

        let result = try #require(harness.result(for: "d1"))
        #expect(result.content == AgentLoop.ModelText.outcomeUnknown)
        #expect(result.isError)
        #expect(harness.statuses.first?.text == "Stopped, result unknown")
        harness.expectValidHistory()
    }

    @Test func aTimedOutActionHasAnUnknownOutcome() async throws {
        let release = AsyncGate()
        defer { release.open() }
        let call = MockScript.call("d1", "stuck_tool")
        let harness = AgentHarness(tools: [MockStuckTool(release: release, riskLevel: .draft)],
                                   scripts: [MockScript.toolCalls([call]), MockScript.answer("Bitte prüfe es.")],
                                   toolTimeout: .milliseconds(100))
        await harness.send("Leg los")
        #expect(harness.result(for: "d1")?.content == AgentLoop.ModelText.outcomeUnknown)
        #expect(harness.statuses.first?.text == "Timed out, result unknown")
        #expect(harness.assistantTexts.last == "Bitte prüfe es.")
    }

    @Test func aTimedOutReadIsAPlainTimeout() async throws {
        let release = AsyncGate()
        defer { release.open() }
        let harness = AgentHarness(tools: [MockStuckTool(release: release)],
                                   scripts: [MockScript.toolCalls([MockScript.call("r1", "stuck_tool")]), MockScript.answer("Ok.")],
                                   toolTimeout: .milliseconds(100))
        await harness.send("Lies")
        #expect(harness.result(for: "r1")?.content == ToolError.timedOut.modelMessage)
        #expect(harness.statuses.first?.text == "Timed out")
    }

    // MARK: AGENT-2: what the confirmation card says

    @Test func theCardSaysRunningUntilTheOutcomeIsKnown() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let tool = MockBlockingTool(started: started, release: release, log: log, riskLevel: .write)
        let harness = AgentHarness(tools: [tool], scripts: [
            MockScript.toolCalls([MockScript.call("w1", "blocking_tool")]), MockScript.answer("Erledigt."),
        ])
        harness.agent.send("Tu es")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: [:]))
        #expect(harness.confirmations.first?.status == .confirmed)
        await started.wait()
        #expect(harness.confirmations.first?.status == .confirmed)
        release.open()
        await harness.agent.waitUntilIdle()
        #expect(harness.confirmations.first?.status == .approved)
    }

    @Test func aFailingActionMarksItsCardFailed() async throws {
        let tool = MockFailingTool(error: ToolError.permissionDenied(.reminders), riskLevel: .write)
        let harness = AgentHarness(tools: [tool], scripts: [
            MockScript.toolCalls([MockScript.call("f1", "failing_tool")]), MockScript.answer("Ging nicht."),
        ])
        harness.agent.send("Tu es")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(harness.confirmations.first?.status == .failed)
    }

    @Test func invalidEditsLeaveTheCardNotRun() async throws {
        let harness = AgentHarness(tools: [MockCreateNoteTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"])]),
            MockScript.answer("Ok."),
        ])
        harness.agent.send("Notiz")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id,
                                          decision: .approved(edits: ["title": ""]))
        await harness.agent.waitUntilIdle()
        #expect(log.entries.isEmpty)
        #expect(harness.confirmations.first?.status == .notRun)
    }

    @Test func stoppingRightAfterApprovingLeavesTheCardNotRun() async throws {
        let harness = AgentHarness(tools: [MockCreateNoteTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"])]),
        ])
        harness.agent.send("Notiz")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: [:]))
        harness.agent.cancel()
        await harness.agent.waitUntilIdle()
        #expect(log.entries.isEmpty)
        #expect(harness.confirmations.first?.status == .notRun)
        harness.expectValidHistory()
    }

    // MARK: AGENT-3: the retry button stays reachable

    @Test func theRetryNoticeStaysLastAfterADisclosure() async throws {
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("s1", "search_files", ["query": "Rechnung"])]),
            [.fail(LLMError.overloaded)],
        ])
        await harness.send("Finde meine Rechnungen")
        guard case .notice(let notice) = harness.agent.items.last?.kind else {
            Issue.record("the last row is not the notice")
            return
        }
        #expect(notice.action == .retry)
        #expect(harness.disclosures == [[ContentDisclosure(kind: .fileNames, count: 2)]])
    }

    // MARK: AGENT-6: frozen tool definitions

    @Test func theToolDefinitionsAreFrozenWithTheConversation() async throws {
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)],
                                   scripts: [MockScript.answer("Eins."), MockScript.answer("Zwei.")])
        await harness.send("Hallo")
        let frozen = try #require(harness.agent.conversation.toolDefinitions)
        #expect(frozen.map(\.name) == ["search_files"])
        #expect(harness.requests[0].tools == frozen)

        // A chat saved with other (older) definitions keeps sending them.
        var stored = harness.agent.currentConversation
        stored.toolDefinitions = [ToolDefinition(name: "search_files", description: "Old wording.",
                                                 inputSchema: ["type": "object"])]
        let restored = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [MockScript.answer("Drei.")],
                                    store: MockConversationStore(conversations: [stored]))
        await restored.agent.restoreMostRecentConversation()
        await restored.send("Weiter")
        #expect(restored.requests.first?.tools.map(\.description) == ["Old wording."])
    }

    // MARK: AGENT-7: the budget belongs to the request

    @Test func retryKeepsTheRequestsToolBudget() async throws {
        let first = (1...10).map { MockScript.call("a\($0)", "search_files", ["query": .string("q\($0)")]) }
        let second = (1...10).map { MockScript.call("b\($0)", "search_files", ["query": .string("r\($0)")]) }
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls(first),
            [.fail(LLMError.overloaded)],
            MockScript.toolCalls(second),
        ])
        await harness.send("Suche alles")
        #expect(log.entries.count == 10)
        harness.agent.retry()
        await harness.agent.waitUntilIdle()
        #expect(log.entries.count == 15, "5 more, not 10")
        #expect(harness.notices.last?.message.contains("after 15 tool calls") == true)
        harness.expectValidHistory()

        // A new request has a new budget.
        harness.provider.enqueue(MockScript.toolCalls([MockScript.call("c1", "search_files", ["query": "neu"])]))
        harness.provider.enqueue(MockScript.answer("Fertig."))
        await harness.send("Noch eine Suche")
        #expect(log.entries.count == 16)
    }

    // MARK: AGENT-8 / CROSSCUT-4: disclosure

    @Test func contentThatWasNeverSentIsDisclosedAfterARelaunch() async throws {
        let selection = [ContextAttachment(kind: .finderSelection(paths: ["/Users/test/a.pdf", "/Users/test/b.pdf"]),
                                           label: "Auswahl")]
        let harness = AgentHarness(scripts: [MockScript.answer("Ok.")], apiKey: nil)
        await harness.send("Fasse zusammen", attachments: selection)
        #expect(harness.notices.last?.action == .openSettings, "no key: the request never went out")
        #expect(harness.disclosures.isEmpty)
        await harness.agent.waitForPendingSaves()

        try harness.secrets.setSecret("sk-test", for: SecretAccount.anthropicAPIKey)
        harness.relaunch()
        await harness.agent.restoreMostRecentConversation()
        await harness.send("Jetzt bitte")
        #expect(harness.disclosures == [[ContentDisclosure(kind: .fileNames, count: 2)]])
    }

    @Test func switchingProvidersDisclosesTheWholeHistory() async throws {
        let harness = AgentHarness(tools: [MockSearchMailTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("m1", "search_mail", ["query": "Angebot"])]),
            MockScript.answer("Drei Mails."),
            MockScript.answer("Die erste ist von Anna."),
            MockScript.answer("Gern."),
        ])
        await harness.send("Mails zum Angebot?")
        #expect(harness.disclosures == [[ContentDisclosure(kind: .emails, count: 3)]])

        // Another provider receives the whole history, mails included.
        harness.settings.providerKind = .openAICompatible
        await harness.send("Von wem ist die erste?")
        #expect(harness.disclosures.count == 2)
        #expect(harness.disclosures.last == [ContentDisclosure(kind: .emails, count: 3)])

        // The same provider again: nothing new was disclosed.
        await harness.send("Danke")
        #expect(harness.disclosures.count == 2)
        #expect(harness.agent.conversation.recipients == ["anthropic@api.anthropic.com", "openAICompatible@localhost:11434"])
    }

    @Test func theClaudeSubscriptionAndTheAPIAreTheSameRecipient() {
        #expect(AgentLoop.recipientKey(kind: .claudeCode, baseURL: nil) == AgentLoop.recipientKey(kind: .anthropic, baseURL: nil))
        #expect(AgentLoop.recipientKey(kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")) == "anthropic@api.anthropic.com")
        #expect(AgentLoop.recipientKey(kind: .anthropic, baseURL: URL(string: "http://127.0.0.1:11434")) == "anthropic@127.0.0.1:11434")
    }

    // MARK: AGENT-10: a dismissed chat stays dismissed

    @Test func aChatLeftWithNewChatIsNotRestored() async throws {
        let harness = AgentHarness(scripts: [MockScript.answer("Hallo zurück")])
        await harness.send("Hallo")
        await harness.agent.waitForPendingSaves()
        let saves = await harness.store.saved.count
        harness.agent.newChat()
        await harness.agent.waitForPendingSaves()
        #expect(await harness.store.saved.count == saves, "an idle chat is not saved again")

        harness.relaunch()
        await harness.agent.restoreMostRecentConversation()
        #expect(!harness.agent.hasConversation)
    }

    // MARK: AGENT-11: an unreadable keychain

    @Test func anUnreadableKeychainIsNotAMissingKey() async throws {
        let harness = AgentHarness(scripts: [MockScript.answer("Ok.")])
        harness.keychainFails = true
        harness.relaunch()
        await harness.send("Hallo")
        let notice = try #require(harness.notices.last)
        #expect(notice.message == LLMError.keychainUnavailable.userMessage)
        #expect(notice.action == .retry)
    }
}
