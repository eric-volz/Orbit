import Foundation
import os
import Testing
@testable import Orbit

/// Helpers of the Claude Code tests (namespaced to avoid clashes in the test module).
enum ClaudeCodeTest {
    /// The fake `claude` script (OrbitTests/Fixtures/FakeClaude/claude).
    static let fakeCLI: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/FakeClaude/claude").path

    static let testTool = ToolDefinition(
        name: "get_test_value",
        description: "Returns the current test value.",
        inputSchema: ["type": "object", "properties": ["label": ["type": "string"]]]
    )

    /// A fresh directory (canonical path, as `pwd -P` reports it); remove it
    /// with `removeDirectory` when done.
    static func makeDirectory(_ name: String = "orbit-cc") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(decoding: UnsafeRawBufferPointer(start: resolved, count: strlen(resolved)),
                                           as: UTF8.self), isDirectory: true)
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A locator that only knows `executable` (no standard paths, no shell).
    static func locator(_ executable: String? = fakeCLI) -> ClaudeCodeLocator {
        ClaudeCodeLocator(candidates: executable.map { [$0] } ?? []) { nil }
    }

    /// A runtime that runs the fake CLI with `scenario`, recording into `logs`.
    static func runtime(scenario: String, logs: URL, workingDirectory: URL,
                        locator: ClaudeCodeLocator = locator(),
                        idleTimeout: Duration = .seconds(15 * 60),
                        interruptTimeout: Duration = .seconds(10),
                        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
                        extra: [String: String] = [:]) -> ClaudeCodeRuntime {
        var configuration = ClaudeCodeRuntime.Configuration(
            workingDirectory: workingDirectory,
            locator: locator,
            baseEnvironment: ProcessInfo.processInfo.environment,
            extraEnvironment: ["FAKE_CLAUDE_SCENARIO": scenario, "FAKE_CLAUDE_LOG_DIR": logs.path]
                .merging(extra) { _, new in new },
            idleTimeout: idleTimeout,
            interruptTimeout: interruptTimeout
        )
        if let sleep {
            configuration.sleep = sleep
        }
        return ClaudeCodeRuntime(configuration: configuration)
    }

    static func request(_ messages: [Message], conversationID: UUID, tools: [ToolDefinition] = [],
                        executor: (any ToolExecuting)? = nil, systemPrompt: String = "You are Orbit (test).",
                        model: String = "sonnet", effort: ReasoningEffort? = .low) -> LLMRequest {
        LLMRequest(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools, effort: effort,
                   conversationID: conversationID, toolExecutor: executor)
    }

    /// Runs one turn through a provider and collects everything it produced.
    static func turn(_ runtime: ClaudeCodeRuntime, _ request: LLMRequest,
                     executablePath: String? = nil) async throws -> LLMStreamResult {
        let provider = try ClaudeCodeProvider(
            configuration: ProviderConfiguration(kind: .claudeCode, apiKey: "", baseURL: nil, executablePath: executablePath),
            runtime: runtime
        )
        return await LLMTest.collect(provider.stream(request))
    }

    /// Files the fake CLI wrote with `prefix` (e.g. "stdin"), oldest first.
    static func records(_ prefix: String, in logs: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
        return names.filter { $0.hasPrefix(prefix + "-") }
            .map { logs.appendingPathComponent($0) }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first < second
            }
    }

    static func lines(of url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
    }

    /// The stdin messages the fake received from process `pid`.
    static func stdinMessages(of pid: pid_t, in logs: URL) -> [JSONValue] {
        lines(of: logs.appendingPathComponent("stdin-\(pid).jsonl")).compactMap { try? JSONValue.parse($0) }
    }

    /// Text blocks of a user message sent on stdin.
    static func textBlocks(_ message: JSONValue) -> [String] {
        (message["message"]?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

/// A `ToolExecuting` for tests: records calls and answers with a fixed result,
/// or waits until `release()` (or cancellation).
final class StubToolExecutor: ToolExecuting {
    private struct State: Sendable {
        var calls: [ToolCall] = []
        var cancellations = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    let result: String
    let isError: Bool
    let blocks: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(result: String = "The test value is PURPLE-42.", isError: Bool = false, blocks: Bool = false) {
        self.result = result
        self.isError = isError
        self.blocks = blocks
    }

    var calls: [ToolCall] { state.withLock { $0.calls } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func execute(_ call: ToolCall) async -> ToolResultBlock {
        state.withLock { $0.calls.append(call) }
        if blocks {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.released || Task.isCancelled { return true }
                        state.waiters.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    state.cancellations += 1
                    defer { state.waiters = [] }
                    return state.waiters
                }
                waiters.forEach { $0.resume() }
            }
            if Task.isCancelled {
                return ToolResultBlock(toolCallID: call.id, content: "cancelled", isError: true)
            }
        }
        return ToolResultBlock(toolCallID: call.id, content: result, isError: isError)
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A sleep function under test control: sleepers wait until `advance()`.
final class ManualSleeper: Sendable {
    private struct Sleeper: Sendable {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private let state = OSAllocatedUnfairLock(initialState: [Sleeper]())

    var sleeperCount: Int { state.withLock { $0.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { $0.append(Sleeper(id: id, continuation: continuation)) }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Wakes every current sleeper.
    func advance() {
        let sleepers = state.withLock { sleepers -> [Sleeper] in
            defer { sleepers = [] }
            return sleepers
        }
        sleepers.forEach { $0.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        let sleeper = state.withLock { sleepers -> Sleeper? in
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return sleepers.remove(at: index)
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}
