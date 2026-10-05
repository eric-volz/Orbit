import Foundation

/// Runs short Claude Code commands (`--version`, `auth status`, `auth login`)
/// and the login-shell lookup: collects stdout, enforces a timeout and
/// terminates the process when the calling task is cancelled.
enum ClaudeCodeCommand {
    struct Output: Sendable, Hashable {
        var exit: ClaudeCodeProcess.Exit
        /// stdout (capped at `maxOutputBytes`). May contain account details:
        /// never log it.
        var stdout: String
    }

    enum Failure: Error, Sendable, Hashable {
        case timedOut
    }

    static let maxOutputBytes = 1024 * 1024

    /// Runs `launch` to completion. stdin is closed right away unless
    /// `keepsStdinOpen` (commands that read from it, like `auth login`, wait).
    /// With `resources` the process is ended by their `shutdown()` (app
    /// termination); after it, the command is cancelled.
    static func run(_ launch: ClaudeCodeProcess.Launch, timeout: Duration, keepsStdinOpen: Bool = false,
                    resources: ClaudeCodeResources? = nil) async throws -> Output {
        let process = try ClaudeCodeProcess.launch(launch)
        if let resources {
            guard resources.register(process) else {
                process.terminate(gracePeriod: 0.5)
                throw CancellationError()
            }
        }
        defer { resources?.unregister(process) }
        if !keepsStdinOpen {
            process.closeStdin()
        }
        let output = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Output?.self) { group in
                group.addTask {
                    var collected = ""
                    for await line in process.lines where collected.utf8.count < maxOutputBytes {
                        collected += line + "\n"
                    }
                    return Output(exit: await process.waitForExit(), stdout: collected)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next() ?? nil
                if first == nil {
                    process.terminate(gracePeriod: 1)
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            process.terminate(gracePeriod: 1)
        }
        try Task.checkCancellation()
        guard let output else { throw Failure.timedOut }
        return output
    }
}
