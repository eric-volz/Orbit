import Darwin
import Foundation
import Security
import os

/// What a Claude Code process was started with. A later turn can reuse the
/// process only when all of it is unchanged.
struct ClaudeCodeLaunchSettings: Sendable, Hashable {
    var executable: String
    var model: String
    var effort: ReasoningEffort?
    var systemPrompt: String
    /// Offered tools; empty when the request offers none (or has no executor).
    var tools: [ToolDefinition]
}

/// One running `claude` process for one conversation, with its MCP bridge and
/// temporary files. Runs one turn at a time: sends the user message, decodes
/// stdout until the turn's `result`, and routes the tool calls of the turn to
/// its executor.
///
/// Cancelling a turn answers pending tool calls with an error, asks the CLI to
/// interrupt (`control_request` / `interrupt`) and ends the caller's wait right
/// away; the session drains the interrupted turn in the background and is
/// reusable afterwards. When the CLI does not confirm in time, the process is
/// terminated instead (the next turn starts a new one with a transcript).
actor ClaudeCodeSession {
    struct Timing: Sendable {
        /// How long an interrupted turn may take to finish before the process is terminated.
        var interruptTimeout: Duration = .seconds(10)
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    nonisolated let conversationID: UUID
    nonisolated let settings: ClaudeCodeLaunchSettings
    nonisolated let process: ClaudeCodeProcess
    private let mcpServer: OrbitMCPServer?
    private let httpServer: LoopbackHTTPServer?
    private let files: [URL]
    private let resources: ClaudeCodeResources
    private let timing: Timing

    /// Ids of the history messages the process has been sent (see `ClaudeCodeHistory`).
    private(set) var knownMessageIDs: [UUID] = []
    /// What Claude Code reported at the start of the last turn.
    private(set) var initInfo: ClaudeCodeInitInfo?
    private(set) var isAlive = true
    private var isReusableFlag = true
    private var turn: Turn?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var interruptRequestID: String?
    private var readerTask: Task<Void, Never>?
    private var didCheckMCPConnection = false

    private struct Turn {
        let id: UUID
        var decoder: ClaudeCodeStreamDecoder
        let emit: @Sendable (LLMEvent) -> Void
        let startedAt = ContinuousClock.now
        var continuation: CheckedContinuation<AssistantTurn, Error>?
        /// Set when the turn ended before the caller started waiting.
        var outcome: Result<AssistantTurn, Error>?
        var isCancelled = false
        var watchdog: Task<Void, Never>?
    }

    private init(conversationID: UUID, settings: ClaudeCodeLaunchSettings, process: ClaudeCodeProcess,
                 mcpServer: OrbitMCPServer?, httpServer: LoopbackHTTPServer?, files: [URL],
                 resources: ClaudeCodeResources, timing: Timing) {
        self.conversationID = conversationID
        self.settings = settings
        self.process = process
        self.mcpServer = mcpServer
        self.httpServer = httpServer
        self.files = files
        self.resources = resources
        self.timing = timing
    }

    // MARK: Starting

    /// Starts the process (and, when tools are offered, the MCP bridge).
    static func start(conversationID: UUID, settings: ClaudeCodeLaunchSettings, workingDirectory: URL,
                      environment: [String: String], resources: ClaudeCodeResources,
                      timing: Timing) async throws -> ClaudeCodeSession {
        try ClaudeCodeFiles.prepareDirectory(workingDirectory)
        let fileID = UUID().uuidString.lowercased()
        let systemPromptFile = workingDirectory.appendingPathComponent("system-prompt-\(fileID).txt")
        var files = [systemPromptFile]
        var mcpServer: OrbitMCPServer?
        var httpServer: LoopbackHTTPServer?

        func cleanUp() {
            httpServer?.stop()
            if let httpServer { resources.unregister(httpServer) }
            for file in files { resources.removeFile(file) }
        }

        do {
            try ClaudeCodeFiles.writePrivateFile(systemPromptFile, contents: Data(settings.systemPrompt.utf8))
            resources.register(file: systemPromptFile)

            var mcpConfigFile: URL?
            if !settings.tools.isEmpty {
                let configFile = workingDirectory.appendingPathComponent("mcp-config-\(fileID).json")
                let token = try ClaudeCodeFiles.randomToken()
                // The config holds the token: it is removed as soon as the CLI connected.
                let server = OrbitMCPServer(tools: settings.tools, token: token) {
                    resources.removeFile(configFile)
                }
                let http = LoopbackHTTPServer { request in
                    await server.respond(to: request)
                }
                guard resources.register(http) else { throw LLMError.cancelled }
                httpServer = http
                mcpServer = server
                let port: UInt16
                do {
                    port = try await http.start()
                } catch {
                    throw LLMError.providerProcessFailed(detail: "The tool bridge could not be started")
                }
                server.setPort(port)
                let url = URL(string: "http://127.0.0.1:\(port)\(OrbitMCPServer.path)")!
                try ClaudeCodeFiles.writePrivateFile(configFile,
                                                     contents: ClaudeCodeLaunch.mcpConfiguration(url: url, token: token).jsonData())
                files.append(configFile)
                resources.register(file: configFile)
                mcpConfigFile = configFile
            }

            let launch = ClaudeCodeProcess.Launch(
                executable: settings.executable,
                arguments: ClaudeCodeLaunch.arguments(model: settings.model, effort: settings.effort,
                                                      systemPromptFile: systemPromptFile.path,
                                                      mcpConfigFile: mcpConfigFile?.path),
                environment: environment,
                workingDirectory: workingDirectory.path
            )
            let process: ClaudeCodeProcess
            do {
                process = try ClaudeCodeProcess.launch(launch)
            } catch ClaudeCodeProcess.Failure.spawnFailed(let code) where code == ENOENT || code == EACCES || code == ENOEXEC {
                throw LLMError.claudeCodeNotInstalled
            } catch {
                throw LLMError.providerProcessFailed(detail: "Starting Claude Code failed (\(error))")
            }
            guard resources.register(process) else {
                process.terminate(gracePeriod: 0.5)
                throw LLMError.cancelled
            }
            Log.llm.info("claude-code: started process \(process.pid, privacy: .public) (tools: \(settings.tools.count, privacy: .public))")
            let session = ClaudeCodeSession(conversationID: conversationID, settings: settings, process: process,
                                            mcpServer: mcpServer, httpServer: httpServer, files: files,
                                            resources: resources, timing: timing)
            await session.startReading()
            return session
        } catch {
            cleanUp()
            throw error
        }
    }

    private func startReading() {
        let process = process
        // Runs on the actor and holds the session until its process ended, so
        // cleanup always runs.
        readerTask = Task {
            for await line in process.lines {
                self.handle(line)
            }
            await self.readerFinished()
        }
    }

    // MARK: State

    /// Whether a new turn may continue this process (alive, never failed).
    var isReusable: Bool { isAlive && isReusableFlag }

    /// Whether no turn is running or draining.
    var isIdle: Bool { turn == nil }

    /// Returns when no turn is running or draining any more.
    func waitUntilIdle() async {
        guard turn != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Marks the process as out of step with the conversation (a failed turn).
    func invalidate() {
        isReusableFlag = false
    }

    // MARK: Turns

    /// Sends one user message and waits for the end of the turn. `messageIDs`
    /// are the history ids the process knows once the message is sent.
    func runTurn(blocks: [String], messageIDs: [UUID], executor: (any ToolExecuting)?,
                 emit: @escaping @Sendable (LLMEvent) -> Void) async throws -> AssistantTurn {
        guard isAlive else {
            throw ClaudeCodeErrorClassifier.processExit(process.exitStatus ?? .exited(-1), stderr: process.stderrTail,
                                                        model: settings.model)
        }
        guard turn == nil else {
            throw LLMError.providerProcessFailed(detail: "Claude Code is still busy with another request")
        }
        let id = UUID()
        turn = Turn(id: id, decoder: ClaudeCodeStreamDecoder(turnID: id.uuidString, configuredModel: settings.model),
                    emit: emit)
        mcpServer?.beginTurn(id, executor: executor)
        knownMessageIDs = messageIDs

        do {
            try await process.write(Self.userMessage(id: id, blocks: blocks))
        } catch {
            // The process is gone; `readerFinished` reports how it ended.
            Log.llm.error("claude-code: writing the request failed")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attach(continuation, to: id)
            }
        } onCancel: {
            Task { await self.cancelTurn(id) }
        }
    }

    private func attach(_ continuation: CheckedContinuation<AssistantTurn, Error>, to id: UUID) {
        guard var current = turn, current.id == id else {
            continuation.resume(throwing: LLMError.providerProcessFailed(detail: "The request ended unexpectedly"))
            return
        }
        if let outcome = current.outcome {
            turn = nil
            continuation.resume(with: outcome)
            signalIdle()
        } else if current.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            current.continuation = continuation
            turn = current
        }
    }

    /// Stops the running turn (the consumer went away).
    func cancelTurn(_ id: UUID) {
        guard var current = turn, current.id == id, !current.isCancelled, current.outcome == nil else { return }
        current.isCancelled = true
        let continuation = current.continuation
        current.continuation = nil
        // Pending tool calls get an error result right away.
        mcpServer?.endTurn(id, message: OrbitMCPServer.cancelledMessage)
        let requestID = "orbit-interrupt-\(UUID().uuidString.lowercased())"
        interruptRequestID = requestID
        let timing = timing
        current.watchdog = Task { [weak self] in
            do { try await timing.sleep(timing.interruptTimeout) } catch { return }
            await self?.interruptTimedOut(id)
        }
        turn = current
        continuation?.resume(throwing: CancellationError())
        Log.llm.info("claude-code: interrupting the running turn")

        let process = process
        Task { [weak self] in
            do {
                try await process.write(Self.interruptRequest(id: requestID))
            } catch {
                await self?.terminate(reason: "interrupt could not be sent")
            }
        }
    }

    private func interruptTimedOut(_ id: UUID) {
        guard turn?.id == id else { return }
        Log.llm.notice("claude-code: interrupted turn did not finish in time; terminating the process")
        terminate(reason: "interrupt timed out")
    }

    /// Ends a turn with `outcome` (success, error, or the end of a drained cancellation).
    private func complete(_ id: UUID, _ outcome: Result<AssistantTurn, Error>) {
        guard var current = turn, current.id == id, current.outcome == nil else { return }
        current.watchdog?.cancel()
        mcpServer?.endTurn(id)
        let milliseconds = ClaudeCodeLaunch.milliseconds(ContinuousClock.now - current.startedAt)
        if current.isCancelled {
            turn = nil
            interruptRequestID = nil
            Log.llm.info("claude-code: interrupted turn finished after \(milliseconds, privacy: .public) ms")
            signalIdle()
            return
        }
        switch outcome {
        case .success:
            Log.llm.info("claude-code: turn finished after \(milliseconds, privacy: .public) ms, \(current.decoder.toolCallCount, privacy: .public) tool calls")
        case .failure(let error):
            let name = (error as? LLMError).map(ProviderHTTP.logName(of:)) ?? String(describing: type(of: error))
            Log.llm.error("claude-code: turn failed with \(name, privacy: .public) after \(milliseconds, privacy: .public) ms")
        }
        if let continuation = current.continuation {
            turn = nil
            continuation.resume(with: outcome)
            signalIdle()
        } else {
            current.outcome = outcome
            turn = current
        }
    }

    private func signalIdle() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: Output

    private func handle(_ line: String) {
        guard !line.isEmpty, let message = try? JSONValue.parse(line) else { return }
        switch message["type"]?.stringValue {
        case "control_response":
            handleControlResponse(message["response"] ?? .null)
            return
        case "control_request":
            // Orbit configures nothing that asks the host (no permission prompt tool, no hooks).
            refuseControlRequest(message["request_id"]?.stringValue ?? "")
            return
        default:
            break
        }
        guard var current = turn, current.outcome == nil else { return }
        let events: [LLMEvent]
        do {
            events = try current.decoder.consume(message)
        } catch {
            turn = current
            complete(current.id, .failure(error))
            return
        }
        if initInfo != current.decoder.initInfo, let info = current.decoder.initInfo {
            initInfo = info
            checkMCPConnection(info)
        }
        turn = current
        if !current.isCancelled {
            for event in events {
                current.emit(event)
            }
        }
        if let finished = current.decoder.finishedTurn {
            complete(current.id, .success(finished))
        }
    }

    private func handleControlResponse(_ response: JSONValue) {
        guard let requestID = response["request_id"]?.stringValue, requestID == interruptRequestID else { return }
        if response["subtype"]?.stringValue == "error" {
            Log.llm.notice("claude-code: interrupt not supported; terminating the process")
            terminate(reason: "interrupt not supported")
        }
    }

    private func refuseControlRequest(_ requestID: String) {
        let response: JSONValue = .object([
            "type": "control_response",
            "response": .object([
                "subtype": "error",
                "request_id": .string(requestID),
                "error": "Orbit does not handle this request.",
            ]),
        ])
        let process = process
        Task { try? await process.write(response.jsonData() + Data("\n".utf8)) }
    }

    private func checkMCPConnection(_ info: ClaudeCodeInitInfo) {
        guard !didCheckMCPConnection else { return }
        didCheckMCPConnection = true
        if !settings.tools.isEmpty, info.mcpServers[ClaudeCodeLaunch.mcpServerName] != "connected" {
            Log.llm.error("claude-code: Orbit's tool bridge is not connected (status: \(info.mcpServers[ClaudeCodeLaunch.mcpServerName] ?? "missing", privacy: .public))")
        }
        let unexpected = info.tools.filter { !$0.hasPrefix(ClaudeCodeLaunch.mcpToolPrefix) }.count
        if unexpected > 0 || !info.skills.isEmpty || !info.slashCommands.isEmpty || info.hasMemoryPaths {
            Log.llm.notice("claude-code: isolation incomplete (built-in tools: \(unexpected, privacy: .public), skills: \(info.skills.count, privacy: .public), commands: \(info.slashCommands.count, privacy: .public), memory: \(info.hasMemoryPaths, privacy: .public))")
        }
    }

    // MARK: Ending

    private func readerFinished() async {
        let exit = await process.waitForExit()
        await process.waitForStderr(timeout: .seconds(1))
        isAlive = false
        isReusableFlag = false
        Log.llm.info("claude-code: process \(self.process.pid, privacy: .public) ended (\(exit.description, privacy: .public))")
        if let current = turn {
            let error = ClaudeCodeErrorClassifier.processExit(exit, stderr: process.stderrTail, model: settings.model)
            complete(current.id, .failure(error))
        }
        cleanUp()
    }

    /// Terminates the process; a running turn fails. Cleanup follows when it exited.
    func terminate(reason: StaticString) {
        isReusableFlag = false
        if let current = turn, !current.isCancelled {
            complete(current.id, .failure(LLMError.providerProcessFailed(detail: "Claude Code was stopped")))
        }
        guard process.isRunning else { return }
        Log.llm.info("claude-code: terminating process \(self.process.pid, privacy: .public) (\(reason, privacy: .public))")
        process.closeStdin()
        process.terminate(gracePeriod: 2)
    }

    private func cleanUp() {
        if let id = turn?.id {
            mcpServer?.endTurn(id)
        }
        httpServer?.stop()
        if let httpServer { resources.unregister(httpServer) }
        for file in files {
            resources.removeFile(file)
        }
        resources.unregister(process)
        readerTask = nil
    }

    // MARK: Messages

    static func userMessage(id: UUID, blocks: [String]) -> Data {
        let message: JSONValue = .object([
            "type": "user",
            "uuid": .string(id.uuidString.lowercased()),
            "message": .object([
                "role": "user",
                "content": .array(blocks.map { .object(["type": "text", "text": .string($0)]) }),
            ]),
        ])
        return message.jsonData() + Data("\n".utf8)
    }

    static func interruptRequest(id: String) -> Data {
        let request: JSONValue = .object([
            "type": "control_request",
            "request_id": .string(id),
            "request": .object(["subtype": "interrupt"]),
        ])
        return request.jsonData() + Data("\n".utf8)
    }
}

/// The working directory and the per-process files (0600 in a 0700 directory).
enum ClaudeCodeFiles {
    /// Leftovers of processes that did not end cleanly are removed after this age.
    static let staleFileAge: TimeInterval = 10 * 60

    static func prepareDirectory(_ directory: URL) throws {
        do {
            try PrivateFile.prepareDirectory(directory)
        } catch {
            throw LLMError.providerProcessFailed(detail: "The Claude Code working directory could not be created")
        }
        removeStaleFiles(in: directory)
    }

    static func removeStaleFiles(in directory: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where (name.hasPrefix("system-prompt-") && name.hasSuffix(".txt"))
            || (name.hasPrefix("mcp-config-") && name.hasSuffix(".json")) {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > staleFileAge else { continue }
            try? fileManager.removeItem(atPath: path)
        }
    }

    /// Creates a new file readable only by the user (never follows symlinks).
    static func writePrivateFile(_ url: URL, contents: Data) throws {
        do {
            try PrivateFile.create(at: url, contents: contents)
        } catch PrivateFile.Failure.create(let code) {
            throw LLMError.providerProcessFailed(detail: "A temporary file could not be created (errno \(code))")
        } catch {
            throw LLMError.providerProcessFailed(detail: "A temporary file could not be written")
        }
    }

    /// 256 random bits, hex encoded.
    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LLMError.providerProcessFailed(detail: "No random bytes for the bridge token")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
