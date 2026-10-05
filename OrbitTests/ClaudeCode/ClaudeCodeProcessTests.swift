import Darwin
import Foundation
import Testing
@testable import Orbit

@Suite("Claude Code child process")
struct ClaudeCodeProcessTests {
    private func shell(_ script: String, environment: [String: String] = ["PATH": "/usr/bin:/bin"],
                       directory: String? = nil) throws -> ClaudeCodeProcess {
        try ClaudeCodeProcess.launch(ClaudeCodeProcess.Launch(executable: "/bin/sh", arguments: ["-c", script],
                                                              environment: environment, workingDirectory: directory))
    }

    private func collect(_ process: ClaudeCodeProcess) async -> [String] {
        var lines: [String] = []
        for await line in process.lines {
            lines.append(line)
        }
        return lines
    }

    @Test func deliversStdoutLineByLineAndTheExitStatus() async throws {
        let process = try shell(#"printf 'eins\nzwei\r\n\ndrei'; echo fehler >&2; exit 7"#)
        #expect(await collect(process) == ["eins", "zwei", "", "drei"])
        #expect(await process.waitForExit() == .exited(7))
        #expect(!process.isRunning)
        #expect(process.stderrTail == "fehler\n")
    }

    @Test func writesToStdinAndEndsAtEOF() async throws {
        let process = try shell("cat")
        try await process.write(Data("hallo\n".utf8))
        try await process.write(Data("welt\n".utf8))
        process.closeStdin()
        #expect(await collect(process) == ["hallo", "welt"])
        #expect(await process.waitForExit() == .exited(0))
    }

    @Test func writingToAnExitedChildFailsInsteadOfRaisingSIGPIPE() async throws {
        let process = try shell("exit 0")
        _ = await process.waitForExit()
        await #expect(throws: ClaudeCodeProcess.Failure.stdinClosed) {
            for _ in 0..<50 {
                try await process.write(Data(repeating: 0x41, count: 64 * 1024))
            }
        }
    }

    @Test func passesExactlyTheGivenEnvironmentAndDirectory() async throws {
        let directory = try ClaudeCodeTest.makeDirectory()
        defer { ClaudeCodeTest.removeDirectory(directory) }
        let process = try shell("env | sort; pwd -P", environment: ["PATH": "/usr/bin:/bin", "ORBIT_TEST": "ja"],
                                directory: directory.path)
        let lines = await collect(process)
        #expect(lines.contains("ORBIT_TEST=ja"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") })
        #expect(lines.last == directory.path)
    }

    @Test func theChildInheritsOnlyStandardDescriptorsAndGetsItsOwnGroup() async throws {
        // An open descriptor of Orbit (without CLOEXEC) must not reach the child.
        let leaked = open("/dev/null", O_RDONLY)
        defer { close(leaked) }
        // The shell's glob opens a single descriptor to read /dev/fd (`ls` opens
        // two on current systems).
        let process = try shell(#"echo /dev/fd/*; ps -o pgid= -p $$"#)
        let lines = await collect(process)
        let descriptors = lines.first?.split(separator: " ").compactMap { Int($0.dropFirst("/dev/fd/".count)) } ?? []
        // 0, 1, 2 and the descriptor the glob uses to read /dev/fd.
        #expect(descriptors.filter { $0 > 3 }.isEmpty, "inherited: \(descriptors)")
        #expect(!descriptors.contains(Int(leaked)) || leaked <= 3)
        #expect(lines.last?.trimmingCharacters(in: .whitespaces) == String(process.pid))
    }

    @Test func terminateStopsTheWholeGroup() async throws {
        let process = try shell("sleep 30 & echo $!; wait")
        var iterator = process.lines.makeAsyncIterator()
        let childPID = try #require(await iterator.next().flatMap { pid_t($0) })
        #expect(ClaudeCodeTest.isRunning(childPID))
        process.terminate(gracePeriod: 1)
        #expect(await process.waitForExit() == .signaled(SIGTERM))
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(childPID) })
    }

    @Test func terminateSynchronouslyKillsAStubbornChild() async throws {
        let process = try shell("trap '' TERM; echo ready; while true; do sleep 0.1; done")
        var iterator = process.lines.makeAsyncIterator()
        #expect(await iterator.next() == "ready")
        let started = ContinuousClock.now
        process.terminateSynchronously(timeout: 0.3)
        #expect(await process.waitForExit() == .signaled(SIGKILL))
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func spawnFailuresAreReported() {
        #expect(throws: ClaudeCodeProcess.Failure.spawnFailed(errno: ENOENT)) {
            try ClaudeCodeProcess.launch(ClaudeCodeProcess.Launch(executable: "/nonexistent/claude", arguments: [],
                                                                  environment: [:], workingDirectory: nil))
        }
    }

    // MARK: Commands

    @Test func commandsCollectOutput() async throws {
        let launch = ClaudeCodeProcess.Launch(executable: "/bin/sh", arguments: ["-c", "echo 2.1.251 '(Claude Code)'"],
                                              environment: [:], workingDirectory: nil)
        let output = try await ClaudeCodeCommand.run(launch, timeout: .seconds(10))
        #expect(output == ClaudeCodeCommand.Output(exit: .exited(0), stdout: "2.1.251 (Claude Code)\n"))
    }

    @Test func commandsTimeOut() async throws {
        let launch = ClaudeCodeProcess.Launch(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:],
                                              workingDirectory: nil)
        let started = ContinuousClock.now
        await #expect(throws: ClaudeCodeCommand.Failure.timedOut) {
            try await ClaudeCodeCommand.run(launch, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func cancellingACommandTerminatesIt() async throws {
        let marker = try ClaudeCodeTest.makeDirectory()
        defer { ClaudeCodeTest.removeDirectory(marker) }
        let launch = ClaudeCodeProcess.Launch(executable: "/bin/sh",
                                              arguments: ["-c", "echo $$ > '\(marker.path)/pid'; sleep 30"],
                                              environment: [:], workingDirectory: nil)
        let task = Task { try await ClaudeCodeCommand.run(launch, timeout: .seconds(60), keepsStdinOpen: true) }
        let pidFile = marker.appendingPathComponent("pid")
        // The shell creates the file before it writes the pid: wait for the pid itself
        // (an empty file would give pid 0, and kill(0, 0) always succeeds).
        func writtenPID() -> pid_t? {
            (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .flatMap { $0 > 0 ? $0 : nil }
        }
        #expect(await LLMTest.eventually { writtenPID() != nil })
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        let pid = try #require(writtenPID())
        #expect(await LLMTest.eventually { !ClaudeCodeTest.isRunning(pid) })
    }
}
