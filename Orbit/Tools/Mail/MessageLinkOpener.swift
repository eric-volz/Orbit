import AppKit

/// Opens a message in Mail through its `message://` link (mail cards). Live:
/// NSWorkspace on the main actor; restricted debug sessions cannot, the DEBUG
/// fake-data mode only records the link, and tests use a recorder.
protocol MessageLinkOpening: Sendable {
    /// Throws when no app opened the link.
    func open(_ url: URL) async throws
}

struct LiveMessageLinkOpener: MessageLinkOpening {
    func open(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                    continuation.resume(with: error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }
}

/// Opens nothing (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// services built for tests): Mail is never reached.
struct DisabledMessageLinkOpener: MessageLinkOpening {
    struct Disabled: Error {}

    func open(_ url: URL) async throws {
        throw Disabled()
    }
}
