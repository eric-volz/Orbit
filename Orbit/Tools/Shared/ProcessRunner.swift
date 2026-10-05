import Foundation

/// Runs a command to completion; the Shortcuts tools run `/usr/bin/shortcuts`
/// through it. Live: `ChildProcess.run` (own process group, stdin from
/// /dev/null, timeout and cancellation stop the whole group, output limit).
/// Tests pass a mock that records the command lines, so no command runs.
protocol ProcessRunning: Sendable {
    /// Runs `launch` and returns what it wrote. Throws
    /// `ChildProcess.RunFailure.timedOut` after `timeout`, `CancellationError`
    /// when the calling task is cancelled (the process group is stopped in
    /// both cases) and `ChildProcess.Failure` when it cannot start.
    func run(_ launch: ChildProcess.Launch, timeout: Duration, outputLimit: Int) async throws -> ChildProcess.Output
}

struct LiveProcessRunner: ProcessRunning {
    func run(_ launch: ChildProcess.Launch, timeout: Duration, outputLimit: Int) async throws -> ChildProcess.Output {
        try await ChildProcess.run(launch, timeout: timeout, outputLimit: outputLimit)
    }
}

/// The environment a helper command gets from Orbit's: a fixed PATH and the
/// variables that locate the user and their language, nothing else (no
/// tokens, no debug variables).
enum ChildEnvironment {
    static let passed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"]

    static func minimal(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in passed {
            if let value = environment[name] { result[name] = value }
        }
        return result
    }
}
