import Darwin
import Foundation
import Testing
@testable import Orbit

/// The live runner with real osascript, on test scripts that target no app
/// (`OrbitTests/Fixtures/AppleScripts`): no Apple Event leaves the process.
@Suite("AppleScript runner (osascript, scripts without an app)")
struct AppleScriptRunnerTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/AppleScripts", isDirectory: true)

    let runner = LiveAppleScriptRunner(scriptsDirectory: Self.fixtures, environment: ProcessInfo.processInfo.environment)

    static func script(_ name: String, app: ScriptedApp? = nil, timeout: Duration = .seconds(30)) -> AppleScript {
        AppleScript(name: name, app: app, timeout: timeout)
    }

    private struct Echo: Decodable {
        var count: Int
        var args: [String]
    }

    @Test func theFixturesTargetNoApp() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "applescript" }
        #expect(files.count >= 5)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("tell application") && !source.contains("application \""), "\(file.lastPathComponent)")
        }
    }

    // MARK: Arguments

    @Test func argumentsArriveAsPlainData() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-pwned-\(UUID().uuidString)")
        let injection = "a\"; do shell script \"touch '\(marker.path)'\"; \""
        let arguments = [injection, "Grüße „Lisa“ 👨‍👩‍👧 \\ \u{2028}", "-e", "--", "", "zwei\nZeilen", "end run"]
        let echo = try await runner.runJSON(Self.script("echo-args"), arguments: arguments, as: Echo.self)
        #expect(echo.count == arguments.count)
        #expect(echo.args == arguments)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the injected command must not run")
    }

    @Test func noArgumentsIsAnEmptyArgv() async throws {
        let echo = try await runner.runJSON(Self.script("echo-args"), arguments: [], as: Echo.self)
        #expect(echo.count == 0)
    }

    @Test func nulCharactersAndOversizedArgumentsAreRefusedBeforeStarting() async {
        await #expect(throws: AppleScriptError.invalidArgument) {
            try await runner.run(Self.script("echo-args"), arguments: ["a\u{0}b"])
        }
        let big = String(repeating: "x", count: LiveAppleScriptRunner.maxArgumentBytes)
        await #expect(throws: AppleScriptError.argumentsTooLarge) {
            try await runner.run(Self.script("echo-args"), arguments: [big])
        }
        // Just below the limit is fine (the limit counts a terminator per argument).
        let fitting = String(repeating: "x", count: LiveAppleScriptRunner.maxArgumentBytes - 1)
        #expect(throws: Never.self) { try LiveAppleScriptRunner.validate([fitting]) }
    }

    // MARK: Results

    @Test(arguments: [("text", "text"), ("number", "42"), ("list", "a, b, 3"), ("empty", ""), ("nothing", ""),
                      ("lines", "eins\nzwei")])
    func theResultIsWhatTheScriptPrinted(kind: String, expected: String) async throws {
        #expect(try await runner.run(Self.script("results"), arguments: [kind]) == expected)
    }

    @Test func outputThatIsNotTheExpectedJSONIsInvalid() async {
        await #expect(throws: AppleScriptError.invalidOutput) {
            try await runner.runJSON(Self.script("results"), arguments: ["text"], as: Echo.self)
        }
    }

    @Test func outputBeyondTheLimitIsRefused() async throws {
        let small = LiveAppleScriptRunner(scriptsDirectory: Self.fixtures, outputLimit: 1_000)
        #expect(try await small.run(Self.script("big"), arguments: ["999"]).count == 999)
        await #expect(throws: AppleScriptError.outputTooLarge) {
            try await small.run(Self.script("big"), arguments: ["50000"])
        }
    }

    @Test func aMissingScriptIsReported() async {
        await #expect(throws: AppleScriptError.scriptMissing("does-not-exist")) {
            try await runner.run(Self.script("does-not-exist"), arguments: [])
        }
    }

    @Test func aMissingOsascriptIsALaunchFailure() async {
        let broken = LiveAppleScriptRunner(scriptsDirectory: Self.fixtures, executable: "/nonexistent/osascript")
        await #expect(throws: AppleScriptError.launchFailed(errno: ENOENT)) {
            try await broken.run(Self.script("echo-args"), arguments: [])
        }
    }

    // MARK: Errors

    @Test(arguments: [
        ("-1743", AppleScriptError.notAuthorized(.notes)),
        ("-1744", AppleScriptError.notAuthorized(.notes)),
        ("-600", AppleScriptError.appUnavailable(.notes)),
        ("-609", AppleScriptError.appUnavailable(.notes)),
        ("-1728", AppleScriptError.notFound),
        ("-1719", AppleScriptError.notFound),
        ("-128", AppleScriptError.userCancelled),
        ("-1712", AppleScriptError.timedOut),
    ])
    func errorNumbersBecomeTypedErrors(number: String, expected: AppleScriptError) async {
        await #expect(throws: expected) {
            try await runner.run(Self.script("fail", app: .notes), arguments: [number, "Nachricht (mit Klammern) (-1)"])
        }
    }

    @Test func otherErrorsKeepTheirNumberAndASingleLineMessage() async {
        await #expect(throws: AppleScriptError.failed(number: 1001, message: "Zeile eins Zeile ‹zwei› (-5)")) {
            try await runner.run(Self.script("fail"), arguments: ["1001", "Zeile eins\nZeile <zwei> (-5)"])
        }
        await #expect(throws: AppleScriptError.failed(number: -2700, message: "ohne Nummer")) {
            try await runner.run(Self.script("fail"), arguments: ["none", "ohne Nummer"])
        }
    }

    @Test func aDeniedAutomationBecomesAPermissionForTheModel() {
        let notes = Self.script("notes-x", app: .notes)
        #expect(AppleScriptError.notAuthorized(.notes).toolError(for: notes) == .permissionDenied(.automationNotes))
        let mail = Self.script("mail-x", app: .mail)
        #expect(AppleScriptError.notAuthorized(nil).toolError(for: mail) == .permissionDenied(.automationMail))
        #expect(AppleScriptError.timedOut.toolError(for: notes) == .timedOut)
        #expect(AppleScriptError.disabled.toolError(for: notes).modelMessage.contains("debug session"))
        if case .failed(let message) = AppleScriptError.failed(number: -10000, message: "Kaputt").toolError(for: notes) {
            #expect(message == "Notes reported an error (-10000): Kaputt")
        } else {
            Issue.record("expected .failed")
        }
    }

    // MARK: Stopping

    /// A copy of the slow fixture under a unique name, so parallel tests can
    /// tell their osascript apart.
    private func uniqueSlowScript() throws -> (runner: LiveAppleScriptRunner, script: AppleScript, folder: URL) {
        let folder = try ClaudeCodeTest.makeDirectory("orbit-scripts")
        let name = "slow-\(UUID().uuidString)"
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("slow.applescript"),
                                         to: folder.appendingPathComponent("\(name).applescript"))
        return (LiveAppleScriptRunner(scriptsDirectory: folder), Self.script(name), folder)
    }

    @Test func aRunLongerThanTheTimeoutIsStopped() async throws {
        let (runner, script, folder) = try uniqueSlowScript()
        defer { ClaudeCodeTest.removeDirectory(folder) }
        var short = script
        short.timeout = .milliseconds(700)
        let started = ContinuousClock.now
        await #expect(throws: AppleScriptError.timedOut) {
            try await runner.run(short, arguments: ["30"])
        }
        #expect(ContinuousClock.now - started < .seconds(6))
        #expect(await LLMTest.eventually(timeout: .seconds(5)) { !Self.osascriptRuns(script: script.name) })
    }

    @Test func cancellingTheTaskStopsOsascript() async throws {
        let (runner, script, folder) = try uniqueSlowScript()
        defer { ClaudeCodeTest.removeDirectory(folder) }
        let task = Task { try await runner.run(script, arguments: ["30"]) }
        #expect(await LLMTest.eventually(timeout: .seconds(5)) { Self.osascriptRuns(script: script.name) })
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await LLMTest.eventually(timeout: .seconds(5)) { !Self.osascriptRuns(script: script.name) })
    }

    @Test func onlyAFewEnvironmentVariablesArePassedOn() {
        let runner = LiveAppleScriptRunner(scriptsDirectory: Self.fixtures,
                                           environment: ["HOME": "/Users/test", "ORBIT_DEBUG_API_KEY": "geheim",
                                                         "LANG": "de_DE.UTF-8", "PATH": "/opt/evil"])
        #expect(runner.environment == ["HOME": "/Users/test", "LANG": "de_DE.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    // MARK: Parsing osascript's errors

    @Test func parsesTheErrorNumberAtTheEnd() {
        let parsed = OsascriptFailure.parse("notes-read.applescript:187:221: execution error: Notes got an error: Can’t get note id \"x (1)\". (-1728)\n")
        #expect(parsed.number == -1728)
        #expect(parsed.message == "Notes got an error: Can’t get note id \"x (1)\".")
        #expect(OsascriptFailure.parse("a.applescript:1:2: syntax error: Expected end of line. (-2741)").number == -2741)
        #expect(OsascriptFailure.parse("something odd (not a number)").number == nil)
        #expect(OsascriptFailure.parse("").number == nil)
    }

    @Test func aChildKilledBySignalWithoutMessageIsAFailure() {
        let error = OsascriptFailure.error(stderr: "", exit: .signaled(SIGSEGV), app: .notes)
        #expect(error == .failed(number: nil, message: "osascript ended unexpectedly"))
    }

    /// Whether an osascript running the script with this (unique) name exists
    /// (pgrep matches process arguments; the scripts are test fixtures).
    static func osascriptRuns(script name: String) -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "osascript .*/\(name)\\.applescript"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
