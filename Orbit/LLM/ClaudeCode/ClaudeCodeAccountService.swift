import Foundation
import os

/// Status and sign-in of the locally installed Claude Code CLI.
///
/// Status comes from `claude --version` and `claude auth status --json`, of
/// which only `loggedIn`, `authMethod` and `subscriptionType` are read; the
/// account's e-mail and organization are never read, stored or logged. Sign-in
/// runs `claude auth login`, Anthropic's own browser flow; Orbit never sees a
/// credential. `shutdown()` (from `applicationWillTerminate`) ends a sign-in
/// that still runs, so the CLI and its local sign-in listener do not outlive Orbit.
final class ClaudeCodeAccountService: ClaudeCodeAccountServicing {
    /// How long the browser sign-in may take.
    static let signInTimeout: Duration = .seconds(10 * 60)

    private let executablePath: @Sendable () async -> String?
    private let locator: ClaudeCodeLocator
    private let baseEnvironment: [String: String]
    private let extraEnvironment: [String: String]
    private let signInTimeout: Duration
    /// A running sign-in; concurrent callers share it (one browser flow),
    /// from Settings, the onboarding and the chat's notice alike.
    private let signInTask = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)
    /// The running `claude auth login`, for `shutdown()`.
    private let resources = ClaudeCodeResources()

    /// `executablePath` returns the path set in the settings, or nil to auto-detect.
    convenience init(executablePath: @escaping @Sendable () async -> String?) {
        self.init(executablePath: executablePath, locator: .standard(),
                  baseEnvironment: ProcessInfo.processInfo.environment)
    }

    init(executablePath: @escaping @Sendable () async -> String?, locator: ClaudeCodeLocator,
         baseEnvironment: [String: String], extraEnvironment: [String: String] = [:],
         signInTimeout: Duration = ClaudeCodeAccountService.signInTimeout) {
        self.executablePath = executablePath
        self.locator = locator
        self.baseEnvironment = baseEnvironment
        self.extraEnvironment = extraEnvironment
        self.signInTimeout = signInTimeout
    }

    func status() async -> ClaudeCodeStatus {
        guard let executable = await locator.locate(configuredPath: await executablePath()) else {
            return ClaudeCodeStatus(availability: .notInstalled)
        }
        let environment = environment(for: executable)
        let version = await ClaudeCodeCLI.version(executable: executable, environment: environment)
        do {
            let auth = try await ClaudeCodeCLI.authStatus(executable: executable, environment: environment)
            return ClaudeCodeStatus(availability: auth.loggedIn ? .ready : .notLoggedIn, executablePath: executable,
                                    version: version, subscriptionType: auth.subscriptionType, authMethod: auth.authMethod)
        } catch {
            let name = (error as? LLMError).map(ProviderHTTP.logName(of:)) ?? String(describing: type(of: error))
            Log.llm.error("claude-code: auth status failed with \(name, privacy: .public)")
            return ClaudeCodeStatus(availability: .unknown("claude auth status failed (\(name))"),
                                    executablePath: executable, version: version)
        }
    }

    func signIn() async throws {
        let task = signInTask.withLock { running -> Task<Void, Error> in
            if let running { return running }
            let task = Task { [self] in
                defer { signInTask.withLock { $0 = nil } }
                try await runSignIn()
            }
            running = task
            return task
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// App termination: ends a running sign-in at once (`claude auth login`
    /// with its process group, blocking for at most about a second) and
    /// starts none afterwards.
    func shutdown() {
        signInTask.withLock { $0 }?.cancel()
        resources.shutdown()
    }

    private func runSignIn() async throws {
        // Orbit is quitting: no new browser flow (one that starts meanwhile is ended by the resources).
        guard !resources.isShutDown else { throw LLMError.cancelled }
        guard let executable = await locator.locate(configuredPath: await executablePath()) else {
            throw LLMError.claudeCodeNotInstalled
        }
        Log.llm.info("claude-code: starting sign-in (claude auth login)")
        let launch = ClaudeCodeProcess.Launch(executable: executable, arguments: ["auth", "login", "--claudeai"],
                                              environment: environment(for: executable),
                                              workingDirectory: NSHomeDirectory())
        let output: ClaudeCodeCommand.Output
        do {
            // stdin stays open: the CLI also accepts a pasted code there.
            output = try await ClaudeCodeCommand.run(launch, timeout: signInTimeout, keepsStdinOpen: true,
                                                     resources: resources)
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch ClaudeCodeCommand.Failure.timedOut {
            Log.llm.notice("claude-code: sign-in timed out")
            throw LLMError.claudeCodeNotLoggedIn
        } catch ClaudeCodeProcess.Failure.spawnFailed {
            throw LLMError.claudeCodeNotInstalled
        } catch {
            throw LLMError.providerProcessFailed(detail: "claude auth login could not run")
        }
        guard output.exit == .exited(0) else {
            Log.llm.notice("claude-code: sign-in failed (\(output.exit.description, privacy: .public))")
            throw LLMError.claudeCodeNotLoggedIn
        }
        Log.llm.info("claude-code: sign-in finished")
    }

    private func environment(for executable: String) -> [String: String] {
        ClaudeCodeLaunch.environment(base: baseEnvironment, extra: extraEnvironment, executable: executable)
    }
}

/// Short, token-free Claude Code commands.
enum ClaudeCodeCLI {
    struct AuthStatus: Sendable, Hashable {
        var loggedIn: Bool
        /// "claude.ai" (subscription), "console", …; nil when not reported.
        var authMethod: String?
        /// "max", "pro", …; nil when not reported.
        var subscriptionType: String?
    }

    static let commandTimeout: Duration = .seconds(20)

    /// `claude auth status --json`. Throws `.claudeCodeNotInstalled` when the
    /// executable cannot be started and `.providerProcessFailed` when the
    /// answer is not understood.
    static func authStatus(executable: String, environment: [String: String]) async throws -> AuthStatus {
        let output = try await runCommand(executable: executable, arguments: ["auth", "status", "--json"],
                                          environment: environment)
        guard let status = parseAuthStatus(output.stdout) else {
            throw LLMError.providerProcessFailed(detail: "Unexpected output of claude auth status (\(output.exit))")
        }
        return status
    }

    /// `claude --version`, e.g. "2.1.251"; nil when it cannot be determined.
    static func version(executable: String, environment: [String: String]) async -> String? {
        guard let output = try? await runCommand(executable: executable, arguments: ["--version"],
                                                 environment: environment),
              output.exit == .exited(0) else { return nil }
        return parseVersion(output.stdout)
    }

    /// Reads only `loggedIn`, `authMethod` and `subscriptionType`.
    static func parseAuthStatus(_ output: String) -> AuthStatus? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let json = try? JSONValue.parse(String(output[start...end])),
              let loggedIn = json["loggedIn"]?.boolValue else { return nil }
        return AuthStatus(loggedIn: loggedIn,
                          authMethod: json["authMethod"]?.stringValue,
                          subscriptionType: json["subscriptionType"]?.stringValue)
    }

    static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    private static func runCommand(executable: String, arguments: [String],
                                   environment: [String: String]) async throws -> ClaudeCodeCommand.Output {
        let launch = ClaudeCodeProcess.Launch(executable: executable, arguments: arguments, environment: environment,
                                              workingDirectory: NSHomeDirectory())
        do {
            return try await ClaudeCodeCommand.run(launch, timeout: commandTimeout)
        } catch ClaudeCodeProcess.Failure.spawnFailed {
            throw LLMError.claudeCodeNotInstalled
        } catch ClaudeCodeCommand.Failure.timedOut {
            throw LLMError.providerProcessFailed(detail: "claude \(arguments.first ?? "") timed out")
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch {
            throw LLMError.providerProcessFailed(detail: "claude \(arguments.first ?? "") could not run")
        }
    }
}
