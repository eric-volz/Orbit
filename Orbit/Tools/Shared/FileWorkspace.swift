import AppKit

/// Opening and revealing files, and whether an item is still there. Live:
/// NSWorkspace on the main actor, the file system off it; tests use a mock
/// that records calls.
protocol FileWorkspace: Sendable {
    /// Opens the item with its default app (a folder in Finder). Throws when no
    /// app can open it.
    func open(_ url: URL) async throws

    /// Shows the item selected in a Finder window.
    func reveal(_ url: URL) async

    /// Whether an item exists at `url`: a file card or search result may be
    /// older than a move or a deletion.
    func itemExists(at url: URL) async -> Bool
}

struct LiveFileWorkspace: FileWorkspace {
    func open(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func reveal(_ url: URL) async {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func itemExists(at url: URL) async -> Bool {
        let path = url.path
        return await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: path)
        }.value
    }
}
