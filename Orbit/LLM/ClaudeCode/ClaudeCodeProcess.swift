import Darwin
import Foundation
import os

/// A long-running child process for the Claude Code CLI, started like every
/// child of Orbit (`ChildProcess.spawn`: own process group, only the standard
/// descriptors inherited).
///
/// - Writing to a child that exited fails with an error instead of raising
///   SIGPIPE in Orbit.
/// - stdout is delivered line by line (`lines`, one consumer); the tail of
///   stderr is kept for diagnostics and never shown to the user.
final class ClaudeCodeProcess: Sendable {
    typealias Launch = ChildProcess.Launch
    typealias Exit = ChildProcess.Exit
    typealias Failure = ChildProcess.Failure

    /// Lines longer than this are dropped (a protocol message is never that large).
    static let maxLineBytes = 64 * 1024 * 1024
    /// Bytes of stderr kept for diagnostics.
    static let stderrTailBytes = 16 * 1024

    let pid: pid_t
    /// stdout, split into lines without the line break. Finishes at EOF.
    let lines: AsyncStream<String>

    private struct State: Sendable {
        var exit: Exit?
        var exitWaiters: [CheckedContinuation<Exit, Never>] = []
        var stderrTail = Data()
        var stdinFD: Int32
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Fires when stderr reached EOF (the tail is complete).
    private let stderrEnded = ClaudeCodeSignal()
    /// Serializes writes to stdin (they may block while the child is busy).
    private let writeQueue = DispatchQueue(label: "io.github.eric-volz.Orbit.claude-code.stdin")

    private init(pid: pid_t, stdinFD: Int32, lines: AsyncStream<String>) {
        self.pid = pid
        self.lines = lines
        state = OSAllocatedUnfairLock(initialState: State(stdinFD: stdinFD))
    }

    deinit {
        let fd = state.withLock { state -> Int32 in
            defer { state.stdinFD = -1 }
            return state.stdinFD
        }
        if fd >= 0 { close(fd) }
    }

    // MARK: Launching

    static func launch(_ launch: Launch) throws -> ClaudeCodeProcess {
        let spawned = try ChildProcess.spawn(launch, stdin: .pipe)
        let (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let childPID = spawned.pid
        let process = ClaudeCodeProcess(pid: childPID, stdinFD: spawned.stdin, lines: lines)
        let stdoutFD = spawned.stdout
        let stderrFD = spawned.stderr
        ChildProcess.startThread("claude-code stdout") {
            readLines(from: stdoutFD, into: continuation)
        }
        let stderrEnded = process.stderrEnded
        ChildProcess.startThread("claude-code stderr") { [weak process] in
            readStderr(from: stderrFD, process: process)
            stderrEnded.fire()
        }
        ChildProcess.startThread("claude-code wait") { [process] in
            process.recordExit(ChildProcess.waitForExit(of: childPID))
        }
        return process
    }

    // MARK: State

    var exitStatus: Exit? {
        state.withLock { $0.exit }
    }

    var isRunning: Bool { exitStatus == nil }

    /// The last bytes the child wrote to stderr (diagnostics only; may contain
    /// user content; never log it publicly or show it).
    var stderrTail: String {
        String(decoding: state.withLock { $0.stderrTail }, as: UTF8.self)
    }

    /// Waits (at most `timeout`) until stderr is closed, so `stderrTail` is complete.
    func waitForStderr(timeout: Duration) async {
        await stderrEnded.wait(timeout: timeout)
    }

    /// Waits until the child exited (returns at once if it did).
    func waitForExit() async -> Exit {
        await withCheckedContinuation { continuation in
            let exit = state.withLock { state -> Exit? in
                if let exit = state.exit { return exit }
                state.exitWaiters.append(continuation)
                return nil
            }
            if let exit { continuation.resume(returning: exit) }
        }
    }

    // MARK: stdin

    /// Writes all bytes to the child's stdin. Throws `Failure.stdinClosed` when
    /// stdin was closed or the child no longer reads it.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                do {
                    try writeAll(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Closes stdin once pending writes are done (the CLI exits at EOF).
    func closeStdin() {
        writeQueue.async { [self] in
            let fd = state.withLock { state -> Int32 in
                defer { state.stdinFD = -1 }
                return state.stdinFD
            }
            if fd >= 0 { close(fd) }
        }
    }

    private func writeAll(_ data: Data) throws {
        let fd = state.withLock { $0.stdinFD }
        guard fd >= 0 else { throw Failure.stdinClosed }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw Failure.stdinClosed
                }
            }
        }
    }

    // MARK: Termination

    /// SIGTERM to the process group, SIGKILL after `gracePeriod` if it is still running.
    func terminate(gracePeriod: TimeInterval = 2) {
        guard signalGroup(SIGTERM) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) { [self] in
            _ = signalGroup(SIGKILL)
        }
    }

    /// Terminates and waits (blocking) up to `timeout` before killing. For app
    /// termination, where no asynchronous work can run any more.
    func terminateSynchronously(timeout: TimeInterval) {
        guard signalGroup(SIGTERM) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            usleep(10_000)
        }
        _ = signalGroup(SIGKILL)
    }

    /// Sends `signal` to the child's process group (and the child). Returns
    /// false when the child already exited: its pid may belong to another
    /// process by now, so nothing is sent.
    @discardableResult
    private func signalGroup(_ signal: Int32) -> Bool {
        guard isRunning else { return false }
        ChildProcess.signalGroup(of: pid, signal)
        return true
    }

    private func recordExit(_ exit: Exit) {
        let waiters = state.withLock { state -> [CheckedContinuation<Exit, Never>] in
            state.exit = exit
            defer { state.exitWaiters = [] }
            return state.exitWaiters
        }
        for waiter in waiters {
            waiter.resume(returning: exit)
        }
    }

    private func appendStderr(_ bytes: Data) {
        state.withLock { state in
            state.stderrTail.append(bytes)
            if state.stderrTail.count > Self.stderrTailBytes {
                state.stderrTail.removeFirst(state.stderrTail.count - Self.stderrTailBytes)
            }
        }
    }

    // MARK: Helpers (run on dedicated threads)

    private static func readLines(from fd: Int32, into continuation: AsyncStream<String>.Continuation) {
        defer {
            close(fd)
            continuation.finish()
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var pending: [UInt8] = []
        var discardingOverlongLine = false
        func emit(_ bytes: ArraySlice<UInt8>) {
            var line = bytes
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            continuation.yield(String(decoding: line, as: UTF8.self))
        }
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            var start = 0
            for index in 0..<count where chunk[index] == UInt8(ascii: "\n") {
                if discardingOverlongLine {
                    discardingOverlongLine = false
                } else if pending.isEmpty {
                    emit(chunk[start..<index])
                } else {
                    pending.append(contentsOf: chunk[start..<index])
                    emit(pending[...])
                }
                pending.removeAll(keepingCapacity: true)
                start = index + 1
            }
            if start < count, !discardingOverlongLine {
                pending.append(contentsOf: chunk[start..<count])
                if pending.count > maxLineBytes {
                    pending = []
                    discardingOverlongLine = true
                    Log.llm.error("claude-code: dropped an overlong output line")
                }
            }
        }
        if !pending.isEmpty, !discardingOverlongLine {
            emit(pending[...])
        }
    }

    private static func readStderr(from fd: Int32, process: ClaudeCodeProcess?) {
        defer { close(fd) }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            process?.appendStderr(Data(chunk[0..<count]))
        }
    }

}

/// Fires once; waiting for it is cancellation-aware.
final class ClaudeCodeSignal: Sendable {
    private struct State: Sendable {
        var fired = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var hasFired: Bool {
        state.withLock { $0.fired }
    }

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns when fired or when the calling task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.fired || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// Returns when fired or after `timeout`.
    func wait(timeout: Duration) async {
        guard !hasFired else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
