import Foundation
import os

/// An app Orbit controls with AppleScript.
enum ScriptedApp: String, Sendable, Hashable, CaseIterable {
    case notes
    case mail
    case photos
    /// The Finder selection for the context of a request.
    case finder
    /// The appearance (dark mode).
    case systemEvents

    /// The automation permission macOS asks the user for.
    var permission: PermissionKind {
        switch self {
        case .notes: .automationNotes
        case .mail: .automationMail
        case .photos: .automationPhotos
        case .finder: .automationFinder
        case .systemEvents: .automationSystemEvents
        }
    }

    /// The app's name for the model (and in the scripts' `tell application`).
    var name: String {
        switch self {
        case .notes: "Notes"
        case .mail: "Mail"
        case .photos: "Photos"
        case .finder: "Finder"
        case .systemEvents: "System Events"
        }
    }
}

/// One of Orbit's AppleScripts, `Orbit/Resources/AppleScripts/<name>.applescript`
/// (copied into the app by Scripts/build-app.sh).
///
/// Every script takes its parameters only as the items of `argv` (`on run argv`):
/// user or model text is never spliced into script source, so it stays data:
/// an argument like `a"; do shell script "…` is just text. Scripts print JSON;
/// each script's header comment documents its arguments and output.
struct AppleScript: Sendable, Hashable, CustomStringConvertible {
    /// The file name without ".applescript", e.g. "notes-search".
    var name: String
    /// The app the script sends Apple Events to, if any.
    var app: ScriptedApp?
    /// How long one run may take before osascript is stopped (below the agent
    /// loop's 90-second deadline, so the tool can still answer).
    var timeout: Duration

    var description: String { name }

    /// Every script Orbit ships. Tests check that each has its file in
    /// Resources/AppleScripts, that no other file is there, and compile them all.
    static var bundled: [AppleScript] {
        NotesService.scripts + MailService.scripts + PhotosService.scripts + FinderService.scripts
            + SystemEventsService.scripts
    }
}

/// Why running a script failed. Errors never carry script arguments; only
/// `failed` keeps the script's error message (for the model, never logged).
enum AppleScriptError: Error, Sendable, Hashable {
    /// macOS did not let Orbit control the app (-1743), or would have to ask
    /// the user first (-1744).
    case notAuthorized(ScriptedApp?)
    /// The app is not running and could not be started, or quit meanwhile (-600, -609).
    case appUnavailable(ScriptedApp?)
    /// What the script asked the app for does not exist (-1728, -1719).
    case notFound
    /// The user cancelled a dialog (-128).
    case userCancelled
    /// The run took longer than the script's timeout (osascript was stopped),
    /// or an Apple Event timed out (-1712).
    case timedOut
    /// The script printed more than Orbit accepts; osascript was stopped.
    case outputTooLarge
    /// The arguments are larger than osascript can be given.
    case argumentsTooLarge
    /// An argument contains a NUL character, which cannot be passed on.
    case invalidArgument
    /// The script file is not in Orbit's resources.
    case scriptMissing(String)
    /// osascript could not be started.
    case launchFailed(errno: Int32)
    /// Scripts cannot run in this session (a DEBUG session restricted with
    /// ORBIT_DEBUG_FILE_SCOPE but without fake personal data).
    case disabled
    /// The script failed with another error: its number (if any) and message.
    case failed(number: Int?, message: String)
    /// The script's output is not what Orbit expected.
    case invalidOutput

    /// A name for logs (no messages: they may echo user content).
    var logName: String {
        switch self {
        case .notAuthorized: "notAuthorized"
        case .appUnavailable: "appUnavailable"
        case .notFound: "notFound"
        case .userCancelled: "userCancelled"
        case .timedOut: "timedOut"
        case .outputTooLarge: "outputTooLarge"
        case .argumentsTooLarge: "argumentsTooLarge"
        case .invalidArgument: "invalidArgument"
        case .scriptMissing: "scriptMissing"
        case .launchFailed(let code): "launchFailed(\(code))"
        case .disabled: "disabled"
        case .failed(let number, _): "failed(\(number.map(String.init) ?? "-"))"
        case .invalidOutput: "invalidOutput"
        }
    }

    /// The error a tool reports for a failed run of `script` (English, for
    /// the model). Denied automation becomes `permissionDenied`, so the agent
    /// tells the user where to grant it.
    func toolError(for script: AppleScript) -> ToolError {
        let app = script.app?.name ?? "the app"
        switch self {
        case .notAuthorized(let scriptedApp):
            guard let permission = (scriptedApp ?? script.app)?.permission else {
                return .failed("macOS did not allow Orbit to control \(app).")
            }
            return .permissionDenied(permission)
        case .appUnavailable:
            return .failed("\(app) is not running and could not be started, or it quit. Ask the user to open \(app) and try again.")
        case .notFound:
            return .notFound("The item does not exist (anymore) in \(app).")
        case .userCancelled:
            return .failed("The action was cancelled in \(app).")
        case .timedOut:
            return .timedOut
        case .outputTooLarge:
            return .failed("\(app) returned more data than Orbit accepts. Narrow the request.")
        case .argumentsTooLarge:
            return .invalidArgument("The text is too long to pass to \(app).")
        case .invalidArgument:
            return .invalidArgument("The text contains a NUL character, which cannot be passed to \(app).")
        case .scriptMissing:
            return .failed("Orbit's script for \(app) is missing; Orbit may need to be reinstalled.")
        case .launchFailed:
            return .failed("Orbit could not start osascript to talk to \(app).")
        case .disabled:
            return .unavailable("\(app) is not available in this debug session (ORBIT_DEBUG_FILE_SCOPE is set without ORBIT_DEBUG_FAKE_PERSONAL_DATA).")
        case .failed(let number, let message):
            let code = number.map { " (\($0))" } ?? ""
            let detail = message.isEmpty ? "" : ": \(message)"
            return .failed("\(app) reported an error\(code)\(detail)")
        case .invalidOutput:
            return .failed("Orbit could not read \(app)'s answer.")
        }
    }
}

/// Runs Orbit's AppleScripts. Live: `LiveAppleScriptRunner` (osascript in its
/// own process); tests use a mock; the DEBUG fake-data mode answers from
/// invented data.
protocol AppleScriptRunning: Sendable {
    /// Runs `script` with `arguments` as the items of its `argv` and returns
    /// what it printed (its result) without the final line break. Throws
    /// `AppleScriptError`, or `CancellationError` when the calling task is
    /// cancelled (osascript is stopped then).
    func run(_ script: AppleScript, arguments: [String]) async throws -> String
}

extension AppleScriptRunning {
    /// Runs `script` and decodes the JSON it printed. Output that is not the
    /// expected JSON throws `AppleScriptError.invalidOutput`.
    func runJSON<Value: Decodable>(_ script: AppleScript, arguments: [String],
                                   as type: Value.Type = Value.self) async throws -> Value {
        let output = try await run(script, arguments: arguments)
        do {
            return try JSONDecoder().decode(Value.self, from: Data(output.utf8))
        } catch {
            Log.tools.error("AppleScript \(script.name, privacy: .public) printed output that is not the expected JSON")
            throw AppleScriptError.invalidOutput
        }
    }
}

/// Runs scripts with `/usr/bin/osascript` in a child process (never in
/// Orbit's process, never on the main thread): own process group, stdin from
/// /dev/null, a timeout and cancellation that stop osascript, an output limit,
/// and osascript's error messages turned into `AppleScriptError`. Nothing of
/// the arguments or the output is logged, only the script name, the outcome
/// and the duration.
struct LiveAppleScriptRunner: AppleScriptRunning {
    static let osascript = "/usr/bin/osascript"
    /// Largest output accepted (a note body or a mail with headers stays far below).
    static let defaultOutputLimit = 8 * 1024 * 1024
    /// Largest total size of the arguments. ARG_MAX (1 MiB) covers arguments and
    /// environment together; this leaves ample room.
    static let maxArgumentBytes = 512 * 1024
    /// The environment variables osascript gets from Orbit's environment.
    static let passedEnvironment = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                                    "__CF_USER_TEXT_ENCODING"]

    /// Where the scripts are: `Orbit.app/Contents/Resources/AppleScripts`.
    static var bundledScripts: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("AppleScripts", isDirectory: true)
    }

    let scriptsDirectory: URL
    var outputLimit: Int
    var executable: String
    var environment: [String: String]

    init(scriptsDirectory: URL = Self.bundledScripts, outputLimit: Int = Self.defaultOutputLimit,
         executable: String = Self.osascript, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.scriptsDirectory = scriptsDirectory
        self.outputLimit = outputLimit
        self.executable = executable
        var passed = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in Self.passedEnvironment {
            if let value = environment[name] { passed[name] = value }
        }
        self.environment = passed
    }

    /// The source file of `script`.
    func url(of script: AppleScript) -> URL {
        scriptsDirectory.appendingPathComponent(script.name).appendingPathExtension("applescript")
    }

    func run(_ script: AppleScript, arguments: [String]) async throws -> String {
        try Self.validate(arguments)
        let file = url(of: script)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            Log.tools.error("AppleScript \(script.name, privacy: .public) is missing from the resources")
            throw AppleScriptError.scriptMissing(script.name)
        }
        let launch = ChildProcess.Launch(executable: executable, arguments: [file.path] + arguments,
                                         environment: environment, workingDirectory: "/")
        let start = ContinuousClock.now
        func finish(_ outcome: String) {
            let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
            Log.tools.info("AppleScript \(script.name, privacy: .public): \(outcome, privacy: .public) after \(milliseconds) ms")
        }
        let output: ChildProcess.Output
        do {
            output = try await ChildProcess.run(launch, timeout: script.timeout, outputLimit: outputLimit)
        } catch ChildProcess.RunFailure.timedOut {
            finish("timed out, stopped")
            throw AppleScriptError.timedOut
        } catch ChildProcess.Failure.spawnFailed(let code) {
            finish("osascript did not start")
            throw AppleScriptError.launchFailed(errno: code)
        } catch ChildProcess.Failure.pipeFailed(let code) {
            finish("no pipe")
            throw AppleScriptError.launchFailed(errno: code)
        } catch is CancellationError {
            finish("cancelled, stopped")
            throw CancellationError()
        }
        if output.exceededOutputLimit {
            finish("too much output, stopped")
            throw AppleScriptError.outputTooLarge
        }
        guard output.exit == .exited(0) else {
            let error = OsascriptFailure.error(stderr: String(decoding: output.stderr, as: UTF8.self),
                                               exit: output.exit, app: script.app)
            finish("failed (\(error.logName))")
            throw error
        }
        finish("ok, \(output.stdout.count) bytes")
        return Self.result(from: output.stdout)
    }

    /// The printed result without the line break osascript adds.
    static func result(from stdout: Data) -> String {
        var text = String(decoding: stdout, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Arguments become C strings: no NUL characters, and not more than
    /// `maxArgumentBytes` in total.
    static func validate(_ arguments: [String]) throws {
        var bytes = 0
        for argument in arguments {
            if argument.utf8.contains(0) { throw AppleScriptError.invalidArgument }
            bytes += argument.utf8.count + 1
        }
        if bytes > maxArgumentBytes { throw AppleScriptError.argumentsTooLarge }
    }
}

/// Reads osascript's error output, e.g.
/// `notes-read.applescript:187:221: execution error: Notes got an error: Can’t get note id "…". (-1728)`
/// The number in the last parentheses is the OSStatus. The message may span
/// lines and contain parentheses itself.
enum OsascriptFailure {
    /// The error for a failed run.
    static func error(stderr: String, exit: ChildProcess.Exit, app: ScriptedApp?) -> AppleScriptError {
        let (number, message) = parse(stderr)
        if number == nil, case .signaled = exit {
            return .failed(number: nil, message: "osascript ended unexpectedly")
        }
        return error(number: number, message: message, app: app)
    }

    static func error(number: Int?, message: String, app: ScriptedApp?) -> AppleScriptError {
        switch number {
        case -1743, -1744: .notAuthorized(app)
        case -600, -609: .appUnavailable(app)
        case -1728, -1719: .notFound
        case -128: .userCancelled
        case -1712: .timedOut
        default: .failed(number: number, message: TurnContext.inline(message, maxCharacters: 300))
        }
    }

    /// The error number and the message (without the file position and the number).
    static func parse(_ stderr: String) -> (number: Int?, message: String) {
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var number: Int?
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let digits = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if let value = Int(digits), !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "-" }) {
                number = value
                text = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for marker in [": execution error: ", ": syntax error: "] {
            if let range = text.range(of: marker) {
                text = String(text[range.upperBound...])
                break
            }
        }
        return (number, text)
    }
}

/// Refuses every script (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE
/// but without fake personal data, because they must not reach Mail or Notes).
struct DisabledAppleScriptRunner: AppleScriptRunning {
    func run(_ script: AppleScript, arguments: [String]) async throws -> String {
        throw AppleScriptError.disabled
    }
}
