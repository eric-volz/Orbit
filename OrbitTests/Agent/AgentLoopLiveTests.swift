import Foundation
import os
import Testing
@testable import Orbit

/// End-to-end tests of the agent loop against the local Ollama model through
/// Orbit's real providers, on both of Ollama's APIs. Opt-in:
///
///     ORBIT_LIVE_TESTS=1 Scripts/swiftpm.sh test --filter AgentLoopLiveTests
///
/// `ORBIT_LIVE_MODEL` overrides the model (default `gpt-oss:20b`).
@Suite("AgentLoop: live (Ollama)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ORBIT_LIVE_TESTS"] == "1"))
@MainActor
struct AgentLoopLiveTests {
    enum Endpoint: String, CaseIterable, Sendable {
        /// Anthropic Messages API at http://127.0.0.1:11434.
        case anthropic
        /// Chat Completions at http://127.0.0.1:11434/v1.
        case openAICompatible
    }

    nonisolated static let model = ProcessInfo.processInfo.environment["ORBIT_LIVE_MODEL"] ?? "gpt-oss:20b"
    static let timeout: Duration = .seconds(240)

    func makeHarness(_ endpoint: Endpoint, tools: [any Tool] = []) throws -> (AgentHarness, RecordingProvider) {
        let configuration = switch endpoint {
        case .anthropic:
            ProviderConfiguration(kind: .anthropic, apiKey: "ollama", baseURL: URL(string: "http://127.0.0.1:11434"))
        case .openAICompatible:
            ProviderConfiguration(kind: .openAICompatible, apiKey: "", baseURL: URL(string: "http://127.0.0.1:11434/v1"))
        }
        let provider = RecordingProvider(base: try LLMProviderFactory.live(claudeCodeRuntime: ClaudeCodeRuntime()).make(configuration))
        let harness = AgentHarness(tools: tools, serving: provider)
        harness.settings.providerKind = configuration.kind
        switch endpoint {
        case .anthropic:
            harness.settings.anthropicModel = Self.model
            harness.settings.anthropicBaseURL = configuration.baseURL?.absoluteString ?? ""
        case .openAICompatible:
            harness.settings.openAIModel = Self.model
            harness.settings.openAIBaseURL = configuration.baseURL?.absoluteString ?? ""
        }
        return (harness, provider)
    }

    func waitForIdle(_ harness: AgentHarness) async {
        #expect(await AgentHarness.eventually(timeout: Self.timeout) { !harness.agent.isRunning })
    }

    func expectCleanRun(_ harness: AgentHarness, _ provider: RecordingProvider,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(harness.notices.filter { $0.style == .error } == [], sourceLocation: sourceLocation)
        #expect(HistoryCheck.problems(in: harness.messages) == [], sourceLocation: sourceLocation)
        let requests = provider.requests
        for (earlier, later) in zip(requests, requests.dropFirst()) {
            #expect(HistoryCheck.isAppendOnly(earlier.messages, later.messages), sourceLocation: sourceLocation)
            #expect(earlier.systemPrompt == later.systemPrompt, sourceLocation: sourceLocation)
            #expect(earlier.tools == later.tools, sourceLocation: sourceLocation)
        }
        #expect(!harness.agent.items.contains { item in
            if case .assistant(_, true) = item.kind { return true }
            return false
        }, sourceLocation: sourceLocation)
    }

    @Test(arguments: Endpoint.allCases)
    func streamsAnAnswerAndEchoesTheTurnUnchanged(endpoint: Endpoint) async throws {
        let (harness, provider) = try makeHarness(endpoint)
        harness.agent.send("Antworte nur mit einem kurzen Satz: Wie heißt die Hauptstadt von Frankreich?")
        await waitForIdle(harness)
        expectCleanRun(harness, provider)
        let answer = try #require(harness.assistantTexts.last)
        print("LIVE[\(endpoint)] answer 1: \(answer)")
        #expect(answer.localizedCaseInsensitiveContains("Paris"))
        #expect(provider.textDeltaCount > 1, "the answer arrived in several deltas")

        // The follow-up sends the first turn (including its reasoning) back unchanged.
        harness.agent.send("Und von Italien? Wieder nur ein kurzer Satz.")
        await waitForIdle(harness)
        expectCleanRun(harness, provider)
        print("LIVE[\(endpoint)] answer 2: \(harness.assistantTexts.last ?? "-")")
        #expect(harness.assistantTexts.last?.localizedCaseInsensitiveContains("Rom") == true)
        #expect(provider.requests.last?.messages[1] == harness.messages[1])
        print("LIVE[\(endpoint)] first turn blocks: \(harness.messages[1].content.map(Self.blockKind)), provider: \(harness.agent.providerDisplayName)")
    }

    @Test(arguments: Endpoint.allCases)
    func runsAToolAndAnswersFromItsResult(endpoint: Endpoint) async throws {
        let log = MockToolLog()
        let (harness, provider) = try makeHarness(endpoint, tools: [MockSearchFilesTool(log: log)])
        harness.agent.send("Finde meine Rechnungen als PDF. Nutze dafür search_files und nenne mir danach die Dateinamen.")
        await waitForIdle(harness)
        expectCleanRun(harness, provider)
        print("LIVE[\(endpoint)] tool calls: \(log.entries.map { "\($0.tool) \($0.arguments.values)" })")
        #expect(!log.entries.isEmpty)
        #expect(harness.statuses.allSatisfy { $0.state == .succeeded })
        #expect(harness.cards.contains(.files(MockSearchFilesTool.files)))
        #expect(harness.disclosures.last?.contains { $0.kind == .fileNames } == true)
        // Models like to write "Rechnung‑März" with a non-breaking hyphen, so match the months.
        let answer = try #require(harness.assistantTexts.last)
        print("LIVE[\(endpoint)] answer: \(answer)")
        #expect(answer.contains("März") && answer.contains("April"))
    }

    @Test(arguments: Endpoint.allCases)
    func asksForConfirmationAndRunsTheEditedAction(endpoint: Endpoint) async throws {
        let log = MockToolLog()
        let (harness, provider) = try makeHarness(endpoint, tools: [MockCreateNoteTool(log: log)])
        harness.agent.send("Lege eine Notiz mit dem Titel „Test“ und dem Text „Hallo Welt“ an.")
        #expect(await AgentHarness.eventually(timeout: Self.timeout) {
            harness.agent.pendingConfirmation != nil || !harness.agent.isRunning
        })
        let request = try #require(harness.agent.pendingConfirmation)
        print("LIVE[\(endpoint)] confirmation fields: \(request.fields.map { "\($0.id)=\($0.value)" })")
        #expect(log.entries.isEmpty)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": "Orbit-Test"]))
        await waitForIdle(harness)
        expectCleanRun(harness, provider)
        print("LIVE[\(endpoint)] answer: \(harness.assistantTexts.last ?? "-")")
        #expect(log.arguments(of: "create_note").map { $0.optionalString("title") } == ["Orbit-Test"])
        #expect(harness.confirmations.map(\.status) == [.approved])
    }

    @Test(arguments: Endpoint.allCases)
    func aDeclinedActionIsNotRetried(endpoint: Endpoint) async throws {
        let log = MockToolLog()
        let (harness, provider) = try makeHarness(endpoint, tools: [MockCreateNoteTool(log: log)])
        harness.agent.send("Lege eine Notiz „Einkauf“ mit dem Text „Milch“ an.")
        #expect(await AgentHarness.eventually(timeout: Self.timeout) {
            harness.agent.pendingConfirmation != nil || !harness.agent.isRunning
        })
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .cancelled)
        await waitForIdle(harness)
        expectCleanRun(harness, provider)
        print("LIVE[\(endpoint)] answer after decline: \(harness.assistantTexts.last ?? "-")")
        #expect(log.entries.isEmpty)
        #expect(harness.confirmations.count == 1, "the model must not ask again on its own")
    }

    @Test(arguments: Endpoint.allCases)
    func stopWhileStreamingKeepsAValidHistory(endpoint: Endpoint) async throws {
        let (harness, provider) = try makeHarness(endpoint)
        harness.agent.send("Zähle langsam von 1 bis 40, jede Zahl in einer eigenen Zeile.")
        #expect(await AgentHarness.eventually(timeout: Self.timeout) {
            !(harness.assistantTexts.last ?? "").isEmpty || !harness.agent.isRunning
        })
        harness.agent.cancel()
        #expect(!harness.agent.isRunning)
        #expect(HistoryCheck.problems(in: harness.messages) == [])
        harness.agent.send("Danke, das reicht. Antworte nur mit: OK")
        await waitForIdle(harness)
        expectCleanRun(harness, provider)
        print("LIVE[\(endpoint)] answer after stop: \(harness.assistantTexts.last ?? "-")")
        #expect(harness.messages.last?.role == .assistant)
    }

    nonisolated static func blockKind(_ block: ContentBlock) -> String {
        switch block {
        case .text: "text"
        case .thinking(_, let signature): signature == nil ? "thinking(unsigned)" : "thinking"
        case .redactedThinking: "redacted_thinking"
        case .toolUse(let call): "tool_use(\(call.name))"
        case .toolResult: "tool_result"
        case .opaque: "opaque"
        }
    }
}

/// Forwards to a real provider and records the requests and text deltas.
final class RecordingProvider: LLMProvider {
    let base: any LLMProvider
    private let state = OSAllocatedUnfairLock(initialState: (requests: [LLMRequest](), textDeltas: 0))

    init(base: any LLMProvider) {
        self.base = base
    }

    var kind: ProviderKind { base.kind }
    var displayName: String { base.displayName }
    var requests: [LLMRequest] { state.withLock { $0.requests } }
    var textDeltaCount: Int { state.withLock { $0.textDeltas } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        state.withLock { $0.requests.append(request) }
        let upstream = base.stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .textDelta = event {
                            self.state.withLock { $0.textDeltas += 1 }
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func validateConfiguration(model: String) async throws {
        try await base.validateConfiguration(model: model)
    }
}
