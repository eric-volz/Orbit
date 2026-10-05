import Foundation
import Testing
@testable import Orbit

/// End-to-end checks against the local Ollama server (model `gpt-oss:20b`),
/// through both of its APIs. Opt-in:
///
///     ORBIT_LIVE_TESTS=1 Scripts/swiftpm.sh test --filter LiveOllamaTests
@Suite(
    "Live Ollama",
    .enabled(if: ProcessInfo.processInfo.environment["ORBIT_LIVE_TESTS"] == "1"),
    .serialized
)
struct LiveOllamaTests {
    enum Endpoint: String, CaseIterable, Sendable {
        /// Anthropic Messages API at http://127.0.0.1:11434 (with a dummy key).
        case anthropic
        /// Chat Completions at http://127.0.0.1:11434/v1 (without a key).
        case openAICompatible
    }

    private static let model = "gpt-oss:20b"
    private static let systemPrompt = "You are Orbit, a concise assistant on the user's Mac. Use tools instead of guessing."

    private func provider(_ endpoint: Endpoint, memory: ProviderFeatureMemory = ProviderFeatureMemory()) throws -> any LLMProvider {
        let transport = ProviderTransport(session: ProviderHTTP.session, featureMemory: memory)
        return switch endpoint {
        case .anthropic:
            try AnthropicProvider(configuration: ProviderConfiguration(
                kind: .anthropic, apiKey: "ollama", baseURL: URL(string: "http://127.0.0.1:11434")
            ), transport: transport)
        case .openAICompatible:
            try OpenAICompatibleProvider(configuration: ProviderConfiguration(
                kind: .openAICompatible, apiKey: "", baseURL: URL(string: "http://127.0.0.1:11434/v1")
            ), transport: transport)
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: Endpoint.allCases)
    func streamsAShortAnswer(endpoint: Endpoint) async throws {
        let request = LLMRequest(
            model: Self.model, systemPrompt: Self.systemPrompt,
            messages: [.user("Count from 1 to 5, separated by commas. Reply with the numbers only.")],
            effort: .low
        )
        let result = await LLMTest.collect(try provider(endpoint).stream(request))
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.textDeltas.count > 1)
        #expect(result.endCount == 1)
        let turn = try #require(result.turn)
        #expect(turn.stopReason == .endTurn)
        #expect(turn.model == Self.model)
        #expect(turn.text.contains("3"))
        #expect(result.progressNotes.isEmpty) // reasoning of gpt-oss is never shown
    }

    @Test(.timeLimit(.minutes(3)), arguments: Endpoint.allCases)
    func completesAToolRoundTrip(endpoint: Endpoint) async throws {
        let memory = ProviderFeatureMemory()
        let provider = try provider(endpoint, memory: memory)
        var messages: [Message] = [.user("What's the weather in Berlin right now? Use the get_weather tool.")]

        let first = await LLMTest.collect(provider.stream(LLMRequest(
            model: Self.model, systemPrompt: Self.systemPrompt, messages: messages, tools: [LLMTest.weatherTool], effort: .low
        )))
        #expect(first.error == nil, "\(String(describing: first.error))")
        let turn = try #require(first.turn)
        #expect(turn.stopReason == .toolUse)
        let call = try #require(turn.toolCalls.first)
        #expect(call.name == "get_weather")
        #expect(call.inputParseError == nil)
        #expect(call.input["city"]?.stringValue?.lowercased().contains("berlin") == true)
        #expect(first.startedToolCalls.contains("\(call.id)/get_weather"))
        #expect(first.toolCalls == turn.toolCalls)

        messages.append(Message(role: .assistant, content: turn.content, model: turn.model))
        messages.append(Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: call.id, content: "18 °C, sunny"))]))
        let second = await LLMTest.collect(provider.stream(LLMRequest(
            model: Self.model, systemPrompt: Self.systemPrompt, messages: messages, tools: [LLMTest.weatherTool], effort: .low
        )))
        #expect(second.error == nil, "\(String(describing: second.error))")
        let answer = try #require(second.turn)
        #expect(answer.stopReason == .endTurn)
        #expect(answer.text.contains("18"))
        #expect(second.textDeltas.count > 1)

        if endpoint == .openAICompatible, !OpenAIWire.reasoningToEcho(in: messages).isEmpty {
            // The reasoning went back in Ollama's own field and was accepted.
            #expect(memory.reasoningField(host: "127.0.0.1:11434", model: Self.model) == .reasoning)
            #expect(!memory.isDisabled(.openAIReasoningEcho, host: "127.0.0.1:11434", model: Self.model))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Endpoint.allCases)
    func validatesTheModel(endpoint: Endpoint) async throws {
        let provider = try provider(endpoint)
        try await provider.validateConfiguration(model: Self.model)
        await #expect(throws: LLMError.modelNotFound(model: "orbit-bogus-model")) {
            try await provider.validateConfiguration(model: "orbit-bogus-model")
        }
    }
}
