import Foundation

/// Finds the `claude` executable: the path configured in the settings when it
/// is usable, else Claude Code as bundled by the Claude desktop app, else the
/// standard install locations of the CLI, else the user's login shell
/// (`command -v claude`), which also covers installs through version managers.
struct ClaudeCodeLocator: Sendable {
    /// Checked in order after the configured path. Evaluated on every lookup:
    /// the Claude app keeps its copy in a new folder with each update.
    var candidates: @Sendable () -> [String]
    /// Asks the login shell; nil when it finds nothing (or takes too long).
    var shellLookup: @Sendable () async -> String?

    init(candidates: [String], shellLookup: @escaping @Sendable () async -> String?) {
        self.init(candidateList: { candidates }, shellLookup: shellLookup)
    }

    init(candidateList: @escaping @Sendable () -> [String], shellLookup: @escaping @Sendable () async -> String?) {
        candidates = candidateList
        self.shellLookup = shellLookup
    }

    /// The standard locations and a real login-shell lookup.
    static func standard(home: String = NSHomeDirectory()) -> ClaudeCodeLocator {
        ClaudeCodeLocator(candidateList: { standardCandidates(home: home) }) {
            await loginShellLookup(home: home)
        }
    }

    static func standardCandidates(home: String) -> [String] {
        claudeAppCandidates(home: home)
            + ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// The executable to run, or nil when Claude Code is not installed.
    func locate(configuredPath: String?) async -> String? {
        if let found = locateWithoutShell(configuredPath: configuredPath) {
            return found
        }
        return await locateWithShell()
    }

    /// The configured path or the first usable candidate (fast: no process).
    func locateWithoutShell(configuredPath: String?) -> String? {
        if let configured = Self.expanded(configuredPath), Self.isUsableExecutable(configured) {
            return configured
        }
        return candidates().first(where: Self.isUsableExecutable)
    }

    /// The login shell's answer, if it is a usable executable.
    func locateWithShell() async -> String? {
        guard let found = await shellLookup(), Self.isUsableExecutable(found) else { return nil }
        return found
    }

    /// An absolute path to an executable regular file (symlinks are followed).
    static func isUsableExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let resolved = (path as NSString).resolvingSymlinksInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: resolved)
    }

    /// The configured path with "~" expanded and whitespace trimmed; nil when empty.
    static func expanded(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    // MARK: Claude desktop app

    /// Where the Claude desktop app keeps its copy of Claude Code, one folder per version.
    static func claudeAppDirectory(home: String) -> String {
        "\(home)/Library/Application Support/Claude/claude-code"
    }

    /// Whether `path` is the Claude desktop app's copy of Claude Code.
    static func isBundledWithClaudeApp(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        path.hasPrefix(claudeAppDirectory(home: home) + "/")
    }

    /// The Claude app's copies of Claude Code, newest version first; versions
    /// whose download the app verified (`.verified`) come before the others.
    static func claudeAppCandidates(home: String) -> [String] {
        let root = claudeAppDirectory(home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let versions = names.compactMap { name -> (name: String, numbers: [Int], verified: Bool)? in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            let verified = FileManager.default.fileExists(atPath: "\(root)/\(name)/.verified")
            return (name, parts.compactMap { $0 }, verified)
        }
        return versions
            .sorted { lhs, rhs in
                if lhs.verified != rhs.verified { return lhs.verified }
                return rhs.numbers.lexicographicallyPrecedes(lhs.numbers)
            }
            .map { "\(root)/\($0.name)/claude.app/Contents/MacOS/claude" }
    }

    // MARK: Login shell

    /// How long the login shell may take (profiles can be slow).
    static let shellLookupTimeout: Duration = .seconds(5)

    /// `/bin/zsh -lc 'command -v claude'` with a minimal environment. Returns the
    /// last output line that is an absolute path (profiles may print other text).
    static func loginShellLookup(home: String) async -> String? {
        let launch = ClaudeCodeProcess.Launch(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v claude"],
            environment: ClaudeCodeLaunch.shellEnvironment(home: home),
            workingDirectory: home
        )
        guard let output = try? await ClaudeCodeCommand.run(launch, timeout: shellLookupTimeout),
              output.exit == .exited(0) else { return nil }
        return output.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }
}
