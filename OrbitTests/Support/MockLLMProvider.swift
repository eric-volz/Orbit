import Foundation
import os
@testable import Orbit

/// A one-shot signal between a test and asynchronous code: `wait()` suspends
/// until `open()` was called (or the waiting task is cancelled).
final class AsyncGate: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isOpen: Bool { state.withLock { $0.isOpen } }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns once the gate is open or the current task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.isOpen || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// Like `wait()`, but deaf to cancellation (simulates a stuck operation).
    func waitIgnoringCancellation() async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.isOpen { return true }
                state.waiters[id] = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// A scripted `LLMProvider`. Every `stream(_:)` call records the request and
/// plays the next script: events, delays, gates, or a thrown error.
final class MockLLMProvider: LLMProvider {
    enum Step: Sendable {
        case event(LLMEvent)
        case delay(Duration)
        /// Opens the gate: tells the test the stream got here.
        case signal(AsyncGate)
        /// Waits until the test opens the gate.
        case wait(AsyncGate)
        /// Throws (ends the stream with an error).
        case fail(any Error)
        /// Runs the calls through `request.toolExecutor` at the same time and
        /// waits for their results, as Claude Code does (provider-managed mode).
        case callTools([ToolCall])
    }

    private struct State: Sendable {
        var scripts: [[Step]]
        var requests: [LLMRequest] = []
        var executorResults: [ToolResultBlock] = []
    }

    let kind: ProviderKind
    let displayName: String
    let executesToolsInternally: Bool
    private let state: OSAllocatedUnfairLock<State>

    init(kind: ProviderKind = .anthropic, displayName: String = "Claude", scripts: [[Step]] = [],
         executesToolsInternally: Bool = false) {
        self.kind = kind
        self.displayName = displayName
        self.executesToolsInternally = executesToolsInternally
        state = OSAllocatedUnfairLock(initialState: State(scripts: scripts))
    }

    /// Every request received so far, in order.
    var requests: [LLMRequest] { state.withLock { $0.requests } }

    /// What `request.toolExecutor` returned for `.callTools` steps, in completion order.
    var executorResults: [ToolResultBlock] { state.withLock { $0.executorResults } }

    var remainingScripts: Int { state.withLock { $0.scripts.count } }

    func enqueue(_ steps: [Step]) {
        state.withLock { $0.scripts.append(steps) }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let script = state.withLock { state -> [Step]? in
            state.requests.append(request)
            return state.scripts.isEmpty ? nil : state.scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish(throwing: LLMError.invalidResponse(detail: "MockLLMProvider has no script left"))
                return
            }
            let task = Task {
                do {
                    for step in script {
                        try Task.checkCancellation()
                        switch step {
                        case .event(let event): continuation.yield(event)
                        case .delay(let duration): try await Task.sleep(for: duration)
                        case .signal(let gate): gate.open()
                        case .wait(let gate): await gate.wait()
                        case .fail(let error): throw error
                        case .callTools(let calls):
                            guard let executor = request.toolExecutor else {
                                throw LLMError.invalidResponse(detail: "MockLLMProvider: the request has no tool executor")
                            }
                            await withTaskGroup(of: Void.self) { group in
                                for call in calls {
                                    group.addTask {
                                        let result = await executor.execute(call)
                                        self.state.withLock { $0.executorResults.append(result) }
                                    }
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func validateConfiguration(model: String) async throws {}
}

// MARK: - Script building

extension MockLLMProvider.Step {
    static func text(_ delta: String) -> Self { .event(.textDelta(delta)) }

    static func end(_ content: [ContentBlock], stopReason: StopReason = .endTurn, model: String = "mock-model") -> Self {
        .event(.end(AssistantTurn(content: content, stopReason: stopReason, model: model)))
    }
}

/// Common scripts.
enum MockScript {
    /// A provider-managed run (Claude Code): optional text, the tool calls run
    /// through the executor, then the final answer. `.end` carries all text.
    static func managedRun(_ calls: [ToolCall], before: String? = nil, answer: String) -> [MockLLMProvider.Step] {
        var steps: [MockLLMProvider.Step] = []
        var content: [ContentBlock] = []
        if let before {
            steps += chunks(of: before).map(MockLLMProvider.Step.text)
            content.append(.text(before))
        }
        steps += calls.map { .event(.toolCallStarted(id: $0.id, name: $0.name)) }
        steps.append(.callTools(calls))
        steps += chunks(of: answer).map(MockLLMProvider.Step.text)
        content.append(.text(answer))
        steps.append(.end(content))
        return steps
    }

    /// Streams `text` in a few chunks, then ends the turn with it.
    static func answer(_ text: String, thinking: String? = nil) -> [MockLLMProvider.Step] {
        var steps = chunks(of: text).map(MockLLMProvider.Step.text)
        var content: [ContentBlock] = []
        if let thinking {
            content.append(.thinking(text: thinking, signature: "sig-\(thinking.count)"))
        }
        content.append(.text(text))
        steps.append(.end(content))
        return steps
    }

    /// A turn asking for tools, optionally with text before the calls.
    static func toolCalls(_ calls: [ToolCall], text: String? = nil, thinking: String? = nil,
                          stopReason: StopReason = .toolUse) -> [MockLLMProvider.Step] {
        var steps: [MockLLMProvider.Step] = []
        var content: [ContentBlock] = []
        if let thinking {
            content.append(.thinking(text: thinking, signature: "sig-\(thinking.count)"))
        }
        if let text {
            steps += chunks(of: text).map(MockLLMProvider.Step.text)
            content.append(.text(text))
        }
        for call in calls {
            steps.append(.event(.toolCallStarted(id: call.id, name: call.name)))
            steps.append(.event(.toolCall(call)))
            content.append(.toolUse(call))
        }
        steps.append(.end(content, stopReason: stopReason))
        return steps
    }

    static func call(_ id: String, _ name: String, _ input: JSONValue = [:]) -> ToolCall {
        ToolCall(id: id, name: name, input: input, rawInput: input.jsonString())
    }

    private static func chunks(of text: String) -> [String] {
        let characters = Array(text)
        let size = max(1, characters.count / 3)
        return stride(from: 0, to: characters.count, by: size).map { start in
            String(characters[start..<min(start + size, characters.count)])
        }
    }
}
