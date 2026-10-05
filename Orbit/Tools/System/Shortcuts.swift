import AppKit
import UniformTypeIdentifiers

/// One of the user's shortcuts (Shortcuts app).
struct ShortcutInfo: Sendable, Hashable {
    var name: String
    /// The shortcut's identifier (a UUID) when `shortcuts list` gave it; it
    /// is run by it, so exactly the shortcut that was matched runs.
    var identifier: String?
}

/// A folder of the Shortcuts app.
struct ShortcutFolder: Sendable, Hashable {
    var name: String
    var identifier: String?
}

/// What a shortcut returned.
enum ShortcutOutput: Sendable, Hashable {
    /// Nothing.
    case none
    /// Text (at most `ShortcutOutputReader.textReadLimit` bytes were read);
    /// `isComplete` false when there was more.
    case text(String, isComplete: Bool)
    /// Files that are not text (an image, a PDF, …): their types and sizes.
    case files([OutputFile])

    struct OutputFile: Sendable, Hashable {
        /// A Uniform Type Identifier ("public.png"); nil when unknown.
        var typeIdentifier: String?
        var size: Int64
    }
}

enum ShortcutsError: Error, Sendable, Hashable {
    /// Not in this session (a DEBUG session restricted with ORBIT_DEBUG_FILE_SCOPE).
    case unavailable
    /// /usr/bin/shortcuts is missing.
    case notInstalled
    /// The command did not start.
    case launchFailed
    /// It ran longer than its time limit and was stopped.
    case timedOut
    /// It printed more than Orbit reads.
    case outputTooLarge
    /// The input could not be written to its file.
    case inputNotWritten
    /// It ended with an error; `message` is its error output, cut. It may
    /// contain what the shortcut handled: never logged.
    case failed(message: String)

    var logName: String {
        switch self {
        case .unavailable: "unavailable"
        case .notInstalled: "notInstalled"
        case .launchFailed: "launchFailed"
        case .timedOut: "timedOut"
        case .outputTooLarge: "outputTooLarge"
        case .inputNotWritten: "inputNotWritten"
        case .failed: "failed"
        }
    }
}

/// The user's shortcuts: listing them and running one. Live: `LiveShortcuts`
/// (`/usr/bin/shortcuts`); restricted debug sessions have none, the DEBUG
/// fake-data mode answers from invented shortcuts, tests use a mock.
protocol ShortcutsService: Sendable {
    /// The shortcuts: all, or those in `folder`.
    func shortcuts(in folder: ShortcutFolder?) async throws -> [ShortcutInfo]
    func folders() async throws -> [ShortcutFolder]
    /// Runs the shortcut with `input` (text) and returns what it returned.
    /// Cancelling the calling task stops it.
    func run(_ shortcut: ShortcutInfo, input: String?) async throws -> ShortcutOutput
}

/// No shortcuts (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`).
struct UnavailableShortcuts: ShortcutsService {
    func shortcuts(in folder: ShortcutFolder?) async throws -> [ShortcutInfo] { throw ShortcutsError.unavailable }
    func folders() async throws -> [ShortcutFolder] { throw ShortcutsError.unavailable }
    func run(_ shortcut: ShortcutInfo, input: String?) async throws -> ShortcutOutput { throw ShortcutsError.unavailable }
}

/// The Shortcuts app through `/usr/bin/shortcuts`, run as a child process
/// (`ProcessRunning`, own process group): `list` (10 s), `run` (120 s; the
/// input goes in a file readable only by the user in Orbit's data folder,
/// the output into a private folder in the temporary folder; both are
/// deleted afterwards, also when the run fails or is stopped). Cancelling
/// stops the command's process group. Logs record the command, the outcome
/// and the duration, never names, input or output.
struct LiveShortcuts: ShortcutsService {
    static let listTimeout: Duration = .seconds(10)
    static let runTimeout: Duration = .seconds(120)
    /// What `list` may print (thousands of names stay far below).
    static let listOutputLimit = 2 * 1024 * 1024
    /// What `run` may print on stdout (with --output-path it prints nothing).
    static let runOutputLimit = 1024 * 1024
    /// Files left behind by a run that ended abnormally (Orbit quit) are removed after this.
    static let staleAge: TimeInterval = 60 * 60

    let runner: any ProcessRunning
    /// Orbit's folder for input files (`<data folder>/ShortcutInput`, 0700).
    let inputDirectory: URL
    /// Where each run gets its private output folder (the temporary folder).
    let outputParent: URL
    var environment: [String: String] = ChildEnvironment.minimal()

    init(runner: any ProcessRunning = LiveProcessRunner(),
         inputDirectory: URL = AppPaths.applicationSupport.appendingPathComponent("ShortcutInput", isDirectory: true),
         outputParent: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
         environment: [String: String] = ChildEnvironment.minimal()) {
        self.runner = runner
        self.inputDirectory = inputDirectory
        self.outputParent = outputParent
        self.environment = environment
    }

    func shortcuts(in folder: ShortcutFolder?) async throws -> [ShortcutInfo] {
        let output = try await list(ShortcutsCommand.list(folder: folder))
        return ShortcutsCommand.parseList(output).map { ShortcutInfo(name: $0.name, identifier: $0.identifier) }
    }

    func folders() async throws -> [ShortcutFolder] {
        let output = try await list(ShortcutsCommand.folders())
        return ShortcutsCommand.parseList(output).map { ShortcutFolder(name: $0.name, identifier: $0.identifier) }
    }

    private func list(_ arguments: [String]) async throws -> String {
        let output = try await execute(arguments, timeout: Self.listTimeout, outputLimit: Self.listOutputLimit,
                                       workingDirectory: "/", what: "list")
        return String(decoding: output.stdout, as: UTF8.self)
    }

    func run(_ shortcut: ShortcutInfo, input: String?) async throws -> ShortcutOutput {
        let id = UUID().uuidString
        Self.removeStale(in: inputDirectory, prefix: "", olderThan: Self.staleAge)
        Self.removeStale(in: outputParent, prefix: "orbit-shortcut-", olderThan: Self.staleAge)
        var inputFile: URL?
        let runDirectory = outputParent.appendingPathComponent("orbit-shortcut-\(id)", isDirectory: true)
        defer {
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
            try? FileManager.default.removeItem(at: runDirectory)
        }
        do {
            if let input {
                try PrivateFile.prepareDirectory(inputDirectory)
                let file = inputDirectory.appendingPathComponent("\(id).txt")
                inputFile = file
                try PrivateFile.create(at: file, contents: Data(input.utf8))
            }
            try PrivateFile.prepareDirectory(runDirectory)
        } catch {
            Log.tools.error("Shortcuts: the input or output folder could not be prepared")
            throw ShortcutsError.inputNotWritten
        }
        let outputFile = runDirectory.appendingPathComponent("output")
        let arguments = ShortcutsCommand.run(shortcut, inputPath: inputFile?.path, outputPath: outputFile.path)
        let output = try await execute(arguments, timeout: Self.runTimeout, outputLimit: Self.runOutputLimit,
                                       workingDirectory: runDirectory.path, what: "run")
        return ShortcutOutputReader.read(directory: runDirectory, stdout: output.stdout)
    }

    /// Runs `/usr/bin/shortcuts` with `arguments`; a failure becomes a `ShortcutsError`.
    private func execute(_ arguments: [String], timeout: Duration, outputLimit: Int, workingDirectory: String,
                         what: String) async throws -> ChildProcess.Output {
        let launch = ChildProcess.Launch(executable: ShortcutsCommand.executable, arguments: arguments,
                                         environment: environment, workingDirectory: workingDirectory)
        let start = ContinuousClock.now
        func finish(_ outcome: String) {
            let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
            Log.tools.info("shortcuts \(what, privacy: .public): \(outcome, privacy: .public) after \(milliseconds) ms")
        }
        let output: ChildProcess.Output
        do {
            output = try await runner.run(launch, timeout: timeout, outputLimit: outputLimit)
        } catch ChildProcess.RunFailure.timedOut {
            finish("timed out, stopped")
            throw ShortcutsError.timedOut
        } catch ChildProcess.Failure.spawnFailed(let code) {
            finish("did not start (\(code))")
            throw code == ENOENT ? ShortcutsError.notInstalled : ShortcutsError.launchFailed
        } catch ChildProcess.Failure.pipeFailed {
            finish("no pipe")
            throw ShortcutsError.launchFailed
        } catch is CancellationError {
            finish("cancelled, stopped")
            throw CancellationError()
        }
        if output.exceededOutputLimit {
            finish("too much output, stopped")
            throw ShortcutsError.outputTooLarge
        }
        guard output.exit == .exited(0) else {
            finish("failed (\(output.exit))")
            throw ShortcutsError.failed(message: ShortcutsCommand.errorMessage(output.stderr))
        }
        finish("ok, \(output.stdout.count) bytes")
        return output
    }

    /// Removes leftovers of runs that ended abnormally (best effort).
    static func removeStale(in directory: URL, prefix: String, olderThan age: TimeInterval, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            guard prefix.isEmpty || entry.lastPathComponent.count > prefix.count,
                  let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}

/// The command lines of `/usr/bin/shortcuts` and how its answers read (pure).
///
/// `shortcuts list --show-identifiers` prints one shortcut per line as
/// "Name (UUID)"; a line without an identifier counts as a name. A shortcut is
/// run by its identifier when there is one, because a name could start with "-" and
/// read as an option, so a name gets "--" before it.
enum ShortcutsCommand {
    static let executable = "/usr/bin/shortcuts"

    static func list(folder: ShortcutFolder?) -> [String] {
        var arguments = ["list", "--show-identifiers"]
        if let folder {
            let value = folder.identifier ?? folder.name
            // A name that starts with "-" would read as an option: "--folder-name=…" keeps it the value.
            arguments += value.hasPrefix("-") ? ["--folder-name=" + value] : ["--folder-name", value]
        }
        return arguments
    }

    static func folders() -> [String] {
        ["list", "--folders", "--show-identifiers"]
    }

    static func run(_ shortcut: ShortcutInfo, inputPath: String?, outputPath: String) -> [String] {
        var arguments = ["run"]
        if let inputPath { arguments += ["--input-path", inputPath] }
        arguments += ["--output-path", outputPath]
        let target = shortcut.identifier ?? shortcut.name
        if target.hasPrefix("-") { arguments.append("--") }
        arguments.append(target)
        return arguments
    }

    /// "Name (UUID)" lines → names with identifiers; empty lines are skipped.
    static func parseList(_ output: String) -> [(name: String, identifier: String?)] {
        let identifiedLine = /^(.*) \(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)$/
        return output.split(whereSeparator: \.isNewline).compactMap { line -> (name: String, identifier: String?)? in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if let match = text.firstMatch(of: identifiedLine) {
                let name = String(match.1).trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? text : name, String(match.2))
            }
            return (text, nil)
        }
    }

    /// The error output of a failed run, on one line and cut (data for the
    /// model, never logged).
    static func errorMessage(_ stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Truncation.prefix(lines.joined(separator: " "), maxCharacters: 500)
    }
}

/// Reads what a run left in its output folder (pure apart from reading those
/// files): text (plain or rich text, read up to `textReadLimit`) or a
/// description of other files (type and size). What the command printed
/// counts as text when the folder is empty.
enum ShortcutOutputReader {
    static let textReadLimit = 1024 * 1024
    /// Files described at most.
    static let maxFiles = 5

    static func read(directory: URL, stdout: Data) -> ShortcutOutput {
        let manager = FileManager.default
        let entries = ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                                         options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !entries.isEmpty else {
            let text = decodedText(stdout)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? .none : .text(text, isComplete: true)
        }
        if entries.count == 1, let file = entries.first, !isDirectory(file),
           let (text, isComplete) = readText(file) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(text, isComplete: isComplete)
        }
        return .files(entries.prefix(maxFiles).map(describe))
    }

    /// The file's text when it is text (UTF-8 or RTF), else nil.
    static func readText(_ file: URL) -> (String, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: textReadLimit + 1) else { return nil }
        let isComplete = data.count <= textReadLimit
        let bytes = data.prefix(textReadLimit)
        if bytes.starts(with: Data("{\\rtf".utf8)) {
            guard isComplete, let text = rtfText(Data(bytes)) else { return nil }
            return (text, true)
        }
        guard let text = decodedText(Data(bytes), allowingCutCharacter: !isComplete) else { return nil }
        return (text, isComplete)
    }

    /// UTF-8 text without NUL bytes, else nil. A read that stopped inside a
    /// character may end with an incomplete one: it is dropped.
    static func decodedText(_ data: Data, allowingCutCharacter: Bool = false) -> String? {
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        guard allowingCutCharacter else { return nil }
        for drop in 1...3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    static func rtfText(_ data: Data) -> String? {
        try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                documentAttributes: nil).string
    }

    static func describe(_ file: URL) -> ShortcutOutput.OutputFile {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let size = Int64(values?.fileSize ?? 0)
        if values?.isDirectory == true { return .init(typeIdentifier: UTType.folder.identifier, size: size) }
        let byExtension = file.pathExtension.isEmpty ? nil : UTType(filenameExtension: file.pathExtension)
        return .init(typeIdentifier: (byExtension ?? sniffedType(file))?.identifier, size: size)
    }

    /// The type of a file without extension, by its first bytes.
    static func sniffedType(_ file: URL) -> UTType? {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 16) else { return nil }
        try? handle.close()
        return sniffedType(head)
    }

    static func sniffedType(_ head: Data) -> UTType? {
        let bytes = [UInt8](head)
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<(offset + prefix.count)]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(Array("GIF8".utf8)) { return .gif }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if starts(Array("ftypheic".utf8), at: 4) || starts(Array("ftypheix".utf8), at: 4) || starts(Array("ftypmif1".utf8), at: 4) {
            return .heic
        }
        if starts(Array("ftyp".utf8), at: 4) { return .mpeg4Movie }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
