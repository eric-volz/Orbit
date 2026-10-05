import Foundation
import Testing
@testable import Orbit

@Suite("Claude Code locator")
struct ClaudeCodeLocatorTests {
    /// A temporary directory with helpers to create fake executables.
    private struct Sandbox {
        let root: URL

        init() throws {
            root = try ClaudeCodeTest.makeDirectory("orbit-cc-locator")
        }

        @discardableResult
        func file(_ relativePath: String, executable: Bool = true) throws -> String {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho claude\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            return url.path
        }

        func path(_ relativePath: String) -> String {
            root.appendingPathComponent(relativePath).path
        }
    }

    @Test func prefersAUsableConfiguredPath() async throws {
        let sandbox = try Sandbox()
        defer { ClaudeCodeTest.removeDirectory(sandbox.root) }
        let configured = try sandbox.file("custom/claude")
        let standard = try sandbox.file("home/.local/bin/claude")
        let locator = ClaudeCodeLocator(candidates: [standard]) { nil }
        #expect(await locator.locate(configuredPath: configured) == configured)
        #expect(await locator.locate(configuredPath: "  \(configured)\n") == configured)
    }

    @Test func fallsBackWhenTheConfiguredPathIsUnusable() async throws {
        let sandbox = try Sandbox()
        defer { ClaudeCodeTest.removeDirectory(sandbox.root) }
        let notExecutable = try sandbox.file("custom/claude", executable: false)
        let standard = try sandbox.file("home/.local/bin/claude")
        let locator = ClaudeCodeLocator(candidates: [sandbox.path("home/.claude/local/claude"), standard]) { nil }
        #expect(await locator.locate(configuredPath: notExecutable) == standard)
        #expect(await locator.locate(configuredPath: sandbox.path("missing/claude")) == standard)
        #expect(await locator.locate(configuredPath: sandbox.path("custom")) == standard) // a directory
        #expect(await locator.locate(configuredPath: "relative/claude") == standard)
        #expect(await locator.locate(configuredPath: nil) == standard)
        #expect(await locator.locate(configuredPath: "") == standard)
    }

    @Test func checksTheCandidatesInOrder() async throws {
        let sandbox = try Sandbox()
        defer { ClaudeCodeTest.removeDirectory(sandbox.root) }
        let candidates = ClaudeCodeLocator.standardCandidates(home: sandbox.path("home"))
        #expect(candidates == [sandbox.path("home/.local/bin/claude"), sandbox.path("home/.claude/local/claude"),
                               "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        let second = try sandbox.file("home/.claude/local/claude")
        let locator = ClaudeCodeLocator(candidates: Array(candidates.prefix(2))) { nil }
        #expect(await locator.locate(configuredPath: nil) == second)
        let first = try sandbox.file("home/.local/bin/claude")
        #expect(await locator.locate(configuredPath: nil) == first)
    }

    @Test func findsTheClaudeAppsCopyNewestVerifiedVersionFirst() async throws {
        let sandbox = try Sandbox()
        defer { ClaudeCodeTest.removeDirectory(sandbox.root) }
        let home = sandbox.path("home")
        let base = "home/Library/Application Support/Claude/claude-code"
        let binary = "claude.app/Contents/MacOS/claude"
        #expect(ClaudeCodeLocator.claudeAppCandidates(home: home).isEmpty)

        let older = try sandbox.file("\(base)/2.1.9/\(binary)")
        let newer = try sandbox.file("\(base)/2.1.10/\(binary)")
        let unverified = try sandbox.file("\(base)/2.2.0/\(binary)")
        try sandbox.file("\(base)/2.1.9/.verified")
        try sandbox.file("\(base)/2.1.10/.verified")
        try sandbox.file("\(base)/not-a-version/\(binary)")
        #expect(ClaudeCodeLocator.claudeAppCandidates(home: home) == [newer, older, unverified])

        // The app's copy comes before the CLI's install locations.
        let cli = try sandbox.file("home/.local/bin/claude")
        let candidates = ClaudeCodeLocator.standardCandidates(home: home)
        #expect(Array(candidates.prefix(4)) == [newer, older, unverified, cli])
        let locator = ClaudeCodeLocator(candidateList: { ClaudeCodeLocator.standardCandidates(home: home) }) { nil }
        #expect(await locator.locate(configuredPath: nil) == newer)
        #expect(ClaudeCodeLocator.isBundledWithClaudeApp(newer, home: home))
        #expect(!ClaudeCodeLocator.isBundledWithClaudeApp(cli, home: home))

        // A new version of the app is picked up without restarting Orbit.
        let update = try sandbox.file("\(base)/2.1.11/\(binary)")
        try sandbox.file("\(base)/2.1.11/.verified")
        #expect(await locator.locate(configuredPath: nil) == update)
    }

    @Test func followsSymlinksLikeTheNativeInstaller() async throws {
        let sandbox = try Sandbox()
        defer { ClaudeCodeTest.removeDirectory(sandbox.root) }
        let target = try sandbox.file("share/claude/versions/2.1.251")
        let link = sandbox.path("bin/claude")
        try FileManager.default.createDirectory(atPath: sandbox.path("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(ClaudeCodeLocator.isUsableExecutable(link))
        try FileManager.default.removeItem(atPath: target)
        #expect(!ClaudeCodeLocator.isUsableExecutable(link)) // dangling
    }

    @Test func asksTheLoginShellLast() async throws {
        let sandbox = try Sandbox()
        defer { ClaudeCodeTest.removeDirectory(sandbox.root) }
        let viaShell = try sandbox.file("nvm/bin/claude")
        let locator = ClaudeCodeLocator(candidates: [sandbox.path("home/.local/bin/claude")]) { viaShell }
        #expect(await locator.locate(configuredPath: nil) == viaShell)
        let bogus = ClaudeCodeLocator(candidates: []) { "claude: aliased to something" }
        #expect(await bogus.locate(configuredPath: nil) == nil)
        let nothing = ClaudeCodeLocator(candidates: []) { nil }
        #expect(await nothing.locate(configuredPath: nil) == nil)
    }

    @Test func theRealLoginShellLookupFindsCommandsOnItsPath() async throws {
        // `command -v` for a command that exists everywhere; proves the lookup
        // runs the shell, parses its output and finishes within the timeout.
        let launch = ClaudeCodeProcess.Launch(executable: "/bin/zsh", arguments: ["-lc", "command -v plutil"],
                                              environment: ClaudeCodeLaunch.shellEnvironment(home: NSHomeDirectory()),
                                              workingDirectory: NSHomeDirectory())
        let output = try await ClaudeCodeCommand.run(launch, timeout: .seconds(10))
        #expect(output.exit == .exited(0))
        #expect(output.stdout.split(separator: "\n").last.map(String.init) == "/usr/bin/plutil")
    }
}
