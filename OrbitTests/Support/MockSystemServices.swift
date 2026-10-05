import Foundation
import os
@testable import Orbit

/// Records what `open_app` and `open_url` would have opened; nothing opens.
/// `failEverything()` makes every call throw.
final class RecordingAppLauncher: AppLaunching, Sendable {
    struct Failure: Error {}

    private let state = OSAllocatedUnfairLock(initialState: (apps: [URL](), links: [URL](), failing: false))

    var openedApps: [URL] { state.withLock { $0.apps } }
    var openedLinks: [URL] { state.withLock { $0.links } }

    func failEverything() {
        state.withLock { $0.failing = true }
    }

    func openApplication(at url: URL) async throws {
        let failing = state.withLock { state in
            if !state.failing { state.apps.append(url) }
            return state.failing
        }
        if failing { throw Failure() }
    }

    func openLink(_ url: URL) async throws {
        let failing = state.withLock { state in
            if !state.failing { state.links.append(url) }
            return state.failing
        }
        if failing { throw Failure() }
    }
}

/// Shortcuts in memory (never /usr/bin/shortcuts). Lists, runs and the
/// inputs of runs are recorded; a run answers from a closure (default: it
/// returns its input as text).
final class MockShortcuts: ShortcutsService, Sendable {
    typealias Runner = @Sendable (ShortcutInfo, String?) throws -> ShortcutOutput

    struct Run: Sendable, Hashable {
        var name: String
        var identifier: String?
        var input: String?
    }

    private struct State: Sendable {
        var shortcuts: [ShortcutInfo]
        var folders: [ShortcutFolder]
        var members: [String: [String]]
        var runs: [Run] = []
        var listings = 0
        var failure: ShortcutsError?
        var runner: Runner
        var holdsRuns = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ shortcuts: [ShortcutInfo] = [], folders: [ShortcutFolder] = [], members: [String: [String]] = [:],
         runner: @escaping Runner = { _, input in input.map { .text($0, isComplete: true) } ?? .none }) {
        state = OSAllocatedUnfairLock(initialState: State(shortcuts: shortcuts, folders: folders, members: members,
                                                          runner: runner))
    }

    var runs: [Run] { state.withLock { $0.runs } }
    /// How often the shortcuts were listed.
    var listings: Int { state.withLock { $0.listings } }

    func fail(with error: ShortcutsError?) {
        state.withLock { $0.failure = error }
    }

    func setShortcuts(_ shortcuts: [ShortcutInfo]) {
        state.withLock { $0.shortcuts = shortcuts }
    }

    /// Runs wait until they are cancelled (to test cancellation).
    func holdRuns() {
        state.withLock { $0.holdsRuns = true }
    }

    func shortcuts(in folder: ShortcutFolder?) async throws -> [ShortcutInfo] {
        try state.withLock { state in
            state.listings += 1
            if let failure = state.failure { throw failure }
            guard let folder else { return state.shortcuts }
            let names = state.members[folder.name] ?? []
            return state.shortcuts.filter { names.contains($0.name) }
        }
    }

    func folders() async throws -> [ShortcutFolder] {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            return state.folders
        }
    }

    func run(_ shortcut: ShortcutInfo, input: String?) async throws -> ShortcutOutput {
        let (runner, holds) = try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.runs.append(Run(name: shortcut.name, identifier: shortcut.identifier, input: input))
            return (state.runner, state.holdsRuns)
        }
        if holds {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            throw CancellationError()
        }
        return try runner(shortcut, input)
    }
}

/// An output device in memory (never Core Audio). Changes are recorded, with
/// the device each was meant for; `switchTo` makes another device the output
/// (headphones plugged in), `appliesChangesLater` reports the old level right
/// after a change (as Core Audio may on Bluetooth, AirPlay and USB devices).
final class MockAudioVolume: AudioVolumeControlling, Sendable {
    struct Change: Sendable, Hashable {
        var volume: Double?
        var muted: Bool?
    }

    private struct State: Sendable {
        var device: AudioOutputDevice
        var changes: [Change] = []
        var targets: [String?] = []
        var reads = 0
        var appliesChangesLater = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ device: AudioOutputDevice = MockAudioVolume.speakers, appliesChangesLater: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(device: device, appliesChangesLater: appliesChangesLater))
    }

    static let speakers = AudioOutputDevice(name: "Test-Lautsprecher", volume: 0.5, isMuted: false, canSetVolume: true, canMute: true,
                                            identifier: "test-speakers")
    static let headphones = AudioOutputDevice(name: "Test-Kopfhörer", volume: 0.3, isMuted: false, canSetVolume: true, canMute: true,
                                              identifier: "test-headphones")
    static let hdmi = AudioOutputDevice(name: "Test-Monitor (HDMI)", volume: nil, isMuted: nil, canSetVolume: false, canMute: false,
                                        identifier: "test-hdmi")

    var changes: [Change] { state.withLock { $0.changes } }
    /// The device each `set` was meant for (`on:`).
    var targets: [String?] { state.withLock { $0.targets } }
    var device: AudioOutputDevice { state.withLock { $0.device } }
    var reads: Int { state.withLock { $0.reads } }

    /// Another device becomes the output device.
    func switchTo(_ device: AudioOutputDevice) {
        state.withLock { $0.device = device }
    }

    func outputDevice() async throws -> AudioOutputDevice {
        state.withLock { state in
            state.reads += 1
            return state.device
        }
    }

    func set(volume: Double?, muted: Bool?, on deviceID: String?) async throws -> AudioOutputDevice {
        try state.withLock { state in
            state.targets.append(deviceID)
            if let deviceID, deviceID != state.device.identifier {
                throw AudioVolumeError.deviceChanged(deviceName: state.device.name)
            }
            if volume != nil, !state.device.canSetVolume {
                throw AudioVolumeError.volumeNotAdjustable(deviceName: state.device.name)
            }
            if muted != nil, !state.device.canMute { throw AudioVolumeError.cannotMute(deviceName: state.device.name) }
            state.changes.append(Change(volume: volume, muted: muted))
            let before = state.device
            if let volume { state.device.volume = volume }
            if let muted { state.device.isMuted = muted }
            return state.appliesChangesLater ? before : state.device
        }
    }
}

/// A frontmost app and its selection the test sets (never NSWorkspace,
/// Accessibility or Finder). Captures are recorded with their options; they
/// can be held to test late results.
final class MockFrontmostContext: FrontmostContextCapturing, Sendable {
    private struct State: Sendable {
        var context: FrontmostContext
        var captures: [FrontmostContextOptions] = []
        var delay: Duration?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ context: FrontmostContext = FrontmostContext(gaps: [.noApp])) {
        state = OSAllocatedUnfairLock(initialState: State(context: context))
    }

    var captures: [FrontmostContextOptions] { state.withLock { $0.captures } }

    func set(_ context: FrontmostContext) {
        state.withLock { $0.context = context }
    }

    /// Every capture takes this long (cancellation ends it early).
    func delay(_ duration: Duration?) {
        state.withLock { $0.delay = duration }
    }

    func capture(_ options: FrontmostContextOptions) async -> FrontmostContext {
        let (context, delay) = state.withLock { state in
            state.captures.append(options)
            return (state.context, state.delay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        return context
    }
}

/// A process runner that runs nothing: records every command line and
/// answers from a closure, which may write the files a real run would leave
/// (e.g. the output of a shortcut).
final class MockProcessRunner: ProcessRunning, Sendable {
    typealias Responder = @Sendable (ChildProcess.Launch) throws -> ChildProcess.Output

    struct Call: Sendable, Hashable {
        var executable: String
        var arguments: [String]
        var workingDirectory: String?
        var timeout: Duration
    }

    private let state: OSAllocatedUnfairLock<(calls: [Call], responder: Responder)>

    init(_ responder: @escaping Responder = { _ in MockProcessRunner.output("") }) {
        state = OSAllocatedUnfairLock(initialState: ([], responder))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func respond(_ responder: @escaping Responder) {
        state.withLock { $0.responder = responder }
    }

    func run(_ launch: ChildProcess.Launch, timeout: Duration, outputLimit: Int) async throws -> ChildProcess.Output {
        let responder = state.withLock { state in
            state.calls.append(Call(executable: launch.executable, arguments: launch.arguments,
                                    workingDirectory: launch.workingDirectory, timeout: timeout))
            return state.responder
        }
        try Task.checkCancellation()
        return try responder(launch)
    }

    static func output(_ stdout: String, stderr: String = "", exit: ChildProcess.Exit = .exited(0)) -> ChildProcess.Output {
        ChildProcess.Output(exit: exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exceededOutputLimit: false)
    }
}

/// The frontmost app a test sets.
struct MockFrontmostApps: FrontmostAppProviding {
    var app: FrontmostApp?

    func frontmostApp() async -> FrontmostApp? { app }
}

/// Accessibility on invented elements (never the AX API): `TestElement`
/// trees per process, and whether secure keyboard entry is on.
final class MockAccessibility: AccessibilityReading, Sendable {
    private let state: OSAllocatedUnfairLock<(elements: [pid_t: TestElement], secureInput: Bool, reads: [pid_t])>

    init(_ elements: [pid_t: TestElement] = [:], secureInput: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: (elements, secureInput, []))
    }

    var reads: [pid_t] { state.withLock { $0.reads } }

    func isSecureInputEnabled() -> Bool {
        state.withLock { $0.secureInput }
    }

    func read<Value: Sendable>(_ processID: pid_t,
                               _ body: @escaping @Sendable (any AccessibilityElement) -> Value) async -> Value? {
        let element = state.withLock { state -> TestElement? in
            state.reads.append(processID)
            return state.elements[processID]
        }
        return element.map(body)
    }
}

/// An invented UI element: attributes, child elements and the requests made
/// of it (the test checks, e.g., that a password field's text was never asked for).
final class TestElement: AccessibilityElement, Sendable {
    private struct State: Sendable {
        var strings: [String: String]
        var children: [String: TestElement]
        var range: NSRange?
        /// The text AXStringForRange answers from (nil: not supported).
        var fullText: String?
        var requests: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ strings: [String: String] = [:], children: [String: TestElement] = [:], selectedRange: NSRange? = nil,
         textForRanges: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(strings: strings, children: children, range: selectedRange,
                                                          fullText: textForRanges))
    }

    /// Every attribute asked for, in order ("AXStringForRange(0,8000)" for the parameterized one).
    var requests: [String] { state.withLock { $0.requests } }

    func string(_ attribute: String) -> String? {
        state.withLock { state in
            state.requests.append(attribute)
            return state.strings[attribute]
        }
    }

    func element(_ attribute: String) -> (any AccessibilityElement)? {
        let child: TestElement? = state.withLock { state in
            state.requests.append(attribute)
            return state.children[attribute]
        }
        return child
    }

    func range(_ attribute: String) -> NSRange? {
        state.withLock { state in
            state.requests.append(attribute)
            return attribute == AXName.selectedTextRange ? state.range : nil
        }
    }

    func string(in range: NSRange) -> String? {
        state.withLock { state in
            state.requests.append("AXStringForRange(\(range.location),\(range.length))")
            guard let text = state.fullText else { return nil }
            let utf16 = text.utf16
            let start = min(range.location, utf16.count)
            let end = min(start + range.length, utf16.count)
            return String(utf16[utf16.index(utf16.startIndex, offsetBy: start)..<utf16.index(utf16.startIndex, offsetBy: end)])
        }
    }

    /// An app whose focused field has `text` selected (all of it), in a window titled `title`.
    static func app(title: String? = "Dokument", selected text: String?, role: String = "AXTextArea",
                    subrole: String? = nil, field: TestElement? = nil) -> TestElement {
        var strings = [AXName.role: role]
        if let subrole { strings[AXName.subrole] = subrole }
        if let text { strings[AXName.selectedText] = text }
        let focused = field ?? TestElement(strings, selectedRange: text.map { NSRange(location: 0, length: $0.utf16.count) },
                                           textForRanges: text)
        var children = [AXName.focusedElement: focused]
        if let title { children[AXName.focusedWindow] = TestElement([AXName.title: title]) }
        return TestElement(children: children)
    }
}
