import Foundation

/// Connects a tool call waiting for the user's decision with the confirmation
/// card that makes it.
///
/// The agent loop awaits `request(_:)`; the UI's decision arrives through
/// `resolve(_:decision:)`. Every continuation is resumed exactly once: by the
/// decision, by `cancelAll()`, or with `.cancelled` when the waiting task is
/// cancelled.
@MainActor
final class ConfirmationBroker {
    private var waiting: [UUID: CheckedContinuation<ConfirmationDecision, Never>] = [:]

    /// Ids of the requests currently waiting for a decision.
    var pendingRequestIDs: Set<UUID> { Set(waiting.keys) }

    /// Suspends until the user decides about `request`.
    func request(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                // A duplicate id would orphan the earlier waiter; end it first.
                waiting.updateValue(continuation, forKey: id)?.resume(returning: .cancelled)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(id, decision: .cancelled)
            }
        }
    }

    /// Delivers the user's decision. Returns false when nothing waits for `id`
    /// (already decided, cancelled or unknown).
    @discardableResult
    func resolve(_ id: UUID, decision: ConfirmationDecision) -> Bool {
        guard let continuation = waiting.removeValue(forKey: id) else { return false }
        continuation.resume(returning: decision)
        return true
    }

    /// Ends all waiting requests with `.cancelled` (stop, new chat).
    func cancelAll() {
        let continuations = waiting.values
        waiting.removeAll()
        for continuation in continuations {
            continuation.resume(returning: .cancelled)
        }
    }
}
