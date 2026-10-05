import Darwin
import Foundation
import os

/// Child processes started with `posix_spawn`: the Claude Code CLI
/// (`ClaudeCodeProcess`) and short commands such as `osascript` (`run`).
///
/// - The child gets its own process group, so signals reach helpers it starts.
/// - Only stdin, stdout and stderr are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`);
///   no other descriptor of Orbit (database, sockets of the MCP bridge) leaks
///   into the child.
/// - Signal dispositions are reset to their defaults and nothing is masked.
enum ChildProcess {
    struct Launch: Sendable {
        var executable: String
        /// Arguments after argv[0].
        var arguments: [String]
        var environment: [String: String]
        var workingDirectory: String?
    }

    enum Exit: Sendable, Hashable, CustomStringConvertible {
        case exited(Int32)
        case signaled(Int32)

        var description: String {
            switch self {
            case .exited(let status): "exit status \(status)"
            case .signaled(let signal): "signal \(signal)"
            }
        }
    }

    enum Failure: Error, Sendable, Hashable {
        case spawnFailed(errno: Int32)
        case pipeFailed(errno: Int32)
        /// stdin is closed or the child stopped reading it (exited).
        case stdinClosed
    }

    /// Where the child's stdin comes from.
    enum Stdin: Sendable {
        /// A pipe the parent writes to (`Spawned.stdin`). Writing to it after the
        /// child exited fails with EPIPE instead of raising SIGPIPE.
        case pipe
        /// /dev/null: the child reads end of file at once.
        case nullDevice
    }

    /// A started child and the parent's ends of its standard streams. The
    /// caller owns the descriptors and closes them.
    struct Spawned: Sendable {
        var pid: pid_t
        /// Write end of the child's stdin; -1 for `Stdin.nullDevice`.
        var stdin: Int32
        var stdout: Int32
        var stderr: Int32
    }

    // MARK: Spawning

    static func spawn(_ launch: Launch, stdin: Stdin) throws -> Spawned {
        let stdinPipe: (read: Int32, write: Int32)
        switch stdin {
        case .pipe: stdinPipe = try makePipe()
        case .nullDevice: stdinPipe = (-1, -1)
        }
        let stdoutPipe: (read: Int32, write: Int32)
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stdoutPipe = try makePipe()
        } catch {
            closeAll([stdinPipe.read, stdinPipe.write])
            throw error
        }
        do {
            stderrPipe = try makePipe()
        } catch {
            closeAll([stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write])
            throw error
        }
        if stdinPipe.write >= 0 {
            // Writing to a pipe whose reader is gone returns EPIPE instead of killing Orbit.
            _ = fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if stdinPipe.read >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.read, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO)
        if let directory = launch.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: only the descriptors set up above reach the child.
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2, SIGTSTP, SIGTTIN, SIGTTOU] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)

        let argv = CStringArray([launch.executable] + launch.arguments)
        let envp = CStringArray(launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let result = posix_spawn(&pid, launch.executable, &fileActions, &attributes, argv.pointers, envp.pointers)

        closeAll([stdinPipe.read, stdoutPipe.write, stderrPipe.write])
        guard result == 0 else {
            closeAll([stdinPipe.write, stdoutPipe.read, stderrPipe.read])
            throw Failure.spawnFailed(errno: result)
        }
        return Spawned(pid: pid, stdin: stdinPipe.write, stdout: stdoutPipe.read, stderr: stderrPipe.read)
    }

    // MARK: Helpers

    /// Blocks until `pid` exited and reaps it.
    static func waitForExit(of pid: pid_t) -> Exit {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return .exited(-1) }
        }
        let signal = status & 0x7F
        return signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
    }

    /// Blocks until `pid` exited, without reaping it: it stays a zombie, so its
    /// pid cannot belong to another process until `reap(_:)`.
    static func waitForExitWithoutReaping(of pid: pid_t) -> Exit {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 {
            guard errno == EINTR else { return .exited(-1) }
        }
        switch info.si_code {
        case CLD_EXITED: return .exited(info.si_status)
        case CLD_KILLED, CLD_DUMPED: return .signaled(info.si_status)
        default: return .exited(-1)
        }
    }

    /// Reaps an exited child (see `waitForExitWithoutReaping(of:)`).
    static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    /// Sends `signal` to the child's process group and to the child. Callers
    /// make sure the child was not reaped yet: its pid may belong to another
    /// process by then.
    static func signalGroup(of pid: pid_t, _ signal: Int32) {
        kill(-pid, signal)
        kill(pid, signal)
    }

    static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Failure.pipeFailed(errno: errno) }
        // Orbit's other child processes must not inherit them.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    static func closeAll(_ fds: [Int32]) {
        for fd in fds where fd >= 0 {
            close(fd)
        }
    }

    static func startThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.stackSize = 256 * 1024
        thread.start()
    }
}

// MARK: - Running a command to completion

extension ChildProcess {
    /// How a command run with `run(_:timeout:outputLimit:errorLimit:)` ended.
    struct Output: Sendable, Hashable {
        var exit: Exit
        /// stdout, at most the output limit.
        var stdout: Data
        /// The last bytes of stderr (at most the error limit). May contain user
        /// content: never log it.
        var stderr: Data
        /// stdout went beyond the output limit, so the child was killed.
        var exceededOutputLimit: Bool
    }

    enum RunFailure: Error, Sendable, Hashable {
        /// The command ran longer than its timeout and was stopped.
        case timedOut
    }

    /// After the child exited, how long its stdout and stderr may stay open (a
    /// helper it started in the background may hold them) before the run ends
    /// without the rest.
    static let pipeGracePeriod: Duration = .seconds(2)
    /// How long a stopped child gets between SIGTERM and SIGKILL.
    static let killGracePeriod: Duration = .seconds(1)

    /// Runs `launch` to completion with stdin from /dev/null and returns what
    /// it wrote. A child that writes more than `outputLimit` bytes to stdout is
    /// killed (`Output.exceededOutputLimit`). After `timeout`, or when the
    /// calling task is cancelled, the child's process group gets SIGTERM and,
    /// a second later, SIGKILL; the call then throws `RunFailure.timedOut` or
    /// `CancellationError` once the child is gone.
    static func run(_ launch: Launch, timeout: Duration, outputLimit: Int,
                    errorLimit: Int = 16 * 1024) async throws -> Output {
        try Task.checkCancellation()
        let spawned = try spawn(launch, stdin: .nullDevice)
        let run = CommandRun(pid: spawned.pid, outputLimit: max(0, outputLimit), errorLimit: max(0, errorLimit))
        startThread("child stdout") { run.read(spawned.stdout, stream: .stdout) }
        startThread("child stderr") { run.read(spawned.stderr, stream: .stderr) }
        startThread("child wait") { run.waitForExit() }
        run.scheduleTimeout(after: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.install(continuation)
            }
        } onCancel: {
            run.stop(.cancelled)
        }
    }
}

/// The state of one `ChildProcess.run`, shared by its reader, waiter and timer.
private final class CommandRun: Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    enum StopReason: Sendable {
        case timedOut
        case cancelled
        case outputLimit
    }

    private struct State: Sendable {
        var stdout = Data()
        var stderr = Data()
        var exceededOutputLimit = false
        var exit: ChildProcess.Exit?
        var stdoutClosed = false
        var stderrClosed = false
        var stopReason: StopReason?
        var result: Result<ChildProcess.Output, any Error>?
        var continuation: CheckedContinuation<ChildProcess.Output, any Error>?
    }

    let pid: pid_t
    private let outputLimit: Int
    private let errorLimit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pid: pid_t, outputLimit: Int, errorLimit: Int) {
        self.pid = pid
        self.outputLimit = outputLimit
        self.errorLimit = errorLimit
    }

    // MARK: Threads

    /// Reads `fd` until end of file (runs on its own thread) and closes it.
    func read(_ fd: Int32, stream: Stream) {
        defer {
            close(fd)
            update { state in
                switch stream {
                case .stdout: state.stdoutClosed = true
                case .stderr: state.stderrClosed = true
                }
            }
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let bytes = chunk[0..<count]
            switch stream {
            case .stdout:
                let overflow = state.withLock { state -> Bool in
                    guard !state.exceededOutputLimit else { return false }
                    let room = outputLimit - state.stdout.count
                    guard bytes.count > room else {
                        state.stdout.append(contentsOf: bytes)
                        return false
                    }
                    state.stdout.append(contentsOf: bytes.prefix(max(0, room)))
                    state.exceededOutputLimit = true
                    return true
                }
                if overflow { stop(.outputLimit) }
            case .stderr:
                state.withLock { state in
                    state.stderr.append(contentsOf: bytes)
                    if state.stderr.count > errorLimit {
                        state.stderr.removeFirst(state.stderr.count - errorLimit)
                    }
                }
            }
        }
    }

    /// Waits for the child (runs on its own thread). The exit is recorded and
    /// the child reaped under the lock, so `signal(_:)` never reaches a reused pid.
    func waitForExit() {
        let exit = ChildProcess.waitForExitWithoutReaping(of: pid)
        update { state in
            state.exit = exit
            ChildProcess.reap(pid)
        }
        // A helper the child started may keep stdout or stderr open; do not wait for it forever.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ChildProcess.pipeGracePeriod.timeInterval) { [weak self] in
            self?.update { state in
                state.stdoutClosed = true
                state.stderrClosed = true
            }
        }
    }

    func scheduleTimeout(after timeout: Duration) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
            self?.stop(.timedOut)
        }
    }

    // MARK: Stopping

    /// Stops the child (once): SIGKILL right away when it wrote too much,
    /// otherwise SIGTERM and SIGKILL a second later if it is still running.
    func stop(_ reason: StopReason) {
        let shouldSignal = state.withLock { state -> Bool in
            guard state.exit == nil, state.result == nil else { return false }
            if state.stopReason == nil { state.stopReason = reason }
            return true
        }
        guard shouldSignal else { return }
        if reason == .outputLimit {
            signal(SIGKILL)
            return
        }
        signal(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ChildProcess.killGracePeriod.timeInterval) { [weak self] in
            self?.signal(SIGKILL)
        }
    }

    /// Signals the child's group while the child has not been reaped.
    private func signal(_ signal: Int32) {
        state.withLock { state in
            // Inside the lock: the waiter records the exit under it right after reaping.
            guard state.exit == nil else { return }
            ChildProcess.signalGroup(of: pid, signal)
        }
    }

    // MARK: Completion

    func install(_ continuation: CheckedContinuation<ChildProcess.Output, any Error>) {
        let result = state.withLock { state -> Result<ChildProcess.Output, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    /// Applies `change`; finishes the run once the child exited and both
    /// streams are closed.
    private func update(_ change: @Sendable (inout State) -> Void) {
        let finished = state.withLock { state -> (CheckedContinuation<ChildProcess.Output, any Error>?, Result<ChildProcess.Output, any Error>)? in
            change(&state)
            guard state.result == nil, let exit = state.exit, state.stdoutClosed, state.stderrClosed else { return nil }
            let result: Result<ChildProcess.Output, any Error> = switch state.stopReason {
            case .timedOut?: .failure(ChildProcess.RunFailure.timedOut)
            case .cancelled?: .failure(CancellationError())
            case .outputLimit?, nil:
                .success(ChildProcess.Output(exit: exit, stdout: state.stdout, stderr: state.stderr,
                                             exceededOutputLimit: state.exceededOutputLimit))
            }
            state.result = result
            defer { state.continuation = nil }
            return (state.continuation, result)
        }
        if let (continuation, result) = finished {
            continuation?.resume(with: result)
        }
    }
}

private extension Duration {
    /// Seconds as a `TimeInterval` (for Dispatch deadlines).
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// A NULL-terminated array of C strings for `posix_spawn`, freed on deinit.
private final class CStringArray {
    let pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) } + [nil]
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }
}
