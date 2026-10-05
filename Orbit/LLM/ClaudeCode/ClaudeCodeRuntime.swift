import Foundation
import os

/// Runs Orbit's conversations on the user's Claude subscription through the
/// locally installed, unmodified Claude Code CLI.
///
/// Owns at most one `claude` process: the one of the current conversation,
/// reused for its later turns and replaced when another conversation starts,
/// when model, effort, system prompt or tools change, after a failed turn, and
/// after 15 minutes without a request. Orbit never reads, stores or forwards
/// Claude credentials; the CLI uses its own login.
///
/// `shutdown()` (from `applicationWillTerminate`) ends the process, stops the
/// MCP bridge and removes the temporary files synchronously.
final class ClaudeCodeRuntime: Sendable {
    struct Configuration: Sendable {
        /// Working directory of the CLI (empty; holds only Orbit's 0600 files).
        var workingDirectory: URL
        var locator: ClaudeCodeLocator
        /// Orbit's environment; only a few variables are passed on (see `ClaudeCodeLaunch`).
        var baseEnvironment: [String: String]
        /// Added to the CLI's environment (tests: a fake CLI's scenario).
        var extraEnvironment: [String: String] = [:]
        var idleTimeout: Duration = .seconds(15 * 60)
        var interruptTimeout: Duration = .seconds(10)
        /// Injectable so tests control the idle timeout.
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        static var standard: Configuration {
            Configuration(
                workingDirectory: AppPaths.applicationSupport.appendingPathComponent("ClaudeCode", isDirectory: true),
                locator: .standard(),
                baseEnvironment: ProcessInfo.processInfo.environment
            )
        }

        func environment(executable: String) -> [String: String] {
            ClaudeCodeLaunch.environment(base: baseEnvironment, extra: extraEnvironment, executable: executable)
        }
    }

    let configuration: Configuration
    private let resources = ClaudeCodeResources()
    private let manager: ClaudeCodeSessionManager

    convenience init() {
        self.init(configuration: .standard)
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        manager = ClaudeCodeSessionManager(configuration: configuration, resources: resources)
    }

    /// Ends everything at once (blocking for at most about a second).
    func shutdown() {
        resources.shutdown()
    }

    /// Runs one turn of `request`; events are handed to `emit` as they arrive.
    func run(_ request: LLMRequest, executablePath: String?,
             emit: @escaping @Sendable (LLMEvent) -> Void) async throws -> AssistantTurn {
        try await manager.run(request, configuredExecutable: executablePath, emit: emit)
    }

    /// The executable a request would use, or nil when Claude Code is not installed.
    func locateExecutable(configuredPath: String?) async -> String? {
        await manager.executable(configuredPath: configuredPath)
    }

    /// Installed and signed in (`claude auth status`); spends no tokens.
    func validateInstallation(executablePath: String?) async throws {
        guard let executable = await locateExecutable(configuredPath: executablePath) else {
            throw LLMError.claudeCodeNotInstalled
        }
        let status = try await ClaudeCodeCLI.authStatus(executable: executable,
                                                       environment: configuration.environment(executable: executable))
        guard status.loggedIn else { throw LLMError.claudeCodeNotLoggedIn }
    }

    // MARK: Diagnostics (tests)

    /// The pid of the live process, if any.
    func currentProcessID() async -> pid_t? {
        await manager.currentProcessID()
    }

    /// What Claude Code reported at the start of the last turn of the live process.
    func currentInitInfo() async -> ClaudeCodeInitInfo? {
        await manager.currentInitInfo()
    }
}

/// The session bookkeeping of `ClaudeCodeRuntime`.
actor ClaudeCodeSessionManager {
    private let configuration: ClaudeCodeRuntime.Configuration
    private let resources: ClaudeCodeResources
    private var session: ClaudeCodeSession?
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = 0
    private var shellExecutable: String?

    init(configuration: ClaudeCodeRuntime.Configuration, resources: ClaudeCodeResources) {
        self.configuration = configuration
        self.resources = resources
    }

    func run(_ request: LLMRequest, configuredExecutable: String?,
             emit: @escaping @Sendable (LLMEvent) -> Void) async throws -> AssistantTurn {
        guard !resources.isShutDown else { throw LLMError.cancelled }
        let model = try ClaudeCodeLaunch.validatedModel(request.model)
        guard request.messages.last?.role == .user else {
            throw LLMError.invalidRequest(message: "The conversation does not end with a user message")
        }
        cancelIdleTimer()
        guard let executable = await executable(configuredPath: configuredExecutable) else {
            throw LLMError.claudeCodeNotInstalled
        }
        try Task.checkCancellation()

        let offersTools = request.toolExecutor != nil && !request.tools.isEmpty
        let settings = ClaudeCodeLaunchSettings(executable: executable, model: model, effort: request.effort,
                                                systemPrompt: request.systemPrompt,
                                                tools: offersTools ? request.tools : [])
        let conversationID = request.conversationID ?? UUID()

        var active: ClaudeCodeSession?
        var blocks: [String] = []
        if let current = session, current.conversationID == conversationID, current.settings == settings {
            await current.waitUntilIdle()
            if session === current, await current.isReusable,
               let input = ClaudeCodeHistory.continuation(known: await current.knownMessageIDs, messages: request.messages) {
                active = current
                blocks = ClaudeCodeHistory.inputBlocks(of: input)
            }
        }
        if active == nil {
            if let previous = session {
                session = nil
                await previous.terminate(reason: "replaced")
            }
            try Task.checkCancellation()
            blocks = ClaudeCodeHistory.firstMessageBlocks(for: request.messages)
            guard !blocks.isEmpty else {
                throw LLMError.invalidRequest(message: "The request has no text")
            }
            let started = try await ClaudeCodeSession.start(
                conversationID: conversationID, settings: settings,
                workingDirectory: configuration.workingDirectory,
                environment: configuration.environment(executable: executable),
                resources: resources,
                timing: ClaudeCodeSession.Timing(interruptTimeout: configuration.interruptTimeout, sleep: configuration.sleep)
            )
            if let replaced = session {
                // Another request started a session meanwhile; this one wins.
                await replaced.terminate(reason: "replaced")
            }
            session = started
            active = started
        }
        guard let active, !blocks.isEmpty else {
            throw LLMError.invalidRequest(message: "The request has no text")
        }

        do {
            let turn = try await active.runTurn(blocks: blocks, messageIDs: request.messages.map(\.id),
                                                executor: offersTools ? request.toolExecutor : nil, emit: emit)
            scheduleIdleTimer()
            return turn
        } catch {
            if error is CancellationError || (error as? LLMError) == .cancelled {
                // The process drains the interrupted turn and stays usable.
                scheduleIdleTimer()
                throw LLMError.cancelled
            }
            // A failed turn leaves the process out of step with the history.
            await active.invalidate()
            if session === active {
                session = nil
            }
            await active.terminate(reason: "turn failed")
            throw error
        }
    }

    /// The configured executable when usable, else the first usable candidate
    /// (checked each time, so an updated Claude app is picked up), else the
    /// login shell's answer (cached, re-checked before use).
    func executable(configuredPath: String?) async -> String? {
        if let found = configuration.locator.locateWithoutShell(configuredPath: configuredPath) {
            return found
        }
        if let shellExecutable, ClaudeCodeLocator.isUsableExecutable(shellExecutable) {
            return shellExecutable
        }
        shellExecutable = await configuration.locator.locateWithShell()
        return shellExecutable
    }

    func currentProcessID() -> pid_t? {
        session?.process.pid
    }

    func currentInitInfo() async -> ClaudeCodeInitInfo? {
        await session?.initInfo
    }

    // MARK: Idle timeout

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
        idleGeneration += 1
    }

    private func scheduleIdleTimer() {
        cancelIdleTimer()
        let generation = idleGeneration
        let sleep = configuration.sleep
        let timeout = configuration.idleTimeout
        idleTask = Task { [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            await self?.idleTimeoutFired(generation)
        }
    }

    private func idleTimeoutFired(_ generation: Int) async {
        guard generation == idleGeneration, let current = session else { return }
        guard await current.isIdle, generation == idleGeneration, session === current else { return }
        session = nil
        Log.llm.info("claude-code: idle timeout")
        await current.terminate(reason: "idle")
    }
}

/// Everything that must be torn down synchronously at app termination.
final class ClaudeCodeResources: Sendable {
    private struct State: Sendable {
        var processes: [pid_t: ClaudeCodeProcess] = [:]
        var servers: [ObjectIdentifier: LoopbackHTTPServer] = [:]
        var files: Set<URL> = []
        var isShutDown = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isShutDown: Bool {
        state.withLock { $0.isShutDown }
    }

    /// Returns false after shutdown (the caller must stop the process itself).
    func register(_ process: ClaudeCodeProcess) -> Bool {
        state.withLock { state in
            guard !state.isShutDown else { return false }
            state.processes[process.pid] = process
            return true
        }
    }

    func unregister(_ process: ClaudeCodeProcess) {
        state.withLock { _ = $0.processes.removeValue(forKey: process.pid) }
    }

    /// Returns false after shutdown.
    func register(_ server: LoopbackHTTPServer) -> Bool {
        state.withLock { state in
            guard !state.isShutDown else { return false }
            state.servers[ObjectIdentifier(server)] = server
            return true
        }
    }

    func unregister(_ server: LoopbackHTTPServer) {
        state.withLock { _ = $0.servers.removeValue(forKey: ObjectIdentifier(server)) }
    }

    func register(file: URL) {
        state.withLock { _ = $0.files.insert(file) }
    }

    /// Deletes a registered temporary file.
    func removeFile(_ file: URL) {
        state.withLock { _ = $0.files.remove(file) }
        try? FileManager.default.removeItem(at: file)
    }

    func shutdown() {
        let (processes, servers, files) = state.withLock { state in
            state.isShutDown = true
            defer {
                state.processes = [:]
                state.servers = [:]
                state.files = []
            }
            return (Array(state.processes.values), Array(state.servers.values), state.files)
        }
        for server in servers {
            server.stop()
        }
        for process in processes {
            process.terminateSynchronously(timeout: 1)
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        if !processes.isEmpty {
            Log.llm.info("claude-code: shut down \(processes.count, privacy: .public) process(es)")
        }
    }
}
