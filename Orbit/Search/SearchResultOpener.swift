import AppKit

/// Opens instant-search results. Live: NSWorkspace on the main actor; tests
/// use a mock that records calls.
protocol SearchResultOpening: Sendable {
    /// Launches the app, or brings it to the front when it runs.
    func openApplication(at url: URL) async throws

    /// Opens a file or folder with its default app, or a URL such as
    /// `addressbook://…` in the app that handles it.
    func open(_ url: URL) async throws
}

struct LiveSearchResultOpener: SearchResultOpening {
    func openApplication(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    continuation.resume(with: error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }

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
