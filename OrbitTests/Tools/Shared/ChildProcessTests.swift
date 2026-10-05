import Darwin
import Foundation
import Testing
@testable import Orbit

/// `ChildProcess.run`: the one-shot runner the AppleScript runner uses
/// (ClaudeCodeProcessTests cover the long-running Claude Code process that
/// shares `ChildProcess.spawn`).
@Suite("Child process: run to completion")
struct ChildProcessTests {
    private func shell(_ script: String, environment: [String: String] = ["PATH": "/usr/bin:/bin"],
                       directory: String? = nil) -> ChildProcess.Launch {
        ChildProcess.Launch(executable: "/bin/sh", arguments: ["-c", script], environment: environment,
                            workingDirectory: directory)
    }

    /// The pid a shell script wrote to `file` (waits for the whole number).
    private func writtenPID(_ file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil }
    }

    @Test func collectsStdoutStderrAndTheExitStatus() async throws {
        let output = try await ChildProcess.run(shell(#"printf 'eins\nzwei'; printf 'fehler' >&2; exit 3"#),
                                                timeout: .seconds(10), outputLimit: 1_000)
        #expect(output.exit == .exited(3))
        #expect(String(decoding: output.stdout, as: UTF8.self) == "eins\nzwei")
        #expect(String(decoding: output.stderr, as: UTF8.self) == "fehler")
        #expect(!output.exceededOutputLimit)
    }

    @Test func stdinIsTheNullDevice() async throws {
        // `cat` would wait forever on an open pipe; /dev/null ends it at once.
        let output = try await ChildProcess.run(shell("cat; echo fertig"), timeout: .seconds(10), outputLimit: 1_000)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "fertig\n")
        #expect(output.exit == .exited(0))
    }

    @Test func passesExactlyTheGivenEnvironmentAndDirectory() async throws {
        let directory = try ClaudeCodeTest.makeDirectory("orbit-child")
        defer { ClaudeCodeTest.removeDirectory(directory) }
        let output = try await ChildProcess.run(shell("env | sort; pwd -P", environment: ["PATH": "/usr/bin:/bin", "ORBIT_TEST": "ja"],
                                                      directory: directory.path),
                                                timeout: .seconds(10), outputLimit: 10_000)
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.contains("ORBIT_TEST=ja"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") })
        #expect(lines.last == directory.path)
    }

    @Test func theChildInheritsOnlyTheStandardDescriptors() async throws {
        let leaked = open("/dev/null", O_RDONLY)
        defer { close(leaked) }
        let output = try await ChildProcess.run(shell(#"echo /dev/fd/*"#), timeout: .seconds(10), outputLimit: 1_000)
        let descriptors = String(decoding: output.stdout, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0.dropFirst("/dev/fd/".count)) }
        // 0, 1, 2 and the descriptor the shell's glob uses to read /dev/fd.
        #expect(descriptors.filter { $0 > 3 }.isEmpty, "inherited: \(descriptors)")
    }

    @Test func outputBeyondTheLimitStopsTheChild() async throws {
        let started = ContinuousClock.now
        let output = try await ChildProcess.run(shell("yes Orbit"), timeout: .seconds(20), outputLimit: 10_000)
        #expect(output.exceededOutputLimit)
        #expect(output.stdout.count == 10_000)
        #expect(output.exit == .signaled(SIGKILL))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aTimeoutStopsTheChildAndItsGroup() async throws {
        let marker = try ClaudeCodeTest.makeDirectory("orbit-child")
        defer { ClaudeCodeTest.removeDirectory(marker) }
        let pidFile = marker.appendingPathComponent("pid")
        let started = ContinuousClock.now
        await #expect(throws: ChildProcess.RunFailure.timedOut) {
            // The helper `sleep` is in the child's process group and must go too.
            try await ChildProcess.run(shell("sleep 30 & echo $! > '\(pidFile.path)'; wait"),
                                       timeout: .milliseconds(500), outputLimit: 1_000)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        let helper = try #require(writtenPID(pidFile))
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(helper) })
    }

    @Test func aChildIgnoringSIGTERMIsKilled() async throws {
        let started = ContinuousClock.now
        await #expect(throws: ChildProcess.RunFailure.timedOut) {
            try await ChildProcess.run(shell("trap '' TERM; while true; do sleep 0.1; done"),
                                       timeout: .milliseconds(300), outputLimit: 1_000)
        }
        // SIGTERM at the timeout, SIGKILL a grace period later.
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func cancellingTheTaskStopsTheChild() async throws {
        let marker = try ClaudeCodeTest.makeDirectory("orbit-child")
        defer { ClaudeCodeTest.removeDirectory(marker) }
        let pidFile = marker.appendingPathComponent("pid")
        let launch = shell("echo $$ > '\(pidFile.path)'; sleep 30")
        let task = Task { try await ChildProcess.run(launch, timeout: .seconds(60), outputLimit: 1_000) }
        #expect(await LLMTest.eventually { writtenPID(pidFile) != nil })
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        let pid = try #require(writtenPID(pidFile))
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(pid) })
    }

    @Test func aCancelledTaskStartsNothing() async throws {
        let marker = try ClaudeCodeTest.makeDirectory("orbit-child")
        defer { ClaudeCodeTest.removeDirectory(marker) }
        let file = marker.appendingPathComponent("ran")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChildProcess.run(shell("touch '\(file.path)'"), timeout: .seconds(10), outputLimit: 1_000)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aHelperHoldingTheOutputOpenDoesNotBlockTheRun() async throws {
        let marker = try ClaudeCodeTest.makeDirectory("orbit-child")
        defer { ClaudeCodeTest.removeDirectory(marker) }
        let pidFile = marker.appendingPathComponent("pid")
        let started = ContinuousClock.now
        // The shell exits at once; the background `sleep` keeps stdout open.
        let output = try await ChildProcess.run(shell("sleep 30 & echo $! > '\(pidFile.path)'; echo fertig"),
                                                timeout: .seconds(20), outputLimit: 1_000)
        #expect(output.exit == .exited(0))
        #expect(String(decoding: output.stdout, as: UTF8.self) == "fertig\n")
        #expect(ContinuousClock.now - started < .seconds(6))
        if let helper = writtenPID(pidFile) { kill(helper, SIGKILL) }
    }

    @Test func spawnFailuresAreReported() async {
        await #expect(throws: ChildProcess.Failure.spawnFailed(errno: ENOENT)) {
            try await ChildProcess.run(ChildProcess.Launch(executable: "/nonexistent/orbit-tool", arguments: [],
                                                           environment: [:], workingDirectory: nil),
                                       timeout: .seconds(5), outputLimit: 1_000)
        }
    }

    @Test func stderrKeepsItsEnd() async throws {
        let output = try await ChildProcess.run(shell("i=0; while [ $i -lt 2000 ]; do echo zeile$i >&2; i=$((i+1)); done; echo ENDE >&2"),
                                                timeout: .seconds(20), outputLimit: 1_000, errorLimit: 100)
        let stderr = String(decoding: output.stderr, as: UTF8.self)
        #expect(output.stderr.count == 100)
        #expect(stderr.hasSuffix("ENDE\n"))
    }
}
