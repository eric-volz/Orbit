import Foundation
import Testing
@testable import Orbit

/// Providers that run the tool loop themselves (Claude Code) call Orbit's tools
/// through `LLMRequest.toolExecutor`.
@Suite("AgentLoop: provider-managed tool loop")
@MainActor
struct AgentLoopProviderToolsTests {
    let log = MockToolLog()

    func managedHarness(tools: [any Tool], scripts: [[MockLLMProvider.Step]],
                        claudeCodeAccount: (any ClaudeCodeAccountServicing)? = nil) -> AgentHarness {
        let provider = MockLLMProvider(kind: .claudeCode, scripts: scripts, executesToolsInternally: true)
        let harness = AgentHarness(tools: tools, apiKey: nil, provider: provider, claudeCodeAccount: claudeCodeAccount)
        harness.settings.providerKind = .claudeCode
        return harness
    }

    @Test func runsToolsThroughTheExecutorAndRecordsAValidHistory() async throws {
        let call = MockScript.call("toolu_1", "search_files", ["query": "Rechnung", "limit": "5"])
        let harness = managedHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.managedRun([call], before: "Ich suche.", answer: "Ich habe 2 Rechnungen gefunden."),
        ])
        await harness.send("Finde meine Rechnungen")

        // One request: the provider ran the tool loop itself.
        #expect(harness.requests.count == 1)
        let request = try #require(harness.requests.first)
        #expect(request.toolExecutor != nil)
        #expect(request.conversationID == harness.agent.conversationID)
        #expect(request.tools.map(\.name) == ["search_files"])
        #expect(log.arguments(of: "search_files") == [ToolArguments(["query": "Rechnung", "limit": 5])])
        let returned = try #require(harness.provider.executorResults.first)
        #expect(returned.toolCallID == "toolu_1")
        #expect(!returned.isError)
        #expect(returned.content.hasPrefix("Found 2 files for 'Rechnung'"))

        // The same rows as with API providers.
        #expect(harness.agent.items.map(\.kind) == [
            .user(text: "Finde meine Rechnungen", attachments: []),
            .assistant(text: "Ich suche.", isStreaming: false),
            .toolStatus(ToolStatus(toolCallID: "toolu_1", toolName: "search_files", category: .files,
                                   text: "2 Dateien gefunden", state: .succeeded)),
            .card(.files(MockSearchFilesTool.files)),
            .assistant(text: "Ich habe 2 Rechnungen gefunden.", isStreaming: false),
            .disclosure(items: [ContentDisclosure(kind: .fileNames, count: 2)], providerName: "Claude"),
        ])

        // The history reads like an API run: usable after switching providers.
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(harness.messages[1].content == [.text("Ich suche."), .toolUse(call)])
        #expect(harness.result(for: "toolu_1") == returned)
        #expect(harness.messages[3].content == [.text("Ich habe 2 Rechnungen gefunden.")])
        #expect(harness.messages[3].model == "mock-model")
        harness.expectValidHistory()
        #expect(!harness.agent.isRunning)
    }

    @Test func aFollowUpRequestContinuesTheHistory() async throws {
        let call = MockScript.call("toolu_1", "search_files", ["query": "Rechnung"])
        let harness = managedHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.managedRun([call], answer: "Zwei Rechnungen."),
            MockScript.answer("Die neuere ist vom August."),
        ])
        await harness.send("Finde meine Rechnungen")
        await harness.send("Welche ist neuer?")

        #expect(harness.requests.count == 2)
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user, .assistant, .user, .assistant])
        // Without text before the call, the assistant message holds only the call.
        #expect(harness.messages[1].content == [.toolUse(call)])
        #expect(harness.requests[1].conversationID == harness.requests[0].conversationID)
        harness.expectValidHistory()
    }

    @Test func confirmationCardsWorkThroughTheExecutor() async throws {
        let call = MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"])
        let harness = managedHarness(tools: [MockCreateNoteTool(log: log)], scripts: [
            MockScript.managedRun([call], before: "Ich lege die Notiz an.", answer: "Die Notiz ist angelegt."),
        ])
        harness.agent.send("Notiz Einkauf: Milch")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.toolCallID == "n1")
        #expect(log.entries.isEmpty, "nothing runs before the user decides")
        #expect(harness.provider.executorResults.isEmpty, "the provider waits for the decision")

        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": "Einkaufsliste"]))
        await harness.agent.waitUntilIdle()

        #expect(log.arguments(of: "create_note") == [ToolArguments(["title": "Einkaufsliste", "body": "Milch"])])
        let result = try #require(harness.provider.executorResults.first)
        #expect(result.content.contains("Einkaufsliste"))
        #expect(harness.confirmations.first?.status == .approved)
        #expect(harness.assistantTexts.last == "Die Notiz ist angelegt.")
        harness.expectValidHistory()
    }

    @Test func aDeclinedConfirmationReachesTheModel() async throws {
        let call = MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"])
        let harness = managedHarness(tools: [MockCreateNoteTool(log: log)], scripts: [
            MockScript.managedRun([call], answer: "Gut, ich lasse es."),
        ])
        harness.agent.send("Notiz Einkauf: Milch")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .cancelled)
        await harness.agent.waitUntilIdle()

        #expect(log.entries.isEmpty)
        #expect(harness.provider.executorResults.first?.content == AgentLoop.ModelText.declined)
        #expect(harness.result(for: "n1")?.content == AgentLoop.ModelText.declined)
        harness.expectValidHistory()
    }

    @Test func concurrentCallsAreRecordedAsOneBatch() async throws {
        let tracker = MockConcurrencyTracker()
        let tools = [
            MockSlowReadTool(name: "slow_a", delay: .milliseconds(200), tracker: tracker, log: log),
            MockSlowReadTool(name: "slow_b", delay: .milliseconds(100), tracker: tracker, log: log),
        ]
        let calls = [MockScript.call("a", "slow_a"), MockScript.call("b", "slow_b")]
        let harness = managedHarness(tools: tools, scripts: [MockScript.managedRun(calls, answer: "Beides gelesen.")])
        await harness.send("Lies beides")

        #expect(await tracker.maximum == 2)
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(Set(harness.messages[1].toolCalls.map(\.id)) == ["a", "b"])
        #expect(Set(harness.messages[2].toolResults.map(\.content)) == ["result of slow_a", "result of slow_b"])
        harness.expectValidHistory()
    }

    @Test func unknownToolsAndInvalidArgumentsGetErrorResults() async throws {
        let calls = [MockScript.call("x", "delete_everything"), MockScript.call("s", "search_files", ["limit": 5])]
        let harness = managedHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.managedRun(calls, answer: "Das ging nicht."),
        ])
        await harness.send("Mach was")

        #expect(log.entries.isEmpty)
        #expect(harness.provider.executorResults.count == 2)
        #expect(harness.provider.executorResults.allSatisfy { $0.isError })
        #expect(harness.result(for: "x")?.content.contains("there is no tool named 'delete_everything'") == true)
        harness.expectValidHistory()
    }

    @Test func theToolBudgetAnswersFurtherCallsWithAnError() async throws {
        let limit = AgentLoop.maxToolCallsPerRequest
        let calls = (0...limit).map { MockScript.call("c\($0)", "search_files", ["query": .string("q\($0)")]) }
        var script: [MockLLMProvider.Step] = []
        for call in calls {
            script += [.event(.toolCallStarted(id: call.id, name: call.name)), .callTools([call])]
        }
        script += [.text("Genug."), .end([.text("Genug.")])]
        let harness = managedHarness(tools: [MockSearchFilesTool(log: log)], scripts: [script])
        await harness.send("Suche alles")

        #expect(log.entries.count == limit)
        let results = harness.provider.executorResults
        #expect(results.count == limit + 1)
        #expect(results.last?.isError == true)
        #expect(results.last?.content == AgentLoop.ModelText.toolLimitReachedForProvider)
        #expect(harness.notices.filter { $0.style == .warning }.count == 1)
        #expect(harness.assistantTexts.last == "Genug.")
        harness.expectValidHistory()
    }

    @Test func stoppingDuringAToolCallAnswersItAndKeepsTheHistoryValid() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let call = MockScript.call("b1", "blocking_tool")
        let harness = managedHarness(tools: [MockBlockingTool(started: started, release: release, log: log)], scripts: [
            MockScript.managedRun([call], before: "Einen Moment.", answer: "Fertig."),
        ])
        harness.agent.send("Los")
        await started.wait()
        harness.agent.cancel()
        release.open()
        await harness.agent.waitUntilIdle()

        #expect(!harness.agent.isRunning)
        #expect(harness.statuses.first?.state == .cancelled)
        #expect(harness.notices.last?.message == "Canceled.")
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user])
        #expect(harness.messages[1].content == [.text("Einen Moment."), .toolUse(call)])
        #expect(harness.result(for: "b1")?.content == AgentLoop.ModelText.cancelledByUser)
        #expect(await AgentHarness.eventually { harness.provider.executorResults.count == 1 })
        #expect(harness.provider.executorResults.first?.isError == true)
        harness.expectValidHistory()

        // The next request continues from there.
        harness.provider.enqueue(MockScript.answer("Weiter geht's."))
        await harness.send("Weiter")
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        harness.expectValidHistory()
    }

    @Test func aFailureKeepsTheToolsThatRanAndCanBeRetried() async throws {
        let call = MockScript.call("toolu_1", "search_files", ["query": "Rechnung"])
        let harness = managedHarness(tools: [MockSearchFilesTool(log: log)], scripts: [[
            .event(.toolCallStarted(id: call.id, name: call.name)),
            .callTools([call]),
            .text("Ich habe zwei gef"),
            .fail(LLMError.providerProcessFailed(detail: "crash")),
        ]])
        await harness.send("Finde meine Rechnungen")

        let notice = try #require(harness.notices.last)
        #expect(notice.style == .error)
        #expect(notice.action == .retry)
        // The tool ran, so it stays; the unfinished answer does not.
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user])
        #expect(harness.result(for: "toolu_1")?.isError == false)
        #expect(!harness.messages.flatMap(\.content).contains(.text("Ich habe zwei gef")))
        harness.expectValidHistory()

        harness.provider.enqueue(MockScript.answer("Zwei Rechnungen gefunden."))
        harness.agent.retry()
        await harness.agent.waitUntilIdle()
        #expect(!harness.assistantTexts.contains("Ich habe zwei gef"))
        #expect(harness.assistantTexts.last == "Zwei Rechnungen gefunden.")
        #expect(log.entries.count == 1, "the retry does not run the tool again by itself")
        harness.expectValidHistory()
    }

    /// Not installed: Settings (Model shows how to install it); signed out:
    /// Anthropic's sign-in; a usage limit: a retry once it reset.
    @Test func claudeCodeErrorsOfferWhatHelps() async throws {
        let cases: [(LLMError, [Notice.Action])] = [
            (.claudeCodeNotInstalled, [.openSettings, .retry]),
            (.claudeCodeNotLoggedIn, [.signIn, .retry]),
            (.claudeCodeOutdated, [.retry, .openSettings]),
            (.usageLimitReached(resetsAt: nil), [.retry]),
        ]
        for (error, actions) in cases {
            let harness = managedHarness(tools: [], scripts: [[.fail(error)]])
            await harness.send("Hallo")
            #expect(harness.notices.last?.actions == actions)
            #expect(harness.notices.last?.message == error.userMessage)
        }
    }

    @Test func theKeychainIsNotReadForClaudeCode() async throws {
        let harness = managedHarness(tools: [], scripts: [MockScript.answer("Hallo!")])
        try harness.secrets.setSecret("sk-should-stay-unread", for: SecretAccount.apiKey(for: .claudeCode))
        try harness.secrets.setSecret("sk-anthropic", for: SecretAccount.anthropicAPIKey)
        await harness.send("Hallo")
        #expect(harness.configurations.all.map(\.kind) == [.claudeCode])
        #expect(harness.configurations.all.map(\.apiKey) == [""])
        #expect(harness.assistantTexts == ["Hallo!"])
    }

    @Test func usageWarningsAppearOncePerWindowAndThreshold() async throws {
        let reset = AgentTestClock.start.addingTimeInterval(3 * 3600)
        func usage(_ utilization: Double, window: String = "five_hour") -> MockLLMProvider.Step {
            .event(.rateLimit(RateLimitInfo(status: "allowed_warning", utilization: utilization, resetsAt: reset,
                                            window: window, isUsingOverage: false)))
        }
        let harness = managedHarness(tools: [], scripts: [
            [usage(0.26, window: "seven_day")] + MockScript.answer("Eins."),
            [usage(0.82)] + MockScript.answer("Zwei."),
            [usage(0.85)] + MockScript.answer("Drei."),
            [usage(0.96)] + MockScript.answer("Vier."),
        ])
        await harness.send("1")
        #expect(harness.agent.providerUsage?.window == "seven_day")
        #expect(harness.notices.isEmpty, "Claude Code's early warning at 26 % is not shown")

        await harness.send("2")
        await harness.send("3")
        await harness.send("4")
        let infos = harness.notices.filter { $0.style == .info }.map(\.message)
        #expect(infos.count == 2)
        #expect(infos.first?.hasPrefix("You have used 82% of your Claude usage limit (5-hour window).") == true)
        #expect(infos.last?.hasPrefix("You have used 96%") == true)
        #expect(harness.agent.providerUsage?.utilization == 0.96)
    }

    @Test func statusAndSignInGoThroughTheAccountService() async throws {
        let account = MockClaudeCodeAccount(status: ClaudeCodeStatus(availability: .ready, executablePath: "/x/claude",
                                                                     version: "2.1.284", subscriptionType: "max",
                                                                     authMethod: "claude.ai"))
        let harness = managedHarness(tools: [], scripts: [], claudeCodeAccount: account)
        #expect(await harness.agent.claudeCodeStatus()?.subscriptionType == "max")
        try await harness.agent.signInToClaudeCode()
        #expect(account.signInCount == 1)

        let without = AgentHarness()
        #expect(await without.agent.claudeCodeStatus() == nil)
        await #expect(throws: LLMError.claudeCodeNotInstalled) {
            try await without.agent.signInToClaudeCode()
        }
    }

    @Test func stopForTerminationKeepsWhatStreamed() async throws {
        let gate = AsyncGate()
        let harness = managedHarness(tools: [], scripts: [[.text("Halb"), .signal(gate), .wait(AsyncGate())]])
        harness.agent.send("Erzähl")
        await gate.wait()
        #expect(await AgentHarness.eventually { harness.assistantTexts == ["Halb"] })
        harness.agent.stopForTermination()
        #expect(!harness.agent.isRunning)
        #expect(harness.messages.last?.content == [.text("Halb")])
        await harness.agent.waitForPendingSaves()
        let saved = await harness.store.saved
        #expect(saved.last?.messages.last?.content == [.text("Halb")])
        harness.agent.stopForTermination() // nothing running: no effect
        #expect(harness.notices.count == 1)
    }
}

/// A scripted `ClaudeCodeAccountServicing`.
final class MockClaudeCodeAccount: ClaudeCodeAccountServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let fixedStatus: ClaudeCodeStatus
    private var signIns = 0

    init(status: ClaudeCodeStatus) {
        fixedStatus = status
    }

    var signInCount: Int { lock.withLock { signIns } }

    func status() async -> ClaudeCodeStatus { fixedStatus }

    func signIn() async throws {
        lock.withLock { signIns += 1 }
    }
}
