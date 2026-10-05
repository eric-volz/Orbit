import Foundation
import Testing
@testable import Orbit

/// D6: the OpenAI-compatible provider end to end in the agent loop, against a
/// scripted server that answers like Ollama (`MockServer`, the in-process
/// counterpart of DevTools/FakeLLMServer): a tool round trip, and the notices
/// when Ollama is not running, the model is not installed, the model cannot
/// use tools, or a server wants a key.
@Suite("OpenAI-compatible provider in the agent loop")
@MainActor
struct OpenAICompatibleAgentTests {
    private static let localBase = SettingsStore.defaultOpenAIBaseURL

    private struct Setup {
        let harness: AgentHarness
        let server: MockServer
        let sleeps: SleepRecorder
    }

    private func setup(base: String = localBase, model: String = "gpt-oss:20b", apiKey: String = "",
                       tools: [any Tool] = []) throws -> Setup {
        let server = MockServer()
        let sleeps = SleepRecorder()
        let provider = try OpenAICompatibleProvider(
            configuration: ProviderConfiguration(kind: .openAICompatible, apiKey: apiKey, baseURL: URL(string: base)),
            transport: server.transport(sleeps: sleeps))
        let harness = AgentHarness(tools: tools, serving: provider)
        harness.settings.providerKind = .openAICompatible
        harness.settings.openAIBaseURL = base
        harness.settings.openAIModel = model
        return Setup(harness: harness, server: server, sleeps: sleeps)
    }

    private static let answer: MockServer.Response = .sse(events: [
        OpenAISSE.content("Da bin ich."), OpenAISSE.content("", finishReason: "stop"), OpenAISSE.done,
    ])

    @Test func toolCallsGoRoundTrip() async throws {
        let log = MockToolLog()
        let setup = try setup(tools: [MockSearchFilesTool(log: log)])
        setup.server.enqueue(
            .sse(events: [
                OpenAISSE.reasoning("Ich suche die Rechnungen."),
                OpenAISSE.toolCall(index: 0, id: "call_1", name: "search_files", arguments: #"{"query":"#),
                OpenAISSE.toolCall(index: 0, arguments: #""Rechnung"}"#),
                OpenAISSE.chunk([:], finishReason: "tool_calls"),
                OpenAISSE.done,
            ]),
            .sse(events: [OpenAISSE.content("Ich habe 2 Rechnungen gefunden.", finishReason: "stop"), OpenAISSE.done])
        )
        await setup.harness.send("Finde meine Rechnungen")

        #expect(log.arguments(of: "search_files").map { try? $0.string("query") } == ["Rechnung"])
        #expect(setup.harness.assistantTexts == ["Ich habe 2 Rechnungen gefunden."])
        #expect(setup.harness.cards == [.files(MockSearchFilesTool.files)])
        #expect(setup.harness.notices.isEmpty)
        setup.harness.expectValidHistory()

        // The first request offers the tool; the second brings its result back as a tool message.
        let requests = setup.server.requests
        #expect(requests.count == 2)
        let tools = try #require(requests[0].bodyJSON?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["function"]?["name"]?.stringValue } == ["search_files"])
        let messages = try #require(requests[1].bodyJSON?["messages"]?.arrayValue)
        let call = try #require(messages.first { $0["role"] == "assistant" }?["tool_calls"]?.arrayValue?.first)
        #expect(call["id"] == "call_1")
        #expect(call["function"]?["arguments"] == #"{"query":"Rechnung"}"#)
        let result = try #require(messages.first { $0["role"] == "tool" })
        #expect(result["tool_call_id"] == "call_1")
        #expect(result["content"]?.stringValue == setup.harness.result(for: "call_1")?.content)
        #expect(result["content"]?.stringValue?.contains("Rechnung-März.pdf") == true)
    }

    @Test func ollamaNotRunningSaysToStartItAndTheRetryWorks() async throws {
        let setup = try setup()
        // The request and its two automatic retries.
        setup.server.enqueue(.failure(.cannotConnectToHost), .failure(.cannotConnectToHost), .failure(.cannotConnectToHost))
        await setup.harness.send("Hallo")
        #expect(setup.harness.notices == [Notice(
            style: .error,
            message: "The server on this Mac (localhost:11434) cannot be reached. Start it (for example Ollama or LM Studio) and try again.",
            action: .retry, secondaryAction: .openSettings)])
        #expect(setup.sleeps.recorded.count == 2)

        setup.server.enqueue(Self.answer)
        setup.harness.agent.retry()
        await setup.harness.agent.waitUntilIdle()
        #expect(setup.harness.notices.isEmpty)
        #expect(setup.harness.assistantTexts == ["Da bin ich."])
    }

    @Test func aModelThatIsNotInstalledIsNamed() async throws {
        let setup = try setup(model: "llama3")
        setup.server.enqueue(.json(status: 404, #"{"error":{"message":"model \"llama3\" not found, try pulling it first","type":"api_error","param":null,"code":null}}"#))
        await setup.harness.send("Hallo")
        #expect(setup.harness.notices == [Notice(
            style: .error,
            message: "The model “llama3” is not installed on this Mac. Download it in Ollama or LM Studio, or choose a different model in Settings.",
            action: .openSettings, secondaryAction: .retry)])
        #expect(setup.server.requests.count == 1)
    }

    @Test func aModelWithoutToolsSaysWhichOnesWork() async throws {
        let setup = try setup(model: "gemma3:4b", tools: [MockSearchFilesTool(log: MockToolLog())])
        setup.server.enqueue(.json(status: 400, #"{"error":{"message":"registry.ollama.ai/library/gemma3:4b does not support tools","type":"api_error","param":null,"code":null}}"#))
        await setup.harness.send("Hallo")
        #expect(setup.harness.notices == [Notice(style: .error, message: LLMError.toolsNotSupported(model: "gemma3:4b").userMessage,
                                                 action: .openSettings, secondaryAction: .retry)])
    }

    @Test func aRemoteServerThatWantsAKeySaysSo() async throws {
        let setup = try setup(base: "https://llm.example.com/v1", model: "gpt-5")
        setup.server.enqueue(.json(status: 401, #"{"error":{"message":"You didn't provide an API key.","type":"invalid_request_error"}}"#))
        await setup.harness.send("Hallo")
        #expect(setup.harness.notices == [Notice(style: .error, message: LLMError.missingAPIKey.userMessage,
                                                 action: .openSettings, secondaryAction: .retry)])
    }

    @Test func anUnreachableRemoteServerPointsToItsAddress() async throws {
        let setup = try setup(base: "http://192.168.1.20:11434/v1")
        setup.server.enqueue(.failure(.cannotFindHost), .failure(.cannotFindHost), .failure(.cannotFindHost))
        await setup.harness.send("Hallo")
        #expect(setup.harness.notices.first?.message
                == "The server 192.168.1.20:11434 cannot be reached. Check the address in Settings and your network connection.")
        #expect(setup.harness.notices.first?.actions == [.retry, .openSettings])
    }
}
