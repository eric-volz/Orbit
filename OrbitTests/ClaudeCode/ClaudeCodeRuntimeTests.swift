import Darwin
import Foundation
import Testing
@testable import Orbit

/// The runtime and provider against the fake CLI (OrbitTests/Fixtures/FakeClaude/claude):
/// real processes, the real MCP bridge over localhost HTTP.
@Suite("Claude Code runtime (fake CLI)")
struct ClaudeCodeRuntimeTests {
    /// Directories of one test: the fake's records and the CLI's working directory.
    struct Sandbox {
        let root: URL
        let logs: URL
        let work: URL

        init() throws {
            root = try ClaudeCodeTest.makeDirectory("orbit-cc-runtime")
            logs = root.appendingPathComponent("logs", isDirectory: true)
            work = root.appendingPathComponent("work/ClaudeCode", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        }

        func remove() {
            ClaudeCodeTest.removeDirectory(root)
        }

        func runtime(_ scenario: String, idleTimeout: Duration = .seconds(15 * 60),
                     interruptTimeout: Duration = .seconds(10),
                     sleep: (@Sendable (Duration) async throws -> Void)? = nil) -> ClaudeCodeRuntime {
            ClaudeCodeTest.runtime(scenario: scenario, logs: logs, workingDirectory: work, idleTimeout: idleTimeout,
                                   interruptTimeout: interruptTimeout, sleep: sleep)
        }

        /// The fake's argument list of process `pid` (empty arguments kept).
        func arguments(of pid: pid_t) -> [String] {
            let text = (try? String(contentsOf: logs.appendingPathComponent("args-\(pid).txt"), encoding: .utf8)) ?? ""
            return Array(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast())
        }

        func environment(of pid: pid_t) -> [String: String] {
            var environment: [String: String] = [:]
            for line in ClaudeCodeTest.lines(of: logs.appendingPathComponent("env-\(pid).txt")) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { environment[parts[0]] = parts[1] }
            }
            return environment
        }

        func records(_ name: String, of pid: pid_t) -> [String] {
            ClaudeCodeTest.lines(of: logs.appendingPathComponent("\(name)-\(pid).log"))
        }

        func workFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).sorted()
        }
    }

    private static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text("<orbit_context>now</orbit_context>"), .text(text)])
    }

    // MARK: Streaming

    @Test func streamsTextAndStartsTheCLIIsolated() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("text")
        defer { runtime.shutdown() }

        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("Hallo")], conversationID: UUID()))
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.textDeltas == ["Hallo", " Welt"])
        #expect(result.endCount == 1)
        let turn = try #require(result.turn)
        #expect(turn.content == [.text("Hallo Welt")])
        #expect(turn.stopReason == .endTurn)
        #expect(turn.model == "claude-fake-1")
        #expect(turn.usage == TokenUsage(inputTokens: 12, outputTokens: 7, cacheReadInputTokens: 3, cacheCreationInputTokens: 2))

        let pid = try #require(await runtime.currentProcessID())
        let arguments = sandbox.arguments(of: pid)
        let promptFile = try #require(arguments.firstIndex(of: "--system-prompt-file").map { arguments[$0 + 1] })
        #expect(arguments == ClaudeCodeLaunch.arguments(model: "sonnet", effort: .low, systemPromptFile: promptFile,
                                                        mcpConfigFile: nil))
        #expect(promptFile.hasPrefix(sandbox.work.path + "/system-prompt-"))
        #expect(try String(contentsOfFile: promptFile, encoding: .utf8) == "You are Orbit (test).")
        let promptAttributes = try FileManager.default.attributesOfItem(atPath: promptFile)
        #expect((promptAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let workAttributes = try FileManager.default.attributesOfItem(atPath: sandbox.work.path)
        #expect((workAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(ClaudeCodeTest.lines(of: sandbox.logs.appendingPathComponent("cwd-\(pid).txt")) == [sandbox.work.path])

        let environment = sandbox.environment(of: pid)
        #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(environment["DISABLE_TELEMETRY"] == "1")
        #expect(environment["MCP_TOOL_TIMEOUT"] == "3600000")
        #expect(!environment.keys.contains { $0.hasPrefix("ANTHROPIC_") || $0 == "CLAUDECODE" })

        let sent = ClaudeCodeTest.stdinMessages(of: pid, in: sandbox.logs)
        #expect(sent.count == 1)
        #expect(ClaudeCodeTest.textBlocks(sent[0]) == ["<orbit_context>now</orbit_context>", "Hallo"])

        let info = await runtime.currentInitInfo()
        #expect(info?.model == "claude-fake-1" && info?.skills == [] && info?.tools == [])
    }

    @Test(arguments: ["no_stream", "noise", "stale_result"])
    func toleratesOutputVariants(scenario: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime(scenario)
        defer { runtime.shutdown() }
        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("Hallo")], conversationID: UUID()))
        #expect(result.error == nil, "\(String(describing: result.error))")
        let expected = ["no_stream": "Ohne Streaming", "noise": "Hallo Welt", "stale_result": "Frisch"][scenario]
        #expect(result.turn?.text == expected)
        #expect(result.text == expected)
    }

    @Test func reportsRefusals() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("refusal")
        defer { runtime.shutdown() }
        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID()))
        #expect(result.turn?.stopReason == .refusal(category: "cyber"))
    }

    // MARK: Tools

    @Test func runsAToolRoundTripThroughTheBridge() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("tool")
        defer { runtime.shutdown() }
        let executor = StubToolExecutor(result: "PURPLE-42")
        let request = ClaudeCodeTest.request([Self.user("Wert?")], conversationID: UUID(),
                                             tools: [ClaudeCodeTest.testTool], executor: executor)
        let result = try await ClaudeCodeTest.turn(runtime, request)
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.startedToolCalls == ["toolu_fake_1/get_test_value"])
        #expect(result.text == "Ich schaue nach.Das Werkzeug sagt: PURPLE-42")
        #expect(result.turn?.content == [.text("Ich schaue nach."), .text("Das Werkzeug sagt: PURPLE-42")])
        #expect(result.turn?.toolCalls.isEmpty == true)

        let call = try #require(executor.calls.first)
        #expect(executor.calls.count == 1)
        #expect(call.id == "toolu_fake_1")
        #expect(call.name == "get_test_value")
        #expect(call.input == ["label": "fake"])

        let pid = try #require(await runtime.currentProcessID())
        #expect(sandbox.records("mcp", of: pid) == ["initialize 200", "protocol 2025-11-25", "initialized 202", "get 405",
                                                    "tools 200", "tools 1", "call-1 200", "result 1 false PURPLE-42"])
        let arguments = sandbox.arguments(of: pid)
        #expect(arguments.suffix(4).first == "--mcp-config")
        #expect(Array(arguments.suffix(2)) == ["--allowedTools", "mcp__orbit__*"])
        // The config (with the bridge token) is deleted once the CLI connected.
        let configPath = arguments[arguments.count - 3]
        #expect(!FileManager.default.fileExists(atPath: configPath))
        let config = try JSONValue.parse(Data(contentsOf: sandbox.logs.appendingPathComponent("mcp-config-\(pid).json")))
        let server = try #require(config["mcpServers"]?["orbit"])
        #expect(server["url"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        #expect(server["alwaysLoad"] == true)
        #expect(server["headers"]?["Authorization"]?.stringValue?.count == "Bearer ".count + 64)
        let info = await runtime.currentInitInfo()
        #expect(info?.tools == ["mcp__orbit__get_test_value"])
        #expect(info?.mcpServers == ["orbit": "connected"])
    }

    @Test func toolsNeedAnExecutor() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("text")
        defer { runtime.shutdown() }
        let request = ClaudeCodeTest.request([Self.user("x")], conversationID: UUID(), tools: [ClaudeCodeTest.testTool])
        let result = try await ClaudeCodeTest.turn(runtime, request)
        #expect(result.error == nil)
        let pid = try #require(await runtime.currentProcessID())
        #expect(!sandbox.arguments(of: pid).contains("--mcp-config"))
    }

    // MARK: Process reuse

    @Test func reusesTheProcessForLaterTurns() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("echo")
        defer { runtime.shutdown() }
        let conversation = UUID()
        var messages = [Self.user("Erste Frage")]
        let first = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        let pid = try #require(await runtime.currentProcessID())
        #expect(first.turn?.text == "turn 1 pid \(pid) blocks 2 transcript no: Erste Frage")

        messages.append(Message(role: .assistant, content: first.turn?.content ?? []))
        messages.append(Self.user("Zweite Frage"))
        let second = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        #expect(second.turn?.text == "turn 2 pid \(pid) blocks 2 transcript no: Zweite Frage")
        #expect(await runtime.currentProcessID() == pid)
        let sent = ClaudeCodeTest.stdinMessages(of: pid, in: sandbox.logs)
        #expect(sent.count == 2)
        #expect(ClaudeCodeTest.textBlocks(sent[1]) == ["<orbit_context>now</orbit_context>", "Zweite Frage"])
    }

    @Test func aNewProcessGetsTheEarlierConversationAsTranscript() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("echo")
        defer { runtime.shutdown() }
        // As after an app restart: history exists, no process yet.
        let messages = [Self.user("Merke dir MANGO-7"), Message(role: .assistant, content: [.text("Gemerkt.")]),
                        Self.user("Wie war das Wort?")]
        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: UUID()))
        let pid = try #require(await runtime.currentProcessID())
        #expect(result.turn?.text == "turn 1 pid \(pid) blocks 3 transcript yes: Wie war das Wort?")
        let sent = ClaudeCodeTest.stdinMessages(of: pid, in: sandbox.logs)
        let blocks = ClaudeCodeTest.textBlocks(try #require(sent.first))
        #expect(blocks.count == 3)
        #expect(blocks[0].hasPrefix("<previous_conversation>"))
        #expect(blocks[0].contains("Merke dir MANGO-7") && blocks[0].contains("Gemerkt."))
        #expect(!blocks[0].contains("Wie war das Wort?"))
        #expect(blocks[2] == "Wie war das Wort?")
    }

    @Test func changedSettingsOrHistoryStartANewProcess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("echo")
        defer { runtime.shutdown() }
        let conversation = UUID()
        var messages = [Self.user("Eins")]
        let first = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        let firstPID = try #require(await runtime.currentProcessID())
        messages.append(Message(role: .assistant, content: first.turn?.content ?? []))
        messages.append(Self.user("Zwei"))

        // Another model: new process, with the transcript.
        let second = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation,
                                                                                    model: "opus"))
        let secondPID = try #require(await runtime.currentProcessID())
        #expect(secondPID != firstPID)
        #expect(second.turn?.text.contains("transcript yes: Zwei") == true)
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(firstPID) })

        // A retry of the same history (no reply appended): new process again.
        let retry = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation,
                                                                                   model: "opus"))
        #expect(await runtime.currentProcessID() != secondPID)
        #expect(retry.turn?.text.contains("turn 1 ") == true)
    }

    @Test func anotherConversationReplacesTheProcess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("echo")
        defer { runtime.shutdown() }
        _ = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("A")], conversationID: UUID()))
        let first = try #require(await runtime.currentProcessID())
        _ = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("B")], conversationID: UUID()))
        let second = try #require(await runtime.currentProcessID())
        #expect(first != second)
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(first) })
        #expect(ClaudeCodeTest.isRunning(second))
    }

    @Test func theIdleTimeoutEndsTheProcess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let clock = ManualSleeper()
        let runtime = sandbox.runtime("echo", sleep: { try await clock.sleep($0) })
        defer { runtime.shutdown() }
        let conversation = UUID()
        var messages = [Self.user("Eins")]
        let first = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        let pid = try #require(await runtime.currentProcessID())
        #expect(await LLMTest.eventually { clock.sleeperCount == 1 })
        clock.advance()
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(pid) })
        #expect(await runtime.currentProcessID() == nil)
        #expect(await LLMTest.eventually { sandbox.workFiles().isEmpty })

        messages.append(Message(role: .assistant, content: first.turn?.content ?? []))
        messages.append(Self.user("Zwei"))
        let second = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        #expect(await runtime.currentProcessID() != pid)
        #expect(second.turn?.text.contains("transcript yes: Zwei") == true)
    }

    @Test func aNewRequestCancelsThePendingIdleTimeout() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let clock = ManualSleeper()
        let runtime = sandbox.runtime("echo", sleep: { try await clock.sleep($0) })
        defer { runtime.shutdown() }
        let conversation = UUID()
        var messages = [Self.user("Eins")]
        let first = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        let pid = try #require(await runtime.currentProcessID())
        #expect(await LLMTest.eventually { clock.sleeperCount == 1 })
        messages.append(Message(role: .assistant, content: first.turn?.content ?? []))
        messages.append(Self.user("Zwei"))
        _ = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        // The first timer was cancelled; only the new one waits.
        #expect(await LLMTest.eventually { clock.sleeperCount == 1 })
        #expect(await runtime.currentProcessID() == pid)
    }

    // MARK: Errors

    @Test(arguments: [
        ("not_logged_in", LLMError.claudeCodeNotLoggedIn),
        ("usage_limit", .usageLimitReached(resetsAt: Date(timeIntervalSince1970: 1_790_700_000))),
        ("usage_limit_legacy", .usageLimitReached(resetsAt: Date(timeIntervalSince1970: 1_790_700_000))),
        ("network_error", .network(.other)),
        // Named as set in Orbit (the request's "sonnet"), not as the CLI resolved it.
        ("model_not_found", .modelNotFound(model: "sonnet")),
        ("crash", .providerProcessFailed(detail: "Claude Code ended unexpectedly (signal 9)")),
        ("exit_on_start", .claudeCodeOutdated),
    ])
    func mapsFailures(scenario: String, expected: LLMError) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime(scenario)
        defer { runtime.shutdown() }
        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID()))
        #expect(result.llmError == expected)
        #expect(result.endCount == 0)
        // Never the CLI's own words.
        #expect(!(result.llmError?.userMessage.contains("/login") ?? true))
        // A failed turn ends the process; the next request starts over.
        #expect(await runtime.currentProcessID() == nil)
        #expect(await LLMTest.eventually { sandbox.workFiles().isEmpty })
    }

    @Test func aMissingInstallationIsReported() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = ClaudeCodeTest.runtime(scenario: "text", logs: sandbox.logs, workingDirectory: sandbox.work,
                                             locator: ClaudeCodeTest.locator(nil))
        defer { runtime.shutdown() }
        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID()),
                                                   executablePath: sandbox.root.appendingPathComponent("missing/claude").path)
        #expect(result.llmError == .claudeCodeNotInstalled)

        // A configured path is used when nothing else is found.
        let configured = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID()),
                                                       executablePath: ClaudeCodeTest.fakeCLI)
        #expect(configured.error == nil)
    }

    @Test func rejectsRequestsItCannotSend() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("text")
        defer { runtime.shutdown() }
        let noUser = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(
            [Self.user("x"), Message(role: .assistant, content: [.text("y")])], conversationID: UUID()))
        #expect(noUser.llmError == .invalidRequest(message: "The conversation does not end with a user message"))
        let badModel = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID(),
                                                                                    model: "--help"))
        #expect(badModel.llmError == .modelNotFound(model: "--help"))
        let empty = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Message(role: .user, content: [.text(" ")])],
                                                                                 conversationID: UUID()))
        #expect(empty.llmError == .invalidRequest(message: "The request has no text"))
        #expect(await runtime.currentProcessID() == nil)
    }

    @Test func refusesControlRequestsOfTheCLI() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("control_request")
        defer { runtime.shutdown() }
        let result = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID()))
        #expect(result.turn?.text == "Weiter")
        let pid = try #require(await runtime.currentProcessID())
        let responses = ClaudeCodeTest.stdinMessages(of: pid, in: sandbox.logs).filter { $0["type"] == "control_response" }
        #expect(responses.count == 1)
        #expect(responses.first?["response"]?["subtype"] == "error")
        #expect(responses.first?["response"]?["request_id"] == "cli-req-1")
    }

    // MARK: Cancellation

    /// Streams `request` until `ready` returns true for the events so far, then cancels.
    private func cancelDuring(_ runtime: ClaudeCodeRuntime, _ request: LLMRequest,
                              when ready: @escaping @Sendable ([LLMEvent]) -> Bool) async throws -> Duration {
        let provider = try ClaudeCodeProvider(configuration: ProviderConfiguration(kind: .claudeCode, apiKey: "", baseURL: nil),
                                              runtime: runtime)
        let consumer = Task { () -> Duration? in
            var events: [LLMEvent] = []
            var cancelledAt: ContinuousClock.Instant?
            do {
                for try await event in provider.stream(request) {
                    events.append(event)
                    if cancelledAt == nil, ready(events) {
                        cancelledAt = .now
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            } catch {}
            return cancelledAt.map { ContinuousClock.now - $0 }
        }
        return try #require(await consumer.value)
    }

    @Test func cancellingInterruptsTheTurnAndKeepsTheProcess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("slow_then_echo")
        defer { runtime.shutdown() }
        let conversation = UUID()
        var messages = [Self.user("Zähle")]
        let elapsed = try await cancelDuring(runtime, ClaudeCodeTest.request(messages, conversationID: conversation)) { events in
            events.contains { if case .textDelta = $0 { true } else { false } }
        }
        #expect(elapsed < .seconds(1))
        let pid = try #require(await runtime.currentProcessID())
        #expect(await LLMTest.eventually { sandbox.records("events", of: pid) == ["interrupted yes"] })
        let sent = ClaudeCodeTest.stdinMessages(of: pid, in: sandbox.logs)
        #expect(sent.last?["type"] == "control_request")
        #expect(sent.last?["request"]?["subtype"] == "interrupt")

        // The interrupted process continues the conversation.
        messages.append(Message(role: .assistant, content: [.text("tick 1 ")]))
        messages.append(Self.user("Weiter"))
        let next = try await ClaudeCodeTest.turn(runtime, ClaudeCodeTest.request(messages, conversationID: conversation))
        #expect(next.turn?.text == "turn 2 pid \(pid) blocks 2 transcript no: Weiter")
        #expect(ClaudeCodeTest.isRunning(pid))
    }

    @Test func cancellingDuringAToolCallAnswersItAndStopsTheExecution() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("tool")
        defer { runtime.shutdown() }
        let executor = StubToolExecutor(blocks: true)
        let request = ClaudeCodeTest.request([Self.user("Wert?")], conversationID: UUID(), tools: [ClaudeCodeTest.testTool],
                                             executor: executor)
        // No event arrives while the tool runs: poll for the call instead.
        let provider = try ClaudeCodeProvider(configuration: ProviderConfiguration(kind: .claudeCode, apiKey: "", baseURL: nil),
                                              runtime: runtime)
        let consumer = Task {
            for try await _ in provider.stream(request) {}
        }
        #expect(await LLMTest.eventually(timeout: .seconds(10)) { !executor.calls.isEmpty })
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        _ = await consumer.result
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(await LLMTest.eventually { executor.cancellations == 1 })
        let pid = try #require(await runtime.currentProcessID())
        // The fake either was still streaming or had just finished the turn.
        #expect(await LLMTest.eventually { sandbox.records("events", of: pid).count == 1 })
        #expect(ClaudeCodeTest.isRunning(pid))
    }

    @Test(arguments: ["ignore_interrupt", "interrupt_error"])
    func aProcessThatDoesNotStopIsTerminated(scenario: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime(scenario, interruptTimeout: .milliseconds(500))
        defer { runtime.shutdown() }
        let elapsed = try await cancelDuring(runtime, ClaudeCodeTest.request([Self.user("x")], conversationID: UUID())) { events in
            events.contains { if case .textDelta = $0 { true } else { false } }
        }
        #expect(elapsed < .seconds(1))
        let pid = try #require(await runtime.currentProcessID())
        #expect(await LLMTest.eventually(timeout: .seconds(5)) { !ClaudeCodeTest.isRunning(pid) })
        #expect(await LLMTest.eventually { sandbox.workFiles().isEmpty })
    }

    // MARK: Shutdown and validation

    @Test func shutdownEndsTheProcessTheBridgeAndTheFiles() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runtime = sandbox.runtime("tool")
        let executor = StubToolExecutor()
        let request = ClaudeCodeTest.request([Self.user("Wert?")], conversationID: UUID(), tools: [ClaudeCodeTest.testTool],
                                             executor: executor)
        _ = try await ClaudeCodeTest.turn(runtime, request)
        let pid = try #require(await runtime.currentProcessID())
        let config = try JSONValue.parse(Data(contentsOf: sandbox.logs.appendingPathComponent("mcp-config-\(pid).json")))
        let url = try #require(config["mcpServers"]?["orbit"]?["url"]?.stringValue.flatMap(URL.init(string:)))
        let port = try #require(url.port.map(UInt16.init))
        #expect(!sandbox.workFiles().isEmpty)

        let started = ContinuousClock.now
        runtime.shutdown()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!ClaudeCodeTest.isRunning(pid))
        #expect(sandbox.workFiles().isEmpty)
        #expect(await LLMTest.eventually { (try? LoopbackHTTPServerTests.Client(port: port)) == nil })
        let after = try await ClaudeCodeTest.turn(runtime, request)
        #expect(after.llmError == .cancelled)
    }

    @Test func validationChecksInstallationAndLoginWithoutAChat() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        func provider(auth: String, locator: ClaudeCodeLocator = ClaudeCodeTest.locator()) throws -> ClaudeCodeProvider {
            let runtime = ClaudeCodeTest.runtime(scenario: "text", logs: sandbox.logs, workingDirectory: sandbox.work,
                                                 locator: locator, extra: ["FAKE_CLAUDE_AUTH": auth])
            return try ClaudeCodeProvider(configuration: ProviderConfiguration(kind: .claudeCode, apiKey: "", baseURL: nil),
                                          runtime: runtime)
        }
        try await provider(auth: "logged_in").validateConfiguration(model: "sonnet")
        await #expect(throws: LLMError.claudeCodeNotLoggedIn) {
            try await provider(auth: "logged_out").validateConfiguration(model: "sonnet")
        }
        await #expect(throws: LLMError.claudeCodeNotInstalled) {
            try await provider(auth: "logged_in", locator: ClaudeCodeTest.locator(nil)).validateConfiguration(model: "sonnet")
        }
        await #expect(throws: LLMError.modelNotFound(model: "")) {
            try await provider(auth: "logged_in").validateConfiguration(model: " ")
        }
        // No chat process was started.
        #expect(ClaudeCodeTest.records("stdin", in: sandbox.logs).isEmpty)
    }

    @Test func theProviderDescribesItself() throws {
        let runtime = ClaudeCodeRuntime(configuration: ClaudeCodeRuntime.Configuration(
            workingDirectory: URL(fileURLWithPath: "/nonexistent"), locator: ClaudeCodeTest.locator(nil), baseEnvironment: [:]))
        let provider = try ClaudeCodeProvider(configuration: ProviderConfiguration(
            kind: .claudeCode, apiKey: "", baseURL: nil, executablePath: " ~/bin/claude "), runtime: runtime)
        #expect(provider.kind == .claudeCode)
        #expect(provider.displayName == "Claude")
        #expect(provider.executesToolsInternally)
        #expect(provider.executablePath == NSHomeDirectory() + "/bin/claude")
        #expect(throws: LLMError.self) {
            try ClaudeCodeProvider(configuration: ProviderConfiguration(kind: .anthropic, apiKey: "", baseURL: nil),
                                   runtime: runtime)
        }
    }
}
