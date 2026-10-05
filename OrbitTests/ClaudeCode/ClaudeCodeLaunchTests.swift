import Foundation
import Testing
@testable import Orbit

@Suite("Claude Code launch configuration")
struct ClaudeCodeLaunchTests {
    @Test func argumentsIsolateTheCLI() {
        let arguments = ClaudeCodeLaunch.arguments(model: "sonnet", effort: .medium, systemPromptFile: "/w/system-prompt.txt",
                                                   mcpConfigFile: "/w/mcp-config.json")
        #expect(arguments == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages",
            "--verbose", "--model=sonnet", "--effort", "medium", "--tools", "", "--disable-slash-commands",
            "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
            "--settings", #"{"crossSessionInbound":"refuse"}"#, "--system-prompt-file", "/w/system-prompt.txt",
            "--mcp-config", "/w/mcp-config.json", "--allowedTools", "mcp__orbit__*",
        ])
    }

    @Test func withoutToolsThereIsNoMCPConfiguration() {
        let arguments = ClaudeCodeLaunch.arguments(model: "opus", effort: nil, systemPromptFile: "/w/p.txt", mcpConfigFile: nil)
        #expect(!arguments.contains("--mcp-config"))
        #expect(!arguments.contains("--allowedTools"))
        #expect(!arguments.contains("--effort"))
        #expect(arguments.contains("--strict-mcp-config"))
    }

    @Test func theMCPConfigurationPointsAtTheBridge() throws {
        let url = try #require(URL(string: "http://127.0.0.1:50123/mcp"))
        let config = ClaudeCodeLaunch.mcpConfiguration(url: url, token: "abc")
        let server = try #require(config["mcpServers"]?["orbit"])
        #expect(server["type"] == "http")
        #expect(server["url"] == "http://127.0.0.1:50123/mcp")
        #expect(server["headers"]?["Authorization"] == "Bearer abc")
        #expect(server["timeout"]?.intValue == 3_600_000)
        #expect(server["alwaysLoad"] == true)
    }

    @Test func theEnvironmentIsMinimalAndForcesTheSubscriptionLogin() {
        let base = [
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "HOME": "/Users/test",
            "USER": "test",
            "LANG": "de_DE.UTF-8",
            "TMPDIR": "/tmp/t/",
            "ANTHROPIC_API_KEY": "sk-secret",
            "ANTHROPIC_BASE_URL": "https://proxy.example",
            "ANTHROPIC_AUTH_TOKEN": "t",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc.sock",
            "CLAUDE_CODE_MESSAGING_TOKEN": "secret",
            "CLAUDE_AUTO_BACKGROUND_TASKS": "1",
            "MCP_CONNECTION_NONBLOCKING": "1",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "HTTPS_PROXY": "http://proxy:3128",
            "ORBIT_DATA_DIR": "/tmp/orbit",
        ]
        let environment = ClaudeCodeLaunch.environment(base: base, extra: ["FAKE": "1"],
                                                       executable: "/Users/test/.local/bin/claude")
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["USER"] == "test")
        #expect(environment["LANG"] == "de_DE.UTF-8")
        #expect(environment["TMPDIR"] == "/tmp/t/")
        #expect(environment["HTTPS_PROXY"] == "http://proxy:3128")
        #expect(environment["PATH"] == "/Users/test/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["FAKE"] == "1")
        for key in environment.keys {
            #expect(!key.hasPrefix("ANTHROPIC_"))
            #expect(key != "CLAUDECODE")
            #expect(key != "DYLD_INSERT_LIBRARIES" && key != "ORBIT_DATA_DIR" && key != "CLAUDE_AUTO_BACKGROUND_TASKS")
            if key.hasPrefix("CLAUDE_CODE_") {
                #expect(ClaudeCodeLaunch.fixedVariables[key] != nil, "\(key) must not be inherited")
            }
        }
        for (key, value) in ClaudeCodeLaunch.fixedVariables {
            #expect(environment[key] == value)
        }
        #expect(environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_BUNDLED_SKILLS"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(environment["DISABLE_TELEMETRY"] == "1")
        #expect(environment["MCP_TOOL_TIMEOUT"] == "3600000")
    }

    @Test func missingBasicsGetDefaults() {
        let environment = ClaudeCodeLaunch.environment(base: [:], executable: "/usr/local/bin/claude")
        #expect(environment["PATH"] == "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(environment["LANG"] == "en_US.UTF-8")
    }

    @Test(arguments: ["sonnet", "opus", "haiku", "claude-sonnet-5", "claude-opus-4-6[1m]", "sonnet[1m]", " sonnet "])
    func acceptsModelAliasesAndIDs(model: String) throws {
        #expect(try ClaudeCodeLaunch.validatedModel(model) == model.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: ["", "  ", "--dangerously-skip-permissions", "-p", "sonnet opus", "a;rm -rf", String(repeating: "a", count: 200)])
    func rejectsMalformedModels(model: String) {
        #expect(throws: LLMError.self) { try ClaudeCodeLaunch.validatedModel(model) }
    }

    @Test func messagesAreSingleJSONLines() throws {
        let id = UUID()
        let data = ClaudeCodeSession.userMessage(id: id, blocks: ["Zeile 1\nZeile 2", "\u{2028}Ende \"zitiert\""])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text.dropLast().contains("\n") == false)
        let json = try JSONValue.parse(String(text.dropLast()))
        #expect(json["type"] == "user")
        #expect(json["uuid"]?.stringValue == id.uuidString.lowercased())
        #expect(json["message"]?["role"] == "user")
        #expect(ClaudeCodeTest.textBlocks(json) == ["Zeile 1\nZeile 2", "\u{2028}Ende \"zitiert\""])

        let interrupt = try JSONValue.parse(String(decoding: ClaudeCodeSession.interruptRequest(id: "r1").dropLast(), as: UTF8.self))
        #expect(interrupt == ["type": "control_request", "request_id": "r1", "request": ["subtype": "interrupt"]])
    }

    @Test func privateFilesAreOwnerOnly() throws {
        let directory = try ClaudeCodeTest.makeDirectory()
        defer { ClaudeCodeTest.removeDirectory(directory) }
        let workingDirectory = directory.appendingPathComponent("ClaudeCode")
        try ClaudeCodeFiles.prepareDirectory(workingDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: workingDirectory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let file = workingDirectory.appendingPathComponent("system-prompt-x.txt")
        try ClaudeCodeFiles.writePrivateFile(file, contents: Data("geheim".utf8))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "geheim")
        // Never overwrites or follows an existing path.
        #expect(throws: LLMError.self) { try ClaudeCodeFiles.writePrivateFile(file, contents: Data()) }
        let link = workingDirectory.appendingPathComponent("mcp-config-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("target"))
        #expect(throws: LLMError.self) { try ClaudeCodeFiles.writePrivateFile(link, contents: Data()) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("target").path))
    }

    @Test func staleFilesAreRemovedOthersKept() throws {
        let directory = try ClaudeCodeTest.makeDirectory()
        defer { ClaudeCodeTest.removeDirectory(directory) }
        let old = directory.appendingPathComponent("mcp-config-old.json")
        let fresh = directory.appendingPathComponent("system-prompt-fresh.txt")
        let foreign = directory.appendingPathComponent("notes.txt")
        for file in [old, fresh, foreign] {
            try Data("x".utf8).write(to: file)
        }
        let past = Date().addingTimeInterval(-3_600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: foreign.path)
        ClaudeCodeFiles.removeStaleFiles(in: directory)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func tokensAreRandom256Bits() throws {
        let first = try ClaudeCodeFiles.randomToken()
        let second = try ClaudeCodeFiles.randomToken()
        #expect(first.count == 64 && second.count == 64)
        #expect(first != second)
        let isHex = first.allSatisfy(\.isHexDigit)
        #expect(isHex)
    }
}
