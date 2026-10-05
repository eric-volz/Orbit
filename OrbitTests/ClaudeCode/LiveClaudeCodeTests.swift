import Foundation
import Testing
@testable import Orbit

/// Runs the real, locally installed Claude Code on the signed-in subscription.
/// Uses the subscription's usage (five short Haiku requests), so it only runs
/// when asked for:
///
///     ORBIT_CLAUDE_CODE_LIVE=1 Scripts/swiftpm.sh test --filter LiveClaudeCode
///
/// Only harmless test prompts and a test tool are used; nothing personal is read.
@Suite("LiveClaudeCode", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ORBIT_CLAUDE_CODE_LIVE"] == "1"))
struct LiveClaudeCodeTests {
    static let model = ProcessInfo.processInfo.environment["ORBIT_LIVE_MODEL"] ?? "haiku"
    static let systemPrompt = "You are Orbit's test assistant. Answer in one short sentence, in German."

    private func makeRuntime(_ directory: URL) -> ClaudeCodeRuntime {
        ClaudeCodeRuntime(configuration: ClaudeCodeRuntime.Configuration(
            workingDirectory: directory,
            locator: .standard(),
            baseEnvironment: ProcessInfo.processInfo.environment
        ))
    }

    private func request(_ messages: [Message], conversation: UUID, tools: [ToolDefinition] = [],
                         executor: (any ToolExecuting)? = nil) -> LLMRequest {
        ClaudeCodeTest.request(messages, conversationID: conversation, tools: tools, executor: executor,
                               systemPrompt: Self.systemPrompt, model: Self.model, effort: nil)
    }

    private static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(text)])
    }

    private static func projectDirectories() -> Set<String> {
        let root = NSHomeDirectory() + "/.claude/projects"
        return Set((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
    }

    @Test func chatsRemembersCancelsAndRestarts() async throws {
        let directory = try ClaudeCodeTest.makeDirectory("orbit-cc-live")
        defer { ClaudeCodeTest.removeDirectory(directory) }
        let projectsBefore = Self.projectDirectories()
        let runtime = makeRuntime(directory)
        defer { runtime.shutdown() }
        let executable = try #require(await runtime.locateExecutable(configuredPath: nil))
        print("live: using \(ClaudeCodeLocator.isBundledWithClaudeApp(executable) ? "the Claude app's copy" : executable)")
        try await runtime.validateInstallation(executablePath: nil)

        // 1. Streaming text, isolated CLI.
        let conversation = UUID()
        var messages = [Self.user("Antworte exakt mit: Hallo Orbit")]
        let first = try await ClaudeCodeTest.turn(runtime, request(messages, conversation: conversation))
        #expect(first.error == nil, "\(String(describing: first.error))")
        #expect(first.text.contains("Hallo Orbit"))
        #expect(first.textDeltas.count >= 1)
        let info = try #require(await runtime.currentInitInfo())
        print("live: init model=\(info.model ?? "?") version=\(info.version ?? "?") tools=\(info.tools) mcp=\(info.mcpServers) skills=\(info.skills.count) commands=\(info.slashCommands.count) agents=\(info.agents) memory=\(info.hasMemoryPaths)")
        #expect(info.tools.isEmpty)
        #expect(info.skills.isEmpty)
        #expect(info.slashCommands.isEmpty)
        #expect(!info.hasMemoryPaths)
        let pid = try #require(await runtime.currentProcessID())
        let rateLimits = first.events.compactMap { if case .rateLimit(let info) = $0 { info } else { nil } }
        print("live: rate limit events: \(rateLimits.map { "\($0.status) \($0.window ?? "?") \($0.utilization.map { String($0) } ?? "?")" })")

        // 2. The same process remembers the first turn.
        messages.append(Message(role: .assistant, content: [.text(first.text)]))
        messages.append(Self.user("Welches Wort kam in deiner letzten Antwort nach „Hallo“? Nur das Wort."))
        let second = try await ClaudeCodeTest.turn(runtime, request(messages, conversation: conversation))
        #expect(second.error == nil)
        #expect(second.text.contains("Orbit"))
        #expect(await runtime.currentProcessID() == pid, "the process is reused")

        // 3. Stopping mid-answer returns at once.
        let long = request([Self.user("Zähle von 1 bis 300, jede Zahl in einer eigenen Zeile, ohne weiteren Text.")],
                           conversation: UUID())
        let provider = try ClaudeCodeProvider(configuration: ProviderConfiguration(kind: .claudeCode, apiKey: "", baseURL: nil),
                                              runtime: runtime)
        let consumer = Task { () -> Duration? in
            var cancelledAt: ContinuousClock.Instant?
            do {
                for try await event in provider.stream(long) {
                    if cancelledAt == nil, case .textDelta = event {
                        cancelledAt = .now
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            } catch {}
            return cancelledAt.map { ContinuousClock.now - $0 }
        }
        let stopTime = try #require(await consumer.value)
        print("live: stopped after \(stopTime)")
        #expect(stopTime < .seconds(1))

        // 4. A new process gets the earlier conversation as a transcript.
        let restarted = makeRuntime(directory)
        defer { restarted.shutdown() }
        let history = [
            Self.user("Merke dir: Mein Lieblingswort ist Kumquat."),
            Message(role: .assistant, content: [.text("Alles klar, dein Lieblingswort ist Kumquat.")]),
            Self.user("Wie lautet mein Lieblingswort? Nur das Wort."),
        ]
        let fifth = try await ClaudeCodeTest.turn(restarted, request(history, conversation: UUID()))
        #expect(fifth.error == nil)
        #expect(fifth.text.localizedCaseInsensitiveContains("Kumquat"))

        // Nothing persisted in Claude Code's session store.
        runtime.shutdown()
        restarted.shutdown()
        #expect(Self.projectDirectories() == projectsBefore)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
    }

    @Test func runsAToolThroughTheBridge() async throws {
        let directory = try ClaudeCodeTest.makeDirectory("orbit-cc-live")
        defer { ClaudeCodeTest.removeDirectory(directory) }
        let runtime = makeRuntime(directory)
        defer { runtime.shutdown() }
        let executor = StubToolExecutor(result: "The test value is PURPLE-42.")
        let toolConversation = UUID()
        let toolRequest = request([Self.user("Rufe jetzt das Werkzeug get_test_value mit label \"test\" auf und nenne mir den Wert, den es liefert.")],
                                  conversation: toolConversation, tools: [ClaudeCodeTest.testTool], executor: executor)
        let third = try await ClaudeCodeTest.turn(runtime, toolRequest)
        #expect(third.error == nil, "\(String(describing: third.error))")
        #expect(executor.calls.count == 1)
        #expect(executor.calls.first?.name == "get_test_value")
        #expect(third.text.contains("PURPLE-42"))
        // The bridge sees the same id the stream announced (orders text and calls).
        let announced = third.startedToolCalls
        print("live: announced \(announced), executed \(executor.calls.map(\.id))")
        #expect(announced == executor.calls.map { "\($0.id)/get_test_value" })
        let toolInfo = try #require(await runtime.currentInitInfo())
        #expect(toolInfo.tools == ["mcp__orbit__get_test_value"])
        #expect(toolInfo.mcpServers["orbit"] == "connected")

    }
}
