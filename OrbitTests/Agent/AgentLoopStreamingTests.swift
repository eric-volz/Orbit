import Foundation
import Testing
@testable import Orbit

@Suite("AgentLoop: streaming, turn endings and errors")
@MainActor
struct AgentLoopStreamingTests {
    @Test func streamsTextIncrementallyAndEndsNotStreaming() async throws {
        let midway = AsyncGate()
        let proceed = AsyncGate()
        let harness = AgentHarness(scripts: [[
            .text("Hal"), .signal(midway), .wait(proceed), .text("lo!"),
            .end([.thinking(text: "greet", signature: "sig"), .text("Hallo!")]),
        ]])

        harness.agent.send("  Hi  ")
        #expect(harness.agent.isRunning)
        #expect(harness.agent.items.first?.kind == .user(text: "Hi", attachments: []))

        await midway.wait()
        #expect(await AgentHarness.eventually { harness.assistantTexts == ["Hal"] })
        #expect(harness.agent.items.last?.kind == .assistant(text: "Hal", isStreaming: true))
        #expect(harness.agent.isRunning)

        proceed.open()
        await harness.agent.waitUntilIdle()
        #expect(!harness.agent.isRunning)
        #expect(harness.agent.items.map(\.kind) == [
            .user(text: "Hi", attachments: []),
            .assistant(text: "Hallo!", isStreaming: false),
        ])

        // The turn is stored verbatim, thinking included.
        let answer = try #require(harness.messages.last)
        #expect(answer.role == .assistant)
        #expect(answer.content == [.thinking(text: "greet", signature: "sig"), .text("Hallo!")])
        #expect(answer.model == "mock-model")
        harness.expectValidHistory()
    }

    @Test func requestCarriesSettingsFrozenPromptAndUserBlocks() async throws {
        let harness = AgentHarness(scripts: [MockScript.answer("Ok")])
        harness.settings.effort = .medium
        await harness.send("Wie spät ist es?")

        let request = try #require(harness.requests.first)
        #expect(request.model == SettingsStore.defaultAnthropicModel)
        #expect(request.effort == .medium)
        #expect(request.maxTokens == nil)
        #expect(request.systemPrompt == harness.agent.conversation.systemPrompt)
        #expect(request.systemPrompt.contains("Erika Mustermann"))
        #expect(request.systemPrompt.contains("2026-09-28T21:30:00+02:00"))

        let user = try #require(request.messages.first)
        #expect(user.role == .user)
        #expect(user.textBlocks.count == 2)
        #expect(user.textBlocks[0].hasPrefix("<orbit_context>\nCurrent time: 2026-09-28T21:30:00+02:00 (Monday, time zone Europe/Berlin)"))
        #expect(user.textBlocks[1] == "Wie spät ist es?")

        #expect(harness.configurations.all == [ProviderConfiguration(kind: .anthropic, apiKey: "test-key", baseURL: nil)])
        #expect(harness.agent.conversation.title == "Wie spät ist es?")
    }

    @Test func ignoresEmptyTextAndSendsWhileRunning() async {
        let proceed = AsyncGate()
        let harness = AgentHarness(scripts: [[.wait(proceed), .end([.text("Eins")])]])
        harness.agent.send("   \n ")
        #expect(!harness.agent.isRunning)
        #expect(harness.agent.items.isEmpty)

        harness.agent.send("Erste Frage")
        harness.agent.send("Zweite Frage")
        #expect(harness.agent.items.count == 1)
        proceed.open()
        await harness.agent.waitUntilIdle()
        #expect(harness.requests.count == 1)
        #expect(harness.messages.count == 2)
    }

    @Test func titleIsTheFirst60CharactersOfTheFirstMessage() async {
        let harness = AgentHarness(scripts: [MockScript.answer("A"), MockScript.answer("B")])
        let long = String(repeating: "Wort ", count: 30)
        await harness.send(long + "\nzweite Zeile")
        await harness.send("Andere Frage")
        #expect(harness.agent.conversation.title == String(long.prefix(60)))
    }

    @Test func progressNotesBecomeProgressRows() async {
        let harness = AgentHarness(scripts: [[
            .event(.progressNote("Ich schaue nach.")), .text("Fertig."), .end([.text("Ich schaue nach."), .text("Fertig.")]),
        ]])
        await harness.send("Los")
        #expect(harness.agent.items.map(\.kind) == [
            .user(text: "Los", attachments: []),
            .progress(text: "Ich schaue nach."),
            .assistant(text: "Fertig.", isStreaming: false),
        ])
    }

    @Test func showsTextThatWasNotStreamed() async {
        let harness = AgentHarness(scripts: [[.end([.text("Nur am Ende")])]])
        await harness.send("Hallo")
        #expect(harness.assistantTexts == ["Nur am Ende"])
    }

    // MARK: Stop reasons

    @Test func refusalRemovesPartialOutputAndTheRefusedRequest() async {
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            [
                .text("Ich werde"), .event(.progressNote("Suche…")),
                .end([.text("Ich werde"), .toolUse(MockScript.call("t1", "search_files", ["query": "x"]))],
                     stopReason: .refusal(category: "cyber")),
            ],
            MockScript.answer("Gern."),
        ])
        await harness.send("Etwas Verbotenes")

        #expect(harness.assistantTexts.isEmpty)
        #expect(!harness.agent.items.contains { if case .progress = $0.kind { true } else { false } })
        #expect(harness.notices == [Notice(style: .warning, message: "The model declined this request.")])
        // The refused request leaves the history (the one exception to append-only),
        // so a follow-up does not carry it again.
        #expect(harness.messages.isEmpty)
        #expect(log.entries.isEmpty)
        #expect(harness.agent.items.first?.kind == .user(text: "Etwas Verbotenes", attachments: []))

        await harness.send("Dann etwas anderes")
        #expect(harness.messages.map(\.role) == [.user, .assistant])
        #expect(harness.messages[0].textBlocks.count == 2)
        #expect(harness.messages[0].textBlocks[1] == "Dann etwas anderes")
        #expect(!harness.requests[1].messages.flatMap(\.textBlocks).contains("Etwas Verbotenes"))
        // The new request states the tool availability again (it went with the removed message).
        #expect(HistoryCheck.problems(in: harness.messages) == [])
    }

    @Test func aRefusalAfterToolResultsSuggestsANewChat() async {
        let log = MockToolLog()
        let call = MockScript.call("t1", "search_files", ["query": "x"])
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls([call]),
            [.text("Das"), .end([.text("Das")], stopReason: .refusal(category: "cyber"))],
        ])
        await harness.send("Suche x")
        #expect(harness.notices.last == Notice(style: .warning, message: "The model declined this request. Start a new chat to continue.",
                                               action: .newChat))
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user], "tool results cannot leave the history")
        harness.expectValidHistory()
    }

    @Test func noAnswerBecauseOfTheOutputLimitOffersARetry() async {
        let harness = AgentHarness(scripts: [[.end([.thinking(text: "lang", signature: "s")], stopReason: .maxTokens)]])
        await harness.send("Denk nach")
        #expect(harness.notices == [Notice(style: .warning, message: "The model reached its output limit before it could answer.",
                                           action: .retry)])
        #expect(harness.messages.map(\.role) == [.user])
    }

    @Test func maxTokensWithoutToolsKeepsTheAnswerAndSaysSo() async {
        let harness = AgentHarness(scripts: [[.text("Lange Antwort"), .end([.text("Lange Antwort")], stopReason: .maxTokens)]])
        await harness.send("Erzähl viel")
        #expect(harness.messages.last?.content == [.text("Lange Antwort")])
        #expect(harness.notices == [Notice(style: .info, message: "The answer was cut off because it reached the maximum length.")])
        #expect(!harness.agent.isRunning)
        harness.expectValidHistory()
    }

    @Test func maxTokensWithToolCallsSkipsThemAndContinues() async throws {
        let log = MockToolLog()
        let cut = ToolCall(id: "t1", name: "search_files", input: [:], rawInput: #"{"query": "Rech"#, inputParseError: "truncated")
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            [.event(.toolCallStarted(id: "t1", name: "search_files")), .end([.toolUse(cut)], stopReason: .maxTokens)],
            MockScript.answer("Neuer Versuch nötig."),
        ])
        await harness.send("Suche Rechnungen")

        #expect(log.entries.isEmpty)
        let result = try #require(harness.result(for: "t1"))
        #expect(result.isError)
        #expect(result.content.contains("maximum output length"))
        #expect(harness.requests.count == 2)
        #expect(harness.statuses.isEmpty)
        #expect(harness.assistantTexts == ["Neuer Versuch nötig."])
        harness.expectValidHistory()
    }

    @Test func contextWindowExceededSuggestsANewChat() async throws {
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: MockToolLog())], scripts: [[
            .end([.text("Moment"), .toolUse(MockScript.call("t1", "search_files", ["query": "a"]))], stopReason: .contextWindowExceeded),
        ]])
        await harness.send("Noch eine Frage")
        #expect(harness.notices == [Notice(style: .warning, message: "This conversation has become too long for the model. Start a new chat.",
                                           action: .newChat)])
        #expect(try #require(harness.result(for: "t1")).isError)
        #expect(harness.requests.count == 1)
        harness.expectValidHistory()
    }

    @Test func turnWithoutTextOrToolsIsNotAppendedAndCanBeRetried() async {
        let harness = AgentHarness(scripts: [
            [.end([.thinking(text: "hmm", signature: nil)])],
            MockScript.answer("Jetzt aber."),
        ])
        await harness.send("Hallo?")
        #expect(harness.messages.count == 1)
        #expect(harness.notices == [Notice(style: .warning, message: "The model did not return an answer.", action: .retry)])

        harness.agent.retry()
        await harness.agent.waitUntilIdle()
        #expect(harness.notices.isEmpty)
        #expect(harness.assistantTexts == ["Jetzt aber."])
        #expect(harness.requests.count == 2)
        #expect(harness.requests[0].messages == harness.requests[1].messages)
        harness.expectValidHistory()
    }

    // MARK: Errors

    @Test func providerErrorShowsRetryAndRetrySucceeds() async throws {
        let harness = AgentHarness(scripts: [
            [.text("Halbe Antw"), .fail(LLMError.overloaded)],
            MockScript.answer("Ganze Antwort."),
        ])
        await harness.send("Frage")

        // The partial answer stays visible but is not part of the history.
        #expect(harness.assistantTexts == ["Halbe Antw"])
        #expect(harness.agent.items.last?.kind == .notice(Notice(style: .error, message: LLMError.overloaded.userMessage, action: .retry)))
        #expect(harness.messages.count == 1)
        #expect(!harness.agent.isRunning)

        harness.agent.retry()
        #expect(harness.agent.isRunning)
        await harness.agent.waitUntilIdle()
        #expect(harness.notices.isEmpty)
        #expect(harness.assistantTexts == ["Ganze Antwort."])
        #expect(harness.messages.count == 2)
        #expect(harness.requests.count == 2)
        #expect(harness.requests[0].messages == harness.requests[1].messages)
        harness.expectValidHistory()
    }

    @Test func retryIsIgnoredWhenTheHistoryDoesNotEndWithTheUser() async {
        let harness = AgentHarness(scripts: [MockScript.answer("Fertig.")])
        await harness.send("Frage")
        harness.agent.retry()
        #expect(!harness.agent.isRunning)
        #expect(harness.requests.count == 1)
    }

    @Test func missingAPIKeyOffersSettingsAndARetry() async throws {
        let harness = AgentHarness(scripts: [MockScript.answer("Hallo")], apiKey: nil)
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: LLMError.missingAPIKey.userMessage, action: .openSettings,
                                           secondaryAction: .retry)])
        #expect(harness.requests.isEmpty)
        #expect(!harness.agent.isRunning)

        // After the key was entered, a retry works.
        try harness.secrets.setSecret("new-key", for: SecretAccount.anthropicAPIKey)
        harness.agent.retry()
        await harness.agent.waitUntilIdle()
        #expect(harness.assistantTexts == ["Hallo"])
        #expect(harness.configurations.all.last?.apiKey == "new-key")
    }

    @Test(arguments: [
        (LLMError.invalidAPIKey, [Notice.Action.openSettings, .retry]),
        (.modelNotFound(model: "x"), [.openSettings, .retry]),
        (.invalidBaseURL, [.openSettings, .retry]),
        (.rateLimited(retryAfter: 3), [.retry]),
        (.network(.offline), [.retry]),
        (.server(status: 500), [.retry]),
    ] as [(LLMError, [Notice.Action])])
    func errorNoticesOfferTheRightActions(error: LLMError, actions: [Notice.Action]) async {
        let harness = AgentHarness(scripts: [[.fail(error)]])
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: error.userMessage, action: actions.first,
                                           secondaryAction: actions.dropFirst().first)])
    }

    @Test func contextTooLongOffersANewChat() async {
        let harness = AgentHarness(scripts: [[.fail(LLMError.contextTooLong)]])
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: LLMError.contextTooLong.userMessage, action: .newChat)])
    }

    @Test func unknownErrorsShowAGenericMessage() async {
        struct Weird: Error {}
        let harness = AgentHarness(scripts: [[.fail(Weird())]])
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: "An unexpected error occurred. Please try again.", action: .retry)])
    }

    @Test func streamWithoutEndEventIsAnError() async {
        let harness = AgentHarness(scripts: [[.text("Abgeris")]])
        await harness.send("Hallo")
        #expect(harness.notices.first?.action == .retry)
        #expect(harness.messages.count == 1)
    }

    @Test func newMessageRetiresOldRetryButtons() async {
        let harness = AgentHarness(scripts: [[.fail(LLMError.overloaded)], MockScript.answer("Ok")])
        await harness.send("Eins")
        await harness.send("Zwei")
        #expect(harness.notices == [Notice(style: .error, message: LLMError.overloaded.userMessage)])
        #expect(harness.messages.count == 2)
        harness.expectValidHistory()
    }

    // MARK: Thinking

    @Test func historyThinkingStrippedRemovesThinkingFromStoredHistory() async throws {
        let harness = AgentHarness(scripts: [
            MockScript.answer("Erste Antwort", thinking: "Überlegung"),
            [.event(.historyThinkingStripped), .text("Zweite"), .end([.thinking(text: "neu", signature: "s2"), .text("Zweite")])],
        ])
        await harness.send("Eins")
        #expect(harness.messages[1].content.contains(.thinking(text: "Überlegung", signature: "sig-10")))

        await harness.send("Zwei")
        #expect(harness.messages.count == 4)
        #expect(harness.messages[1].content == [.text("Erste Antwort")])
        // The new turn keeps its own thinking.
        #expect(harness.messages[3].content == [.thinking(text: "neu", signature: "s2"), .text("Zweite")])
        #expect(HistoryCheck.problems(in: harness.messages) == [])
    }

    // MARK: Provider name

    @Test func providerDisplayNameFollowsTheProvider() async {
        let provider = MockLLMProvider(kind: .openAICompatible, displayName: "Ollama", scripts: [MockScript.answer("Hi")])
        let harness = AgentHarness(provider: provider)
        harness.settings.providerKind = .openAICompatible
        // Before a request, named from the settings the way the provider names itself: the server on this Mac
        // (the default address), another server by its host, "the language model" without a usable address.
        #expect(harness.agent.providerDisplayName == ProviderRecipient.localModel)
        harness.settings.openAIBaseURL = "https://llm.example.com/v1"
        #expect(harness.agent.providerDisplayName == "llm.example.com")
        harness.settings.openAIBaseURL = ""
        #expect(harness.agent.providerDisplayName == ProviderRecipient.languageModel)
        harness.settings.openAIBaseURL = SettingsStore.defaultOpenAIBaseURL
        await harness.send("Hallo")
        #expect(harness.agent.providerDisplayName == "Ollama")
        harness.settings.providerKind = .anthropic
        #expect(harness.agent.providerDisplayName == "Claude")
        harness.settings.anthropicBaseURL = "http://127.0.0.1:11434"
        #expect(harness.agent.providerDisplayName == ProviderRecipient.localModel)
        harness.settings.anthropicBaseURL = "https://api.anthropic.com"
        #expect(harness.agent.providerDisplayName == "Claude")
        harness.settings.providerKind = .claudeCode
        #expect(harness.agent.providerDisplayName == "Claude")
    }
}
