import Foundation
import Testing
@testable import Orbit

@Suite("ConfirmationBroker")
@MainActor
struct ConfirmationBrokerTests {
    func makeRequest() -> ConfirmationRequest {
        ConfirmationRequest(toolCallID: "c1", toolName: "create_note", riskLevel: .write, title: "Notiz", message: "Anlegen?")
    }

    @Test func deliversTheDecision() async {
        let broker = ConfirmationBroker()
        let request = makeRequest()
        let waiter = Task { await broker.request(request) }
        #expect(await AgentHarness.eventually { broker.pendingRequestIDs == [request.id] })
        #expect(broker.resolve(request.id, decision: .approved(edits: ["title": "Neu"])))
        #expect(await waiter.value == .approved(edits: ["title": "Neu"]))
        #expect(broker.pendingRequestIDs.isEmpty)
    }

    @Test func resolvesOnlyOnce() async {
        let broker = ConfirmationBroker()
        let request = makeRequest()
        let waiter = Task { await broker.request(request) }
        #expect(await AgentHarness.eventually { !broker.pendingRequestIDs.isEmpty })
        #expect(broker.resolve(request.id, decision: .cancelled))
        #expect(!broker.resolve(request.id, decision: .approved(edits: [:])))
        #expect(!broker.resolve(UUID(), decision: .cancelled))
        #expect(await waiter.value == .cancelled)
    }

    @Test func cancelAllEndsEveryWaiter() async {
        let broker = ConfirmationBroker()
        let first = makeRequest()
        let second = makeRequest()
        let waiters = [Task { await broker.request(first) }, Task { await broker.request(second) }]
        #expect(await AgentHarness.eventually { broker.pendingRequestIDs.count == 2 })
        broker.cancelAll()
        for waiter in waiters {
            #expect(await waiter.value == .cancelled)
        }
        #expect(broker.pendingRequestIDs.isEmpty)
    }

    @Test func taskCancellationEndsTheWait() async {
        let broker = ConfirmationBroker()
        let request = makeRequest()
        let waiter = Task { await broker.request(request) }
        #expect(await AgentHarness.eventually { !broker.pendingRequestIDs.isEmpty })
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        #expect(await AgentHarness.eventually { broker.pendingRequestIDs.isEmpty })
        #expect(!broker.resolve(request.id, decision: .approved(edits: [:])))
    }

    @Test func alreadyCancelledTasksDoNotWait() async {
        let broker = ConfirmationBroker()
        let request = makeRequest()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await broker.request(request)
        }
        #expect(await waiter.value == .cancelled)
        #expect(await AgentHarness.eventually { broker.pendingRequestIDs.isEmpty })
    }

    @Test func duplicateIDsDoNotOrphanAWaiter() async {
        let broker = ConfirmationBroker()
        let request = makeRequest()
        let first = Task { await broker.request(request) }
        #expect(await AgentHarness.eventually { !broker.pendingRequestIDs.isEmpty })
        let second = Task { await broker.request(request) }
        #expect(await first.value == .cancelled)
        broker.resolve(request.id, decision: .approved(edits: [:]))
        #expect(await second.value == .approved(edits: [:]))
    }
}

@Suite("AgentLoop.runWithDeadline")
struct DeadlineTests {
    /// How soon a deadline or a cancellation must return the call. The operations below never end on their own
    /// (or take 30 s), so waiting for them shows as a far longer wait; the bound leaves room for a busy machine
    /// (a full run with 12 extra busy threads once stalled a 100 ms deadline for 2.05 s).
    static let promptly: Duration = .seconds(5)

    @Test func returnsTheResultInTime() async throws {
        let value = try await AgentLoop.runWithDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func passesErrorsThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await AgentLoop.runWithDeadline(.seconds(5)) { () async throws -> Int in throw Boom() }
        }
    }

    @Test func timesOutEvenWhenTheOperationIgnoresCancellation() async {
        let gate = AsyncGate()
        defer { gate.open() }
        let start = ContinuousClock.now
        await #expect(throws: ToolError.timedOut) {
            try await AgentLoop.runWithDeadline(.milliseconds(100)) { await gate.waitIgnoringCancellation() }
        }
        // The operation only ends when the gate opens, after this: the call returned without waiting for it.
        #expect(ContinuousClock.now - start < Self.promptly)
    }

    @Test func cancellationReturnsPromptly() async {
        let gate = AsyncGate()
        defer { gate.open() }
        let task = Task {
            try await AgentLoop.runWithDeadline(.seconds(30)) { await gate.waitIgnoringCancellation() }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < Self.promptly)
    }

    @Test func cancelsTheOperationOnTimeout() async {
        let cancelled = AsyncGate()
        await #expect(throws: ToolError.timedOut) {
            try await AgentLoop.runWithDeadline(.milliseconds(50)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.open()
                }
            }
        }
        await cancelled.wait()
        #expect(cancelled.isOpen)
    }
}
