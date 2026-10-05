import Foundation

/// State of the locally installed Claude Code CLI, for settings and onboarding.
/// Never contains account identifiers (e-mail, organization).
struct ClaudeCodeStatus: Sendable, Hashable {
    enum Availability: Sendable, Hashable {
        case notInstalled
        case notLoggedIn
        case ready
        /// The status could not be determined (message for logs/UI details).
        case unknown(String)
    }

    var availability: Availability
    var executablePath: String?
    var version: String?
    /// "max", "pro", … as reported by `claude auth status`.
    var subscriptionType: String?
    /// "claude.ai", "api_key", … as reported by `claude auth status`.
    var authMethod: String?
}

/// Status and sign-in for the Claude Code provider. Sign-in always runs
/// Anthropic's own flow (`claude auth login`, browser); Orbit never sees credentials.
protocol ClaudeCodeAccountServicing: Sendable {
    func status() async -> ClaudeCodeStatus
    /// Runs `claude auth login` and returns when it finished.
    func signIn() async throws
}
