import Foundation

/// Claude on the user's subscription, through the locally installed Claude
/// Code CLI (see `ClaudeCodeRuntime`). Claude Code runs the tool loop itself
/// and calls Orbit's tools through `LLMRequest.toolExecutor`; `.end` carries
/// the text of the whole run.
struct ClaudeCodeProvider: LLMProvider {
    let kind = ProviderKind.claudeCode
    let displayName = "Claude"
    /// The `claude` executable from the settings; nil = auto-detect.
    let executablePath: String?
    let runtime: ClaudeCodeRuntime

    var executesToolsInternally: Bool { true }

    init(configuration: ProviderConfiguration, runtime: ClaudeCodeRuntime) throws {
        guard configuration.kind == .claudeCode else {
            throw LLMError.invalidRequest(message: "Not a Claude Code configuration")
        }
        executablePath = ClaudeCodeLocator.expanded(configuration.executablePath)
        self.runtime = runtime
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let runtime = runtime
        let executablePath = executablePath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let turn = try await runtime.run(request, executablePath: executablePath) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.end(turn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.llmError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Installed and signed in; spends no tokens (the model is checked for its
    /// form only; Claude Code resolves aliases itself).
    func validateConfiguration(model: String) async throws {
        _ = try ClaudeCodeLaunch.validatedModel(model)
        try await runtime.validateInstallation(executablePath: executablePath)
    }

    static func llmError(_ error: any Error) -> LLMError {
        switch error {
        case let error as LLMError: error
        case is CancellationError: .cancelled
        default: .providerProcessFailed(detail: String(describing: type(of: error)))
        }
    }
}
