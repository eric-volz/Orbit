import Foundation
import Testing
@testable import Orbit

/// The sign-in to Claude Code with the fake CLI (`auth login` never finishes
/// with FAKE_CLAUDE_LOGIN=hang), never the real one, which opens Anthropic's
/// sign-in in the browser.
@Suite("Claude Code account service")
struct ClaudeCodeAccountServiceTests {
    private func service(logs: URL) -> ClaudeCodeAccountService {
        ClaudeCodeAccountService(executablePath: { nil }, locator: ClaudeCodeTest.locator(),
                                 baseEnvironment: ProcessInfo.processInfo.environment,
                                 extraEnvironment: ["FAKE_CLAUDE_LOGIN": "hang", "FAKE_CLAUDE_LOG_DIR": logs.path])
    }

    /// The pid of the fake's `auth login` (it records its arguments in login-args-<pid>.txt).
    private func signInProcessIDs(in logs: URL) -> [pid_t] {
        ClaudeCodeTest.records("login-args", in: logs).compactMap { record in
            record.deletingPathExtension().lastPathComponent.split(separator: "-").last.flatMap { pid_t($0) }
        }
    }

    /// Quitting Orbit ends a sign-in that still runs (started from Settings,
    /// the onboarding or a notice, which share the service) at once:
    /// `claude auth login` does not outlive Orbit, and none starts afterwards.
    @Test func shutdownEndsARunningSignIn() async throws {
        let logs = try ClaudeCodeTest.makeDirectory("orbit-cc-login")
        defer { ClaudeCodeTest.removeDirectory(logs) }
        let service = service(logs: logs)
        let signIn = Task { try await service.signIn() }
        #expect(await LLMTest.eventually(timeout: .seconds(10)) { !signInProcessIDs(in: logs).isEmpty })
        let pid = try #require(signInProcessIDs(in: logs).first)
        #expect(ClaudeCodeTest.isRunning(pid))

        let started = ContinuousClock.now
        service.shutdown()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!ClaudeCodeTest.isRunning(pid))
        await #expect(throws: LLMError.cancelled) { try await signIn.value }

        await #expect(throws: LLMError.cancelled) { try await service.signIn() }
        #expect(signInProcessIDs(in: logs) == [pid], "no sign-in starts while Orbit quits")
    }
}
