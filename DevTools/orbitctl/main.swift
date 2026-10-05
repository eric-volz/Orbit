// orbitctl drives a running DEBUG build of Orbit (see Orbit/App/DebugAutomation.swift).
//
//   orbitctl [--bundle-id io.github.eric-volz.Orbit] [--data-dir DIR] [--timeout 30] <command> [argument…]
//
// Orbit must run with ORBIT_DEBUG_AUTOMATION=1. orbitctl reads the per-launch token
// from `<data dir>/Automation/token` (data dir: --data-dir, else ORBIT_DATA_DIR, else
// ~/Library/Application Support/Orbit), posts `<bundle-id>.debug.command` with it and a
// fresh reply id, waits for `<bundle-id>.debug.reply` and prints the reply file's JSON.
// Exit status: 0 ok, 1 error reply or timeout, 64 usage error.
//
// Examples:
//   orbitctl show
//   orbitctl type "Hallo Welt"
//   orbitctl key cmd-n
//   orbitctl snapshot /tmp/panel.png
//   orbitctl --timeout 180 wait-idle 120
import Foundation

let usage = """
    usage: orbitctl [--bundle-id ID] [--data-dir DIR] [--timeout SECONDS] <command> [argument…]

    commands: show, hide, toggle, type <text>, submit [text], key <spec>, new-chat,
              open-settings, close-settings, open-onboarding [step|new-permissions], close-onboarding, state,
              snapshot <png>, snapshot-window <png>, snapshot-settings <png>,
              snapshot-onboarding <png>, wait-idle <seconds>, fake-frontmost [scene], quit, help
    onboarding steps: welcome, provider, hotkey, done, or a permission (automationMail, calendars, …);
                      new-permissions: only the steps an existing user sees once after an update
    fake-frontmost:   with ORBIT_DEBUG_FAKE_PERSONAL_DATA, lists the invented frontmost apps (frontmost.json)
                      or switches to one; show/toggle then capture its selection as context chips
    key specs: escape, return, tab, space, up, down, left, right, delete, a to z, 0 to 9, comma, …
               with optional cmd-/shift-/opt-/ctrl- prefixes (cmd-n, cmd-return, cmd-shift-z)
    """

struct Options {
    var bundleID = "io.github.eric-volz.Orbit"
    var dataDirectory = ProcessInfo.processInfo.environment["ORBIT_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSHomeDirectory() + "/Library/Application Support/Orbit"
    var timeout: TimeInterval = 30
    var command = ""
    var argument: String?

    var channelDirectory: URL {
        URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent("Automation", isDirectory: true)
    }
}

enum ParseResult {
    case run(Options)
    case help
    case failure(String)
}

func parse(_ arguments: [String]) -> ParseResult {
    var options = Options()
    var remaining = arguments[...]
    // Options come before the command; everything after the command is its argument.
    optionLoop: while let first = remaining.first, first.hasPrefix("-") {
        remaining.removeFirst()
        switch first {
        case "--":
            break optionLoop
        case "-h", "--help":
            return .help
        case "--bundle-id":
            guard let value = remaining.popFirst(), !value.isEmpty else { return .failure("--bundle-id needs a value") }
            options.bundleID = value
        case "--data-dir":
            guard let value = remaining.popFirst(), !value.isEmpty else { return .failure("--data-dir needs a value") }
            options.dataDirectory = value
        case "--timeout":
            guard let value = remaining.popFirst(), let seconds = TimeInterval(value), seconds > 0 else {
                return .failure("--timeout needs a positive number of seconds")
            }
            options.timeout = seconds
        default:
            return .failure("unknown option \(first)")
        }
    }
    guard let command = remaining.popFirst() else { return .failure("missing command") }
    options.command = command
    if !remaining.isEmpty {
        options.argument = remaining.joined(separator: " ")
    }
    // The app runs in another working directory: make snapshot paths absolute.
    if command.hasPrefix("snapshot"), let path = options.argument, !path.hasPrefix("/") {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        options.argument = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }
    // wait-idle replies only after the app-side wait (30 s by default); allow for it.
    if command == "wait-idle" {
        if options.argument == nil { options.argument = "30" }
        if let seconds = options.argument.flatMap(TimeInterval.init) {
            options.timeout = max(options.timeout, seconds + 5)
        }
    }
    return .run(options)
}

/// Collects the reply with our id. Distributed notifications arrive on the main run loop.
final class ReplyListener: NSObject {
    let replyID: String
    private(set) var ok = false
    private(set) var received = false

    init(replyID: String) {
        self.replyID = replyID
    }

    @objc func receive(_ notification: Notification) {
        guard let info = notification.userInfo, info["replyID"] as? String == replyID else { return }
        ok = info["ok"] as? Bool ?? false
        received = true
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("orbitctl: \(message)\n".utf8))
}

let options: Options
switch parse(Array(CommandLine.arguments.dropFirst())) {
case .run(let parsed):
    options = parsed
case .help:
    print(usage)
    exit(0)
case .failure(let message):
    printError(message)
    printError(usage)
    exit(64)
}

let tokenURL = options.channelDirectory.appendingPathComponent("token")
guard let token = try? String(contentsOf: tokenURL, encoding: .utf8), !token.isEmpty else {
    printError("no token at \(tokenURL.path); start a DEBUG build of Orbit with ORBIT_DEBUG_AUTOMATION=1 "
        + "(and the same ORBIT_DATA_DIR, or pass --data-dir)")
    exit(1)
}

let center = DistributedNotificationCenter.default()
let listener = ReplyListener(replyID: UUID().uuidString.lowercased())
// Observe before posting so a fast reply is not missed.
center.addObserver(listener, selector: #selector(ReplyListener.receive(_:)),
                   name: Notification.Name("\(options.bundleID).debug.reply"), object: nil)

var userInfo: [String: String] = ["command": options.command, "replyID": listener.replyID, "token": token]
userInfo["argument"] = options.argument
center.postNotificationName(Notification.Name("\(options.bundleID).debug.command"), object: nil,
                            userInfo: userInfo, deliverImmediately: true)

let deadline = Date(timeIntervalSinceNow: options.timeout)
while !listener.received, Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.25)))
}
center.removeObserver(listener)

guard listener.received else {
    printError("no reply from \(options.bundleID) within \(Int(options.timeout)) s; is a DEBUG build of Orbit running "
        + "with ORBIT_DEBUG_AUTOMATION=1 and this data folder?")
    exit(1)
}
let replyURL = options.channelDirectory.appendingPathComponent("reply-\(listener.replyID).json")
guard let payload = try? String(contentsOf: replyURL, encoding: .utf8) else {
    printError("the reply file \(replyURL.path) could not be read")
    exit(1)
}
try? FileManager.default.removeItem(at: replyURL)
print(payload)
exit(listener.ok ? 0 : 1)
