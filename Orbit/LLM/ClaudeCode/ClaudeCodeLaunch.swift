import Foundation

/// How Orbit starts Claude Code: command-line flags, the environment and the
/// MCP configuration that points the CLI at Orbit's tool bridge.
///
/// The CLI runs as a plain chat engine: no built-in tools, skills, slash
/// commands, plugins, hooks, memory, settings files or session files; peer
/// sessions cannot message it; telemetry and non-essential traffic are off.
/// Authentication is the user's own Claude Code login (never touched by Orbit).
enum ClaudeCodeLaunch {
    /// Name of the MCP server; Claude Code calls its tools `mcp__orbit__<name>`.
    static let mcpServerName = "orbit"
    static let mcpToolPrefix = "mcp__orbit__"
    /// Tool calls may wait this long, e.g. for the user to confirm a card.
    static let toolCallTimeout: Duration = .seconds(60 * 60)

    /// Variables passed through from Orbit's environment. Everything else is
    /// dropped, in particular ANTHROPIC_* (API keys, base URLs) and
    /// CLAUDE_CODE_* / CLAUDECODE (e.g. from a parent Claude Code session).
    static let inheritedVariables = [
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
        // Network configuration Claude Code honors (proxies, corporate CAs).
        "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy", "NODE_EXTRA_CA_CERTS",
    ]

    /// Switches set for every Claude Code process.
    static let fixedVariables: [String: String] = [
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
        "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": "1",
        "CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "DISABLE_AUTOUPDATER": "1",
        // Long MCP tool calls (confirmation cards wait for the user) must not
        // time out or be moved to the background.
        "MCP_TOOL_TIMEOUT": String(milliseconds(toolCallTimeout)),
        "CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": "0",
    ]

    static let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    // MARK: Arguments

    /// Flags of a streaming chat process. `mcpConfigFile` is nil when no tools
    /// are offered.
    static func arguments(model: String, effort: ReasoningEffort?, systemPromptFile: String,
                          mcpConfigFile: String?) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            // "=" binds the value even if it looked like a flag (validated anyway).
            "--model=\(model)",
        ]
        if let effort {
            arguments += ["--effort", effort.rawValue]
        }
        arguments += [
            "--tools", "",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--no-session-persistence",
            "--settings", #"{"crossSessionInbound":"refuse"}"#,
            "--system-prompt-file", systemPromptFile,
        ]
        if let mcpConfigFile {
            arguments += ["--mcp-config", mcpConfigFile, "--allowedTools", "\(mcpToolPrefix)*"]
        }
        return arguments
    }

    /// The `--mcp-config` document: Orbit's bridge as the only MCP server. Its
    /// tools are always loaded (never deferred behind tool search) and may take
    /// as long as a confirmation needs.
    static func mcpConfiguration(url: URL, token: String) -> JSONValue {
        .object([
            "mcpServers": .object([
                mcpServerName: .object([
                    "type": "http",
                    "url": .string(url.absoluteString),
                    "headers": .object(["Authorization": .string("Bearer \(token)")]),
                    "timeout": .number(Double(milliseconds(toolCallTimeout))),
                    "alwaysLoad": true,
                ]),
            ]),
        ])
    }

    // MARK: Environment

    /// The environment of a Claude Code process: a few inherited variables plus
    /// the fixed switches. `extra` is for tests (e.g. a fake CLI's scenario).
    static func environment(base: [String: String], extra: [String: String] = [:],
                            executable: String) -> [String: String] {
        var environment: [String: String] = [:]
        for name in inheritedVariables {
            if let value = base[name], !value.isEmpty {
                environment[name] = value
            }
        }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["PATH"] = searchPath(base["PATH"], executable: executable)
        environment.merge(fixedVariables) { _, fixed in fixed }
        environment.merge(extra) { _, extra in extra }
        return environment
    }

    /// Environment of the login-shell lookup (profiles set up PATH themselves).
    static func shellEnvironment(home: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["HOME": home, "PATH": standardPath, "LANG": base["LANG"] ?? "en_US.UTF-8"]
        for name in ["USER", "LOGNAME", "TMPDIR"] {
            if let value = base[name], !value.isEmpty { environment[name] = value }
        }
        return environment
    }

    /// Orbit's PATH (a GUI app gets a minimal one) plus the system directories
    /// and the executable's own directory, without duplicates.
    static func searchPath(_ inherited: String?, executable: String) -> String {
        var directories: [String] = []
        let executableDirectory = (executable as NSString).deletingLastPathComponent
        for directory in [executableDirectory] + (inherited ?? "").split(separator: ":").map(String.init)
            + standardPath.split(separator: ":").map(String.init) where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    // MARK: Validation

    /// The model alias or id, trimmed. Throws `.modelNotFound` for empty or
    /// malformed values (it is passed on the command line).
    static func validatedModel(_ raw: String) throws -> String {
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(model.count),
              model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@\[\]-]*$"#, options: .regularExpression) != nil
        else {
            throw LLMError.modelNotFound(model: model)
        }
        return model
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
