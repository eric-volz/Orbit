#if DEBUG
import Foundation
import os

/// DEBUG only: an invented Mac for the app and system tools and the context
/// capture in the fake-data mode (`FakePersonalData`,
/// ORBIT_DEBUG_FAKE_PERSONAL_DATA): the user's shortcuts (`shortcuts.json`),
/// the app in front and what is selected there (`frontmost.json`), the
/// appearance and an output device (`system.json`). Nothing of the Mac is
/// reached: no shortcut runs, no app or link opens, no setting changes, no
/// other app is read; what Orbit did is recorded for `orbitctl state`. The
/// context capture itself is the real one (`FrontmostContextCapture`) on
/// invented parts, so its rules (password fields, Finder items Orbit never
/// shares, missing permissions) apply as on a real Mac.
///
/// `shortcuts.json` (every key optional):
/// `{"shortcuts": [{"name": "Wetter heute", "folder": "Alltag", "output": "Sonnig, 21 °C",
///   "outputType": "text" | "image" | "none", "failure": "…"}]}`; without `output` a run returns its
///   input (an echo); `failure` makes it fail with that message; `"image"` returns an invented PNG file.
///
/// `frontmost.json` (every key optional):
/// `{"accessibility": "granted" | "denied", "finderAutomation": "granted" | "denied" | "notDetermined",
///   "scene": "finder", "scenes": [{"name": "finder", "app": "Finder", "bundleID": "com.apple.finder",
///   "windowTitle": "Rechnungen", "selectedText": "…", "secureField": false,
///   "finderSelection": ["../Files/Rechnungen/Rechnung-Telekom-2026-08.pdf"]}]}`; paths relative to
///   the fake-data folder or absolute; `orbitctl fake-frontmost <scene>` switches the scene.
///
/// `system.json` (every key optional): `{"appearance": "light" | "dark", "automation": "granted" | "denied",
///   "volume": {"device": "Orbit-Testlautsprecher", "level": 50, "muted": false, "adjustable": true,
///   "canMute": true}}`.
final class FakeSystemData: Sendable {
    static let shortcutsFile = "shortcuts.json"
    static let frontmostFile = "frontmost.json"
    static let systemFile = "system.json"
    /// Records kept per kind for `orbitctl state`.
    static let maxRecords = 100
    /// Process identifiers of invented apps (above any real one).
    static let firstProcessID: pid_t = 900_000
    /// The invented output device's identifier.
    static let outputDeviceID = "orbit-fake-output"

    struct Shortcut: Sendable, Hashable {
        var info: ShortcutInfo
        var folder: String?
        var output: String?
        var outputType: String?
        var failure: String?
    }

    struct Scene: Sendable, Hashable {
        var name: String
        var app: FrontmostApp
        var windowTitle: String?
        var selectedText: String?
        var secureField: Bool
        /// Absolute paths.
        var finderSelection: [String]
    }

    private struct State: Sendable {
        var scene: String?
        var finderAutomation: PermissionStatus
        var isDark: Bool
        var device: AudioOutputDevice
        var shortcutRuns: [JSONValue] = []
        var openedApps: [String] = []
        var openedLinks: [String] = []
        var appearanceChanges: [String] = []
        var volumeChanges: [JSONValue] = []
        var contextCaptures: [JSONValue] = []
    }

    let shortcuts: [Shortcut]
    let folders: [String]
    let scenes: [Scene]
    let accessibility: PermissionStatus
    let systemEventsAutomation: PermissionStatus
    private let state: OSAllocatedUnfairLock<State>

    init(folder: URL?, errors: inout [String]) {
        let shortcutsFile = folder.flatMap { Self.decode(ShortcutsFile.self, $0.appendingPathComponent(Self.shortcutsFile), errors: &errors) }
            ?? ShortcutsFile()
        var shortcuts: [Shortcut] = []
        for (index, entry) in (shortcutsFile.shortcuts ?? []).enumerated() {
            let name = NoteText.singleLine(entry.name)
            guard !name.isEmpty else {
                errors.append("A shortcut in \(Self.shortcutsFile) has no name.")
                continue
            }
            let identifier = String(format: "0F000000-0000-4000-8000-%012d", index + 1)
            shortcuts.append(Shortcut(info: ShortcutInfo(name: name, identifier: identifier), folder: entry.folder,
                                      output: entry.output, outputType: entry.outputType?.lowercased(), failure: entry.failure))
        }
        self.shortcuts = shortcuts
        var folders = shortcutsFile.folders ?? []
        for name in shortcuts.compactMap(\.folder) where !folders.contains(name) {
            folders.append(name)
        }
        self.folders = folders

        let frontmost = folder.flatMap { Self.decode(FrontmostFile.self, $0.appendingPathComponent(Self.frontmostFile), errors: &errors) }
            ?? FrontmostFile()
        scenes = (frontmost.scenes ?? []).enumerated().map { index, entry in
            Scene(name: entry.name,
                  app: FrontmostApp(name: entry.app, bundleID: entry.bundleID, processID: Self.firstProcessID + pid_t(index)),
                  windowTitle: entry.windowTitle, selectedText: entry.selectedText, secureField: entry.secureField ?? false,
                  finderSelection: (entry.finderSelection ?? []).map { Self.absolute($0, in: folder) })
        }
        accessibility = Self.status(frontmost.accessibility, errors: &errors)
        let system = folder.flatMap { Self.decode(SystemFile.self, $0.appendingPathComponent(Self.systemFile), errors: &errors) }
            ?? SystemFile()
        systemEventsAutomation = Self.status(system.automation, errors: &errors)
        let volume = system.volume
        let device = AudioOutputDevice(name: volume?.device ?? "Orbit-Testlautsprecher",
                                       volume: AudioVolumeLevel.scalar(fromPercent: volume?.level ?? 50),
                                       isMuted: (volume?.canMute ?? true) ? (volume?.muted ?? false) : nil,
                                       canSetVolume: volume?.adjustable ?? true, canMute: volume?.canMute ?? true,
                                       identifier: Self.outputDeviceID)
        let scene = frontmost.scene ?? scenes.first?.name
        if let scene, !scenes.contains(where: { $0.name == scene }) {
            errors.append("\(Self.frontmostFile): there is no scene named '\(scene)'.")
        }
        state = OSAllocatedUnfairLock(initialState: State(
            scene: scene, finderAutomation: Self.status(frontmost.finderAutomation, errors: &errors),
            isDark: system.appearance?.lowercased() == "dark", device: device))
    }

    // MARK: Frontmost app

    var currentScene: Scene? {
        let name = state.withLock { $0.scene }
        return scenes.first { $0.name == name }
    }

    /// `orbitctl fake-frontmost`: switches to the scene `name` (nil: none
    /// switched) and reports the scenes.
    func selectScene(_ name: String?) -> JSONValue {
        if let name {
            guard scenes.contains(where: { $0.name == name }) else {
                return ["error": .string("No scene '\(name)'. Scenes: \(scenes.map(\.name).joined(separator: ", "))")]
            }
            state.withLock { $0.scene = name }
        }
        return ["scene": currentScene.map { .string($0.name) } ?? .null, "scenes": .array(scenes.map { .string($0.name) })]
    }

    var finderAutomation: PermissionStatus {
        state.withLock { $0.finderAutomation }
    }

    /// "Allow…" for Automation: Finder: the fake user agrees while undecided.
    func requestFinderAutomation() -> PermissionStatus {
        state.withLock { state in
            if state.finderAutomation == .notDetermined { state.finderAutomation = .granted }
            return state.finderAutomation
        }
    }

    /// The real capture on the invented scene; every capture is recorded.
    func contextCapture(finder: FinderService, permissions: any PermissionAccessing, policy: FileAccessPolicy,
                        homeDirectory: String) -> any FrontmostContextCapturing {
        let capture = FrontmostContextCapture(apps: FakeFrontmostApps(data: self), accessibility: FakeAccessibility(data: self),
                                              finder: finder, permissions: permissions, policy: policy,
                                              homeDirectory: homeDirectory)
        return RecordingContextCapture(base: capture, data: self)
    }

    fileprivate func recordCapture(_ context: FrontmostContext, options: FrontmostContextOptions) {
        let record: JSONValue = [
            "scene": currentScene.map { .string($0.name) } ?? .null,
            "for": .string(options.includesWindowTitle ? "tool" : "chips"),
            "app": context.app.map { .string($0.name) } ?? .null,
            "windowTitle": .bool(context.windowTitle != nil),
            "selectedText": .bool(context.selectedText != nil),
            "finderItems": .number(Double(context.finderPaths.count)),
            "gaps": .array(context.gaps.sorted().map { .string($0.rawValue) }),
        ]
        append(record, to: \.contextCaptures)
    }

    // MARK: Scripts

    /// Answers finder-selection and system-appearance like the real scripts; nil for other scripts.
    func runScript(_ name: String, arguments: [String]) throws -> String? {
        switch name {
        case FinderService.selectionScript.name:
            guard finderAutomation == .granted else { throw AppleScriptError.notAuthorized(.finder) }
            let limit = max(1, Int(arguments.first ?? "") ?? 1)
            let paths = currentScene?.finderSelection ?? []
            let shown = paths.prefix(limit).map { path -> String in
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return exists && isDirectory.boolValue && !path.hasSuffix("/") ? path + "/" : path
            }
            return ([String(paths.count)] + shown).joined(separator: "\u{0}")
        case SystemEventsService.appearanceScript.name:
            guard systemEventsAutomation.allowsUse else { throw AppleScriptError.notAuthorized(.systemEvents) }
            guard let wanted = arguments.first, ["dark", "light"].contains(wanted) else {
                throw AppleScriptError.failed(number: 1001, message: "system-appearance expects dark or light")
            }
            let dark = wanted == "dark"
            let changed = state.withLock { state -> Bool in
                defer { state.isDark = dark }
                return state.isDark != dark
            }
            appendText(wanted, to: \.appearanceChanges)
            return try FakePersonalData.encode(SystemEventsService.AppearanceAnswer(dark: dark, changed: changed))
        default:
            return nil
        }
    }

    // MARK: Shortcuts

    fileprivate func listShortcuts(in folder: ShortcutFolder?) -> [ShortcutInfo] {
        guard let folder else { return shortcuts.map(\.info) }
        return shortcuts.filter { $0.folder == folder.name }.map(\.info)
    }

    fileprivate func runShortcut(_ shortcut: ShortcutInfo, input: String?) throws -> ShortcutOutput {
        guard let fake = shortcuts.first(where: { $0.info.identifier == shortcut.identifier || $0.info.name == shortcut.name }) else {
            throw ShortcutsError.failed(message: "Error: The shortcut could not be found.")
        }
        append(["name": .string(fake.info.name), "input": input.map(JSONValue.string) ?? .null], to: \.shortcutRuns)
        if let failure = fake.failure { throw ShortcutsError.failed(message: failure) }
        switch fake.outputType {
        case "image": return .files([ShortcutOutput.OutputFile(typeIdentifier: "public.png", size: 245_760)])
        case "none": return .none
        default:
            if let output = fake.output { return .text(output, isComplete: true) }
            return input.map { .text($0, isComplete: true) } ?? .none
        }
    }

    // MARK: Apps, links, volume

    fileprivate func recordOpenedApp(_ url: URL) {
        appendText(url.path, to: \.openedApps)
    }

    fileprivate func recordOpenedLink(_ url: URL) {
        appendText(url.absoluteString, to: \.openedLinks)
    }

    fileprivate var device: AudioOutputDevice {
        state.withLock { $0.device }
    }

    fileprivate func setVolume(_ volume: Double?, muted: Bool?, on deviceID: String?) throws -> AudioOutputDevice {
        let device = self.device
        if let deviceID, deviceID != device.identifier { throw AudioVolumeError.deviceChanged(deviceName: device.name) }
        if volume != nil, !device.canSetVolume { throw AudioVolumeError.volumeNotAdjustable(deviceName: device.name) }
        if muted != nil, !device.canMute { throw AudioVolumeError.cannotMute(deviceName: device.name) }
        let after = state.withLock { state -> AudioOutputDevice in
            if let volume { state.device.volume = volume }
            if let muted { state.device.isMuted = muted }
            return state.device
        }
        append(["level": volume.map { .number(Double(AudioVolumeLevel.percent(fromScalar: $0))) } ?? .null,
                "muted": muted.map(JSONValue.bool) ?? .null], to: \.volumeChanges)
        return after
    }

    // MARK: State

    private func append(_ record: JSONValue, to keyPath: WritableKeyPath<State, [JSONValue]> & Sendable) {
        state.withLock { state in
            state[keyPath: keyPath].append(record)
            if state[keyPath: keyPath].count > Self.maxRecords { state[keyPath: keyPath].removeFirst() }
        }
    }

    private func appendText(_ text: String, to keyPath: WritableKeyPath<State, [String]> & Sendable) {
        state.withLock { state in
            state[keyPath: keyPath].append(text)
            if state[keyPath: keyPath].count > Self.maxRecords { state[keyPath: keyPath].removeFirst() }
        }
    }

    /// For `orbitctl state`: what Orbit did with the invented Mac.
    func stateSummary() -> [String: JSONValue] {
        let snapshot = state.withLock { $0 }
        return [
            "shortcuts": .number(Double(shortcuts.count)),
            "shortcutRuns": .array(snapshot.shortcutRuns),
            "openedApps": .array(snapshot.openedApps.map(JSONValue.string)),
            "openedLinks": .array(snapshot.openedLinks.map(JSONValue.string)),
            "appearance": .string(snapshot.isDark ? "dark" : "light"),
            "appearanceChanges": .array(snapshot.appearanceChanges.map(JSONValue.string)),
            "volume": .number(Double(snapshot.device.percent ?? 0)),
            "muted": snapshot.device.isMuted.map(JSONValue.bool) ?? .null,
            "volumeChanges": .array(snapshot.volumeChanges),
            "frontmostScene": snapshot.scene.map(JSONValue.string) ?? .null,
            "contextCaptures": .array(snapshot.contextCaptures),
            "accessibility": .string(accessibility.rawValue),
            "finderAutomation": .string(snapshot.finderAutomation.rawValue),
            "systemEventsAutomation": .string(systemEventsAutomation.rawValue),
        ]
    }

    // MARK: Files

    private struct ShortcutsFile: Decodable {
        struct Entry: Decodable {
            var name: String
            var folder: String?
            var output: String?
            var outputType: String?
            var failure: String?
        }

        var shortcuts: [Entry]?
        var folders: [String]?
    }

    private struct FrontmostFile: Decodable {
        struct Entry: Decodable {
            var name: String
            var app: String
            var bundleID: String?
            var windowTitle: String?
            var selectedText: String?
            var secureField: Bool?
            var finderSelection: [String]?
        }

        var accessibility: String?
        var finderAutomation: String?
        var scene: String?
        var scenes: [Entry]?
    }

    private struct SystemFile: Decodable {
        struct Volume: Decodable {
            var device: String?
            var level: Int?
            var muted: Bool?
            var adjustable: Bool?
            var canMute: Bool?
        }

        var appearance: String?
        var automation: String?
        var volume: Volume?
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ url: URL, errors: inout [String]) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            errors.append("\(url.lastPathComponent) could not be read: \(error)")
            return nil
        }
    }

    /// "granted" (default), "denied", "notDetermined", "restricted".
    private static func status(_ text: String?, errors: inout [String]) -> PermissionStatus {
        switch text?.lowercased() {
        case nil, "granted", "authorized": return .granted
        case "denied": return .denied
        case "notdetermined": return .notDetermined
        case "restricted": return .restricted
        case let other?:
            errors.append("'\(other)' is no permission state (granted, denied, notDetermined or restricted).")
            return .granted
        }
    }

    /// A path from the file: absolute as it is, else relative to the fake-data folder.
    private static func absolute(_ path: String, in folder: URL?) -> String {
        guard !path.hasPrefix("/"), let folder else { return FilePath.normalize(path) }
        return FilePath.normalize(folder.path + "/" + path)
    }
}

/// The invented frontmost app (DEBUG fake-data mode).
struct FakeFrontmostApps: FrontmostAppProviding {
    let data: FakeSystemData

    func frontmostApp() async -> FrontmostApp? {
        data.currentScene?.app
    }
}

/// The invented app's window and selection as Accessibility would show them
/// (DEBUG fake-data mode): a password field as a field with the subrole
/// AXSecureTextField. Never touches the Accessibility API.
struct FakeAccessibility: AccessibilityReading {
    let data: FakeSystemData

    func isSecureInputEnabled() -> Bool { false }

    func read<Value: Sendable>(_ processID: pid_t,
                               _ body: @escaping @Sendable (any AccessibilityElement) -> Value) async -> Value? {
        guard let scene = data.currentScene, scene.app.processID == processID else { return nil }
        return body(FakeSceneElement(scene: scene, node: .app))
    }
}

private struct FakeSceneElement: AccessibilityElement {
    enum Node {
        case app
        case window
        case field
    }

    let scene: FakeSystemData.Scene
    let node: Node

    func string(_ attribute: String) -> String? {
        switch (node, attribute) {
        case (.window, AXName.title): scene.windowTitle
        case (.field, AXName.role): scene.secureField ? "AXTextField" : "AXTextArea"
        case (.field, AXName.subrole): scene.secureField ? AXName.secureTextField : nil
        case (.field, AXName.selectedText): scene.selectedText
        default: nil
        }
    }

    func element(_ attribute: String) -> (any AccessibilityElement)? {
        switch (node, attribute) {
        case (.app, AXName.focusedWindow): scene.windowTitle == nil ? nil : FakeSceneElement(scene: scene, node: .window)
        case (.app, AXName.focusedElement): FakeSceneElement(scene: scene, node: .field)
        default: nil
        }
    }

    func range(_ attribute: String) -> NSRange? {
        guard node == .field, attribute == AXName.selectedTextRange else { return nil }
        return NSRange(location: 0, length: (scene.selectedText ?? "").utf16.count)
    }

    func string(in range: NSRange) -> String? {
        guard node == .field, let text = scene.selectedText else { return nil }
        let utf16 = text.utf16
        let start = min(max(range.location, 0), utf16.count)
        let end = min(start + max(range.length, 0), utf16.count)
        return String(utf16[utf16.index(utf16.startIndex, offsetBy: start)..<utf16.index(utf16.startIndex, offsetBy: end)])
    }
}

/// The capture of the fake-data mode, recording what each capture saw.
private struct RecordingContextCapture: FrontmostContextCapturing {
    let base: any FrontmostContextCapturing
    let data: FakeSystemData

    func capture(_ options: FrontmostContextOptions) async -> FrontmostContext {
        let context = await base.capture(options)
        data.recordCapture(context, options: options)
        return context
    }
}

/// Opening apps and links in the DEBUG fake-data mode: recorded, nothing opens.
struct FakeAppLauncher: AppLaunching {
    let data: FakeSystemData

    func openApplication(at url: URL) async throws {
        data.recordOpenedApp(url)
    }

    func openLink(_ url: URL) async throws {
        data.recordOpenedLink(url)
    }
}

/// The invented shortcuts (DEBUG fake-data mode): a run is recorded and
/// returns its configured output or echoes its input; nothing runs.
struct FakeShortcuts: ShortcutsService {
    let data: FakeSystemData

    func shortcuts(in folder: ShortcutFolder?) async throws -> [ShortcutInfo] {
        data.listShortcuts(in: folder)
    }

    func folders() async throws -> [ShortcutFolder] {
        data.folders.map { ShortcutFolder(name: $0, identifier: nil) }
    }

    func run(_ shortcut: ShortcutInfo, input: String?) async throws -> ShortcutOutput {
        try Task.checkCancellation()
        return try data.runShortcut(shortcut, input: input)
    }
}

/// The invented output device (DEBUG fake-data mode): changes are recorded; the Mac's sound is never touched.
struct FakeAudioVolume: AudioVolumeControlling {
    let data: FakeSystemData

    func outputDevice() async throws -> AudioOutputDevice {
        data.device
    }

    func set(volume: Double?, muted: Bool?, on deviceID: String?) async throws -> AudioOutputDevice {
        try data.setVolume(volume, muted: muted, on: deviceID)
    }
}
#endif
