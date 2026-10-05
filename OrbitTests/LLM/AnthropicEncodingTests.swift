import Foundation
import Testing
@testable import Orbit

@Suite("Anthropic request encoding")
struct AnthropicEncodingTests {
    private let request = LLMRequest(
        model: "claude-sonnet-5-5",
        systemPrompt: "You are Orbit.",
        messages: [.user("Hi")],
        tools: [LLMTest.weatherTool],
        effort: .low
    )

    private func body(_ request: LLMRequest, officialAPI: Bool) -> String {
        let features = AnthropicFeatures.for(model: request.model, effort: request.effort, officialAPI: officialAPI)
        return AnthropicWire.requestBody(for: request, messages: request.messages, features: features).jsonString()
    }

    private func messages(_ messages: [Message]) -> String {
        JSONValue.array(AnthropicWire.encode(messages)).jsonString()
    }

    // MARK: Bodies

    @Test func officialAPIBodyUsesAllFeatures() {
        #expect(body(request, officialAPI: true) == #"{"cache_control":{"type":"ephemeral"},"fallbacks":"default","max_tokens":32000,"messages":[{"content":[{"text":"Hi","type":"text"}],"role":"user"}],"model":"claude-sonnet-5-5","output_config":{"effort":"low"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"You are Orbit.","type":"text"}],"thinking":{"display":"updates","type":"adaptive"},"tools":[{"description":"Get the current weather for a city.","eager_input_streaming":true,"input_schema":{"properties":{"city":{"description":"City name","type":"string"}},"required":["city"],"type":"object"},"name":"get_weather"}]}"#)
    }

    @Test func customBaseGetsNoOfficialOnlyFeatures() {
        // A proxy in front of Claude: effort is kept, beta features and automatic caching are not.
        #expect(body(request, officialAPI: false) == #"{"max_tokens":32000,"messages":[{"content":[{"text":"Hi","type":"text"}],"role":"user"}],"model":"claude-sonnet-5-5","output_config":{"effort":"low"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"You are Orbit.","type":"text"}],"tools":[{"description":"Get the current weather for a city.","input_schema":{"properties":{"city":{"description":"City name","type":"string"}},"required":["city"],"type":"object"},"name":"get_weather"}]}"#)
    }

    @Test func nonClaudeModelsGetNoEffort() {
        var ollama = request
        ollama.model = "gpt-oss:20b"
        ollama.tools = []
        ollama.maxTokens = 2048
        #expect(body(ollama, officialAPI: false) == #"{"max_tokens":2048,"messages":[{"content":[{"text":"Hi","type":"text"}],"role":"user"}],"model":"gpt-oss:20b","stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"You are Orbit.","type":"text"}]}"#)
    }

    @Test func toolsAndSystemAreOmittedWhenEmpty() {
        let bare = LLMRequest(model: "claude-haiku-4-5", systemPrompt: "", messages: [.user("Hi")])
        #expect(body(bare, officialAPI: true) == #"{"cache_control":{"type":"ephemeral"},"max_tokens":32000,"messages":[{"content":[{"text":"Hi","type":"text"}],"role":"user"}],"model":"claude-haiku-4-5","stream":true}"#)
    }

    /// Per the API reference: `fallbacks: "default"` on Sonnet 5.5, Opus 5.5,
    /// Opus 5, Fable 5, Fable 5.1 and Mythos 5.1 (Mythos 5 has no refusal
    /// classifiers); `display: "updates"` on Fable 5.1, Mythos 5.1, Fable 5,
    /// Opus 5.5 and Sonnet 5.5.
    @Test(arguments: [
        ("claude-sonnet-5-5", "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18"),
        ("claude-opus-5-5", "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18"),
        ("claude-fable-5-1", "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18"),
        ("claude-fable-5", "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18"),
        ("claude-mythos-5-1", "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18"),
        ("claude-opus-5", "server-side-fallback-2026-07-01"),
        ("claude-mythos-5", nil),
        ("claude-sonnet-5", nil),
        ("claude-opus-4-8", nil),
        ("claude-haiku-4-5", nil),
    ] as [(String, String?)])
    func betaHeaderPerModel(model: String, expected: String?) {
        let features = AnthropicFeatures.for(model: model, effort: .high, officialAPI: true)
        #expect(features.betaHeader == expected)
        #expect(features.refusalFallback == (expected?.contains(AnthropicWire.refusalFallbackBeta) ?? false))
        #expect(features.progressUpdates == (expected?.contains(AnthropicWire.progressUpdatesBeta) ?? false))
        #expect(AnthropicFeatures.for(model: model, effort: .high, officialAPI: false).betaHeader == nil)
    }

    @Test func fallbackAndProgressUpdatesReachTheBody() throws {
        var fable = request
        fable.model = "claude-fable-5"
        let json = try JSONValue.parse(body(fable, officialAPI: true))
        #expect(json["fallbacks"] == "default")
        #expect(json["thinking"] == ["type": "adaptive", "display": "updates"])

        var mythos = request
        mythos.model = "claude-mythos-5"
        let old = try JSONValue.parse(body(mythos, officialAPI: true))
        #expect(old["fallbacks"] == nil)
        #expect(old["thinking"] == nil)
    }

    @Test(arguments: [
        ("claude-sonnet-5-5", true), ("claude-sonnet-5", true), ("claude-opus-5", true), ("claude-opus-5-5", true),
        ("claude-fable-5-1", true), ("claude-mythos-5", true), ("claude-opus-4-5", true), ("claude-opus-4-8", true),
        ("claude-sonnet-4-6", true), ("claude-sonnet-4-5", false), ("claude-haiku-4-5", false),
        ("claude-opus-4-1", false), ("gpt-oss:20b", false), ("llama3.2", false),
    ])
    func effortSupport(model: String, supported: Bool) {
        #expect(AnthropicModelSupport.supportsEffort(model) == supported)
        let features = AnthropicFeatures.for(model: model, effort: .medium, officialAPI: true)
        #expect(features.effort == (supported ? .medium : nil))
    }

    @Test func noEffortRequestedMeansNoOutputConfig() {
        var noEffort = request
        noEffort.effort = nil
        #expect(!body(noEffort, officialAPI: true).contains("output_config"))
    }

    @Test(arguments: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-opus-4-8", "gpt-oss:20b"])
    func neverSendsForbiddenParameters(model: String) throws {
        for official in [true, false] {
            var request = request
            request.model = model
            let json = try JSONValue.parse(body(request, officialAPI: official))
            for key in ["tool_choice", "temperature", "top_p", "top_k"] {
                #expect(json[key] == nil, "\(key) for \(model)")
            }
            #expect(json["thinking"]?["type"] != "disabled")
            if let thinking = json["thinking"] {
                #expect(thinking == ["type": "adaptive", "display": "updates"])
            }
        }
    }

    @Test func maxTokensOverride() throws {
        var capped = request
        capped.maxTokens = 1024
        #expect(try JSONValue.parse(body(capped, officialAPI: true))["max_tokens"] == 1024)
    }

    @Test func bodyIsByteDeterministic() {
        let first = AnthropicWire.requestBody(for: request, messages: request.messages, features: .for(model: request.model, effort: .low, officialAPI: true)).jsonData()
        for _ in 0..<5 {
            let again = AnthropicWire.requestBody(for: request, messages: request.messages, features: .for(model: request.model, effort: .low, officialAPI: true)).jsonData()
            #expect(again == first)
        }
    }

    // MARK: Messages

    @Test func echoesThinkingToolUseAndResults() {
        let history = [
            Message.user("Q"),
            Message(role: .assistant, content: [
                .thinking(text: "Plan", signature: "c2ln"),
                .thinking(text: "raw reasoning", signature: nil),
                .redactedThinking(data: "ZW5j"),
                .thinking(text: "", signature: "b25seQ=="),
                .text("A"),
                .toolUse(ToolCall(id: "toolu_1", name: "get_weather", input: ["city": "Berlin"], rawInput: #"{"city": "Berlin"}"#)),
            ]),
            Message(role: .user, content: [
                .toolResult(ToolResultBlock(toolCallID: "toolu_1", content: "18 °C, sunny")),
                .toolResult(ToolResultBlock(toolCallID: "toolu_2", content: "boom", isError: true)),
            ]),
        ]
        #expect(messages(history) == #"[{"content":[{"text":"Q","type":"text"}],"role":"user"},{"content":[{"signature":"c2ln","thinking":"Plan","type":"thinking"},{"thinking":"raw reasoning","type":"thinking"},{"data":"ZW5j","type":"redacted_thinking"},{"signature":"b25seQ==","thinking":"","type":"thinking"},{"text":"A","type":"text"},{"id":"toolu_1","input":{"city":"Berlin"},"name":"get_weather","type":"tool_use"}],"role":"assistant"},{"content":[{"content":"18 °C, sunny","tool_use_id":"toolu_1","type":"tool_result"},{"content":"boom","is_error":true,"tool_use_id":"toolu_2","type":"tool_result"}],"role":"user"}]"#)
    }

    @Test func mergesConsecutiveRolesAndPutsToolResultsFirst() {
        let history = [
            Message.user("context"),
            Message.user("question"),
            Message(role: .assistant, content: [.text("  \n")]), // nothing to send: dropped
            Message(role: .assistant, content: [.text("A1")]),
            Message(role: .assistant, content: [.toolUse(ToolCall(id: "t1", name: "x"))]),
            Message(role: .user, content: [.text("note"), .toolResult(ToolResultBlock(toolCallID: "t1", content: "ok"))]),
        ]
        #expect(messages(history) == #"[{"content":[{"text":"context","type":"text"},{"text":"question","type":"text"}],"role":"user"},{"content":[{"text":"A1","type":"text"},{"id":"t1","input":{},"name":"x","type":"tool_use"}],"role":"assistant"},{"content":[{"content":"ok","tool_use_id":"t1","type":"tool_result"},{"text":"note","type":"text"}],"role":"user"}]"#)
    }

    @Test func skipsBlocksWithNothingToSend() {
        let history = [
            Message(role: .user, content: [.text(""), .text("Hi"), .text(" ")]),
            Message(role: .assistant, content: [.thinking(text: "", signature: nil), .text("Hello")]),
        ]
        #expect(messages(history) == #"[{"content":[{"text":"Hi","type":"text"}],"role":"user"},{"content":[{"text":"Hello","type":"text"}],"role":"assistant"}]"#)
    }

    @Test func opaqueBlocksAreSentVerbatim() {
        let opaque: JSONValue = ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "x"]]
        let history = [Message.user("Q"), Message(role: .assistant, content: [.opaque(opaque), .text("A")])]
        #expect(AnthropicWire.encode(history)[1]["content"]?[0] == opaque)
    }

    @Test func toolUseInputIsAlwaysAnObject() {
        let broken = ToolCall(id: "t", name: "x", input: .array([1]), rawInput: "[1]", inputParseError: "not an object")
        #expect(AnthropicWire.encode(.toolUse(broken))?["input"] == .object([:]))
    }

    @Test func removingThinkingKeepsEverythingElse() {
        let history = [
            Message.user("Q"),
            Message(role: .assistant, content: [.thinking(text: "t", signature: "s"), .redactedThinking(data: "r"), .text("A")]),
        ]
        #expect(AnthropicWire.containsThinking(history))
        let stripped = AnthropicWire.removingThinking(from: history)
        #expect(!AnthropicWire.containsThinking(stripped))
        #expect(stripped[1].content == [.text("A")])
        #expect(stripped[1].id == history[1].id)
    }

    // MARK: 400 classification

    @Test func recognizesThinkingBindingErrors() {
        let bound = "messages.5.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` to \"drop_block\". That setting requires the `thinking-binding-controls-2026-08-01` value in the `anthropic-beta` header."
        #expect(AnthropicWire.rejectsHistoryThinking(bound))
        #expect(AnthropicWire.rejectsHistoryThinking("messages.1.content.0.thinking.signature: Field required"))
        #expect(AnthropicWire.rejectsHistoryThinking("body.messages.1.content.0.thinking.signature: Field required"))
        #expect(AnthropicWire.rejectsHistoryThinking("messages.3.content.0: Invalid `signature` in `thinking` block"))
        #expect(!AnthropicWire.rejectsHistoryThinking("messages: roles must alternate between \"user\" and \"assistant\""))
    }

    @Test(arguments: [
        "Unexpected value(s) `thinking-display-updates-2026-08-18` for the `anthropic-beta` header.",
        "fallbacks: Extra inputs are not permitted",
        "thinking.display: Input should be 'summarized' or 'omitted'",
        "tools.0.custom.eager_input_streaming: Extra inputs are not permitted",
        "output_config: Extra inputs are not permitted",
        "This model does not support the effort parameter.",
        "cache_control: Extra inputs are not permitted",
        "body.system.0.cache_control: Extra inputs are not permitted",
    ])
    func recognizesOptionalFeatureErrors(message: String) {
        #expect(AnthropicWire.rejectsOptionalFeature(message))
    }

    @Test func otherErrorsAreNotFeatureErrors() {
        #expect(!AnthropicWire.rejectsOptionalFeature("messages: roles must alternate between \"user\" and \"assistant\""))
        #expect(!AnthropicWire.rejectsOptionalFeature("max_tokens: 64000 > 32000, which is the maximum allowed"))
    }

    @Test(arguments: [
        ("end_turn", StopReason.endTurn), ("tool_use", .toolUse), ("max_tokens", .maxTokens),
        ("stop_sequence", .stopSequence), ("model_context_window_exceeded", .contextWindowExceeded),
        ("pause_turn", .other("pause_turn")),
    ])
    func mapsStopReasons(raw: String, expected: StopReason) {
        #expect(AnthropicWire.stopReason(raw, category: nil) == expected)
    }

    @Test func refusalKeepsItsCategory() {
        #expect(AnthropicWire.stopReason("refusal", category: "cyber") == .refusal(category: "cyber"))
        #expect(AnthropicWire.stopReason("refusal", category: nil) == .refusal(category: nil))
    }
}
