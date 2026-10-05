import Foundation

extension LLMProviderFactory {
    /// The real providers: HTTPS to the configured endpoint, or the Claude
    /// subscription through Claude Code (run by `claudeCodeRuntime`). Throws
    /// `LLMError.invalidBaseURL` for unusable base URLs.
    static func live(claudeCodeRuntime: ClaudeCodeRuntime) -> LLMProviderFactory {
        LLMProviderFactory { configuration in
            switch configuration.kind {
            case .anthropic:
                return try AnthropicProvider(configuration: configuration)
            case .openAICompatible:
                return try OpenAICompatibleProvider(configuration: configuration)
            case .claudeCode:
                return try ClaudeCodeProvider(configuration: configuration, runtime: claudeCodeRuntime)
            }
        }
    }
}
