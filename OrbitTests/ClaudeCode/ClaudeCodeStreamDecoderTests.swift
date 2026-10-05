import Foundation
import Testing
@testable import Orbit

/// Stdout lines of Claude Code 2.1.251, recorded on 2026-09-29 (shortened),
/// and the decoder's view of them.
@Suite("Claude Code stream decoder")
struct ClaudeCodeStreamDecoderTests {
    static let turnID = "616cf19d-7101-48fc-b9e4-a4de7c3448b6"

    static let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"s","tools":["mcp__orbit__get_test_value"],"mcp_servers":[{"name":"orbit","status":"connected"}],"model":"claude-sonnet-5","permissionMode":"default","slash_commands":[],"skills":[],"agents":["claude","general-purpose","statusline-setup"],"plugins":[],"apiKeySource":"none","claude_code_version":"2.1.251","capabilities":["interrupt_receipt_v1"],"memory_paths":null}"#

    /// A tool round trip: tool_use, the tool result, then the answer.
    static let toolTurn = [
        #"{"type":"command_lifecycle","command_uuid":"616cf19d-7101-48fc-b9e4-a4de7c3448b6","state":"started","uuid":"x","session_id":"s"}"#,
        initLine,
        #"{"type":"system","subtype":"status","status":"requesting","uuid":"x","session_id":"s"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-sonnet-5","id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":779,"output_tokens":1}}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_019WbTaSjZ1sxNEbGtxrqb2M","name":"mcp__orbit__get_test_value","input":{},"caller":{"type":"direct"}}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"model":"claude-sonnet-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_019WbTaSjZ1sxNEbGtxrqb2M","name":"mcp__orbit__get_test_value","input":{}}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"usage":{"output_tokens":31}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1791201600,"rateLimitType":"seven_day","utilization":0.31,"isUsingOverage":false},"uuid":"x","session_id":"s"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_019WbTaSjZ1sxNEbGtxrqb2M","type":"tool_result","content":[{"type":"text","text":"The test value is PURPLE-42."}]}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-sonnet-5","id":"msg_2","type":"message","role":"assistant","content":[],"usage":{"input_tokens":872,"output_tokens":1}}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret reasoning"}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"The test value is "}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"PURPLE-42."}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"model":"claude-sonnet-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"The test value is PURPLE-42."}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null,"stop_details":null},"usage":{"output_tokens":8}},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s","parent_tool_use_id":null}"#,
        #"{"is_error":false,"duration_api_ms":5884,"num_turns":2,"stop_reason":"end_turn","session_id":"s","total_cost_usd":0.003802,"permission_denials":[],"terminal_reason":"completed","subtype":"success","api_error_status":null,"result":"The test value is PURPLE-42.","user_message_uuid":"616cf19d-7101-48fc-b9e4-a4de7c3448b6","type":"result","duration_ms":5901,"uuid":"x","usage":{"input_tokens":1651,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}"#,
    ]

    private func decode(_ lines: [String], turnID: String = turnID) throws -> (events: [LLMEvent], decoder: ClaudeCodeStreamDecoder) {
        var decoder = ClaudeCodeStreamDecoder(turnID: turnID)
        var events: [LLMEvent] = []
        for line in lines {
            events += try decoder.consume(try JSONValue.parse(line))
        }
        return (events, decoder)
    }

    private func texts(_ events: [LLMEvent]) -> [String] {
        events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }
    }

    @Test func decodesAToolRoundTrip() throws {
        let (events, decoder) = try decode(Self.toolTurn)
        #expect(texts(events) == ["The test value is ", "PURPLE-42."])
        let started = events.compactMap { event -> String? in
            if case .toolCallStarted(let id, let name) = event { return "\(id)/\(name)" }
            return nil
        }
        #expect(started == ["toolu_019WbTaSjZ1sxNEbGtxrqb2M/get_test_value"])
        #expect(!events.contains { if case .toolCall = $0 { true } else { false } })
        let rateLimits = events.compactMap { if case .rateLimit(let info) = $0 { info } else { nil } }
        #expect(rateLimits == [RateLimitInfo(status: "allowed_warning", utilization: 0.31,
                                             resetsAt: Date(timeIntervalSince1970: 1_791_201_600),
                                             window: "seven_day", isUsingOverage: false)])

        let turn = try #require(decoder.finishedTurn)
        #expect(turn.content == [.text("The test value is PURPLE-42.")])
        #expect(turn.stopReason == .endTurn)
        #expect(turn.model == "claude-sonnet-5")
        #expect(turn.usage == TokenUsage(inputTokens: 1651, outputTokens: 50))
        #expect(decoder.toolCallCount == 1)
        let info = try #require(decoder.initInfo)
        #expect(info.tools == ["mcp__orbit__get_test_value"])
        #expect(info.mcpServers == ["orbit": "connected"])
        #expect(info.skills.isEmpty && info.slashCommands.isEmpty && !info.hasMemoryPaths)
        #expect(info.version == "2.1.251")
    }

    @Test func textOfEveryModelCallBecomesItsOwnBlock() throws {
        let lines = [
            Self.initLine,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","model":"claude-sonnet-5"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Ich suche."}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"mcp__orbit__search_files","input":{}}}}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m2","model":"claude-sonnet-5"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Gefunden."}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Gefunden.","stop_reason":"end_turn","user_message_uuid":"616CF19D-7101-48FC-B9E4-A4DE7C3448B6"}"#,
        ]
        let (events, decoder) = try decode(lines)
        #expect(texts(events) == ["Ich suche.", "Gefunden."])
        #expect(decoder.finishedTurn?.content == [.text("Ich suche."), .text("Gefunden.")])
    }

    @Test func messagesThatWereNotStreamedContributeTheirText() throws {
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-sonnet-5","id":"m9","content":[{"type":"thinking","thinking":"x","signature":"s"},{"type":"text","text":"Ohne Streaming"}]},"parent_tool_use_id":null}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Ohne Streaming","stop_reason":"end_turn"}"#,
        ]
        let (events, decoder) = try decode(lines)
        #expect(texts(events) == ["Ohne Streaming"])
        #expect(decoder.finishedTurn?.content == [.text("Ohne Streaming")])
        #expect(decoder.finishedTurn?.model == "claude-sonnet-5")
    }

    @Test func theResultTextIsTheFallbackAnswer() throws {
        let (events, decoder) = try decode([#"{"type":"result","subtype":"success","is_error":false,"result":"Nur im Ergebnis"}"#])
        #expect(texts(events) == ["Nur im Ergebnis"])
        #expect(decoder.finishedTurn?.content == [.text("Nur im Ergebnis")])
    }

    @Test func aResultOfAnEarlierMessageIsSkipped() throws {
        let lines = [
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","user_message_uuid":"00000000-0000-0000-0000-000000000000"}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5","id":"m1","content":[{"type":"text","text":"Frisch"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Frisch","user_message_uuid":"616cf19d-7101-48fc-b9e4-a4de7c3448b6"}"#,
        ]
        let (_, decoder) = try decode(lines)
        #expect(decoder.finishedTurn?.content == [.text("Frisch")])
    }

    @Test func subagentOutputIsIgnored() throws {
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"sub","model":"claude-haiku"}},"parent_tool_use_id":"toolu_parent"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"sub text"}},"parent_tool_use_id":"toolu_parent"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":""}"#,
        ]
        let (events, decoder) = try decode(lines)
        #expect(texts(events).isEmpty)
        #expect(decoder.finishedTurn?.content == [])
    }

    @Test func mapsTheStopReason() throws {
        let refusal = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","model":"claude-sonnet-5"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"I can"}}}"#,
            #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"I can","stop_reason":"refusal"}"#,
        ]
        #expect(try decode(refusal).decoder.finishedTurn?.stopReason == .refusal(category: "cyber"))
        #expect(ClaudeCodeStreamDecoder.stopReason("tool_use", category: nil) == .endTurn)
        #expect(ClaudeCodeStreamDecoder.stopReason("max_tokens", category: nil) == .maxTokens)
        #expect(ClaudeCodeStreamDecoder.stopReason(nil, category: nil) == .endTurn)
        let maxTurns = [#"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":[]}"#]
        #expect(try decode(maxTurns).decoder.finishedTurn?.stopReason == .other("max_turns"))
    }

    @Test func throwsTheErrorOfAFailedTurnWithoutItsText() throws {
        let lines = [
            #"{"type":"assistant","message":{"model":"<synthetic>","id":"e1","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"is_api_error_message":true}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","api_error_status":null}"#,
        ]
        #expect(throws: LLMError.claudeCodeNotLoggedIn) { try decode(lines) }

        let interrupted = [
            #"{"type":"assistant","message":{"model":"claude-sonnet-5","id":"m1","content":[{"type":"text","text":"one\ntwo"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","errors":["[ede_diagnostic] result_type=user"],"user_message_uuid":"616cf19d-7101-48fc-b9e4-a4de7c3448b6"}"#,
        ]
        #expect(throws: LLMError.cancelled) { try decode(interrupted) }
    }

    /// An error about the model names it as it is set in Orbit ("opus"), not
    /// as Claude Code resolved it.
    @Test func aMissingModelIsNamedAsSetInOrbit() throws {
        let lines = [
            Self.initLine,
            #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 404 model: claude-opus-x not_found_error","api_error_status":404}"#,
        ]
        for (configured, expected) in [("opus", "opus"), ("", "claude-sonnet-5")] {
            var decoder = ClaudeCodeStreamDecoder(turnID: Self.turnID, configuredModel: configured)
            #expect(throws: LLMError.modelNotFound(model: expected)) {
                for line in lines {
                    _ = try decoder.consume(try JSONValue.parse(line))
                }
            }
        }
    }

    @Test func aRejectedRateLimitMeansTheUsageLimit() throws {
        let lines = [
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790700000,"rateLimitType":"five_hour"}}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 3pm","api_error_status":429}"#,
        ]
        #expect(throws: LLMError.usageLimitReached(resetsAt: Date(timeIntervalSince1970: 1_790_700_000))) {
            try decode(lines)
        }
    }

    /// The turn's warning about the seven-day window (as recorded above), then
    /// a limit Claude Code reports only as text: the reset is the text's next
    /// 3 pm in Berlin, not the warning's.
    @Test func aWarningOfAnotherWindowDoesNotSetTheReset() throws {
        let text = "You've hit your limit · resets 3pm (Europe/Berlin)"
        let lines = [
            Self.toolTurn.first { $0.contains("rate_limit_event") } ?? "",
            #"{"type":"result","subtype":"success","is_error":true,"result":"\#(text)","api_error_status":429}"#,
        ]
        let before = Date()
        var thrown: LLMError?
        do {
            _ = try decode(lines)
        } catch let error as LLMError {
            thrown = error
        }
        let after = Date()
        guard case .usageLimitReached(let reset?) = thrown else {
            Issue.record("a usage limit with its reset time, got \(String(describing: thrown))")
            return
        }
        #expect(reset != Date(timeIntervalSince1970: 1_791_201_600), "the seven-day warning's reset")
        #expect([before, after].compactMap { ClaudeCodeErrorClassifier.resetTime(in: text, now: $0) }.contains(reset))
    }

    @Test func ignoresUnknownMessagesAndStopsAfterTheResult() throws {
        var decoder = ClaudeCodeStreamDecoder(turnID: Self.turnID)
        #expect(try decoder.consume(["type": "keep_alive"]).isEmpty)
        #expect(try decoder.consume(["type": "prompt_suggestion", "suggestion": "x"]).isEmpty)
        _ = try decoder.consume(try JSONValue.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"x"}"#))
        #expect(decoder.isFinished)
        #expect(try decoder.consume(try JSONValue.parse(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"late"}}}"#)).isEmpty)
    }
}
