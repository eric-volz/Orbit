#if DEBUG
import AppKit
import Observation
import Security

/// DEBUG-only remote control for automated checks, driven by `DevTools/orbitctl`.
/// Off unless Orbit is launched with `ORBIT_DEBUG_AUTOMATION=1`.
///
/// Protocol (distributed notifications, delivered even while Orbit is inactive):
/// - command: `<bundleID>.debug.command`, userInfo `command`, `argument` (optional),
///   `replyID` (a UUID) and `token`: the per-launch secret the app writes to
///   `<data dir>/Automation/token` (mode 0600). Commands without it are ignored.
/// - reply: the payload (JSON) goes to `<data dir>/Automation/reply-<replyID>.json`
///   (0600); the notification `<bundleID>.debug.reply` carries only `replyID` and
///   `ok`, so no chat content is broadcast to other processes.
///
/// Commands: show, hide, toggle, type <text>, submit [text], key <spec>, new-chat,
/// open-settings, close-settings, open-onboarding [step | new-permissions], close-onboarding, state,
/// snapshot <png path>, snapshot-window <png path>, snapshot-settings <png path>,
/// snapshot-onboarding <png path>, wait-idle <seconds>, fake-frontmost [scene], quit, help.
/// `show` and `toggle` open the panel like the hotkey, with the context chips (`ContextCapture`).
/// `fake-frontmost` lists the invented frontmost apps of the fake-data mode or switches to one.
/// Onboarding steps: welcome, provider, hotkey, done or a permission (automationMail,
/// automationNotes, contacts, calendars, reminders, photos, automationFinder, accessibility); `new-permissions` opens what an
/// existing user sees once after an update. Debug runs never open the onboarding by themselves.
/// Key specs: escape, return, tab, space, up, down, left, right, delete, a to z, 0 to 9, … with
/// optional `cmd-`, `shift-`, `opt-`, `ctrl-` prefixes (e.g. `cmd-n`, `cmd-return`, `cmd-shift-z`).
///
/// User content (input text, chat items, instant results) appears only in replies to `state`; nothing is logged.
/// `state` also reports the Quick Look preview of file cards (visible, keyboard, index, count), the
/// permissions as Orbit read them, the onboarding and, with ORBIT_DEBUG_FAKE_PERSONAL_DATA, what Orbit did
/// with the fake notes, mail, contacts, events, reminders, photos and permissions (`fakePersonalData`).
/// Snapshots are written only as new or replaced PNG files in temporary folders or the data folder.
@MainActor
final class DebugAutomation: NSObject {
    /// Set by the development scripts (e2e, orbitctl users) at launch.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ORBIT_DEBUG_AUTOMATION"] == "1"
    }

    static var commandNotification: Notification.Name {
        Notification.Name("\(AppPaths.bundleIdentifier).debug.command")
    }

    static var replyNotification: Notification.Name {
        Notification.Name("\(AppPaths.bundleIdentifier).debug.reply")
    }

    static let commandNames = [
        "show", "hide", "toggle", "type", "submit", "key", "new-chat", "open-settings", "close-settings",
        "open-onboarding", "close-onboarding", "state", "snapshot", "snapshot-window", "snapshot-settings",
        "snapshot-onboarding", "wait-idle", "fake-frontmost", "quit", "help",
    ]

    private let environment: AppEnvironment
    private let panelController: PanelController
    private let settingsController: SettingsWindowController
    private let onboardingController: OnboardingWindowController
    private let hotkeyManager: HotkeyManager
    private weak var actions: (any AppActions)?
    private let channel = DebugChannel.standard
    private var token: String?

    init(environment: AppEnvironment, panelController: PanelController, settingsController: SettingsWindowController,
         onboardingController: OnboardingWindowController, hotkeyManager: HotkeyManager, actions: any AppActions) {
        self.environment = environment
        self.panelController = panelController
        self.settingsController = settingsController
        self.onboardingController = onboardingController
        self.hotkeyManager = hotkeyManager
        self.actions = actions
    }

    func start() {
        do {
            token = try channel.createToken()
        } catch {
            Log.app.error("Debug automation not started: the token could not be written")
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(didReceiveCommand(_:)),
            name: Self.commandNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        Log.app.info("Debug automation listening")
    }

    @objc private nonisolated func didReceiveCommand(_ notification: Notification) {
        guard let request = DebugRequest(userInfo: notification.userInfo) else { return }
        Task { @MainActor in
            await self.handle(request)
        }
    }

    private func handle(_ request: DebugRequest) async {
        guard let token, DebugChannel.matches(request.token, token), channel.replyURL(for: request.replyID) != nil else {
            Log.app.notice("Debug command rejected (no valid token)")
            return
        }
        Log.app.debug("Debug command \(request.command, privacy: .public)")
        do {
            let payload = try await run(request.command, argument: request.argument)
            reply(to: request.replyID, ok: true, payload: payload)
            if request.command == "quit" {
                // Give the reply a moment to leave the process. Terminate from a run
                // loop timer, not from inside this main-actor job: `terminate:` may
                // spin a nested run loop that must be able to run other main-actor work.
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        } catch {
            let message = (error as? DebugError)?.message ?? String(describing: error)
            reply(to: request.replyID, ok: false, payload: ["error": .string(message)])
        }
    }

    /// Writes the payload to the reply file, then tells orbitctl it is there.
    private func reply(to replyID: String, ok: Bool, payload: JSONValue) {
        var delivered = true
        do {
            try channel.writeReply(Data(payload.jsonString(prettyPrinted: true).utf8), for: replyID)
        } catch {
            Log.app.error("Debug reply could not be written")
            delivered = false
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.replyNotification,
            object: nil,
            userInfo: ["replyID": replyID, "ok": ok && delivered, "written": delivered],
            deliverImmediately: true
        )
    }

    // MARK: Commands

    private var panelState: PanelState { environment.panelState }
    private var panel: OrbitPanel { panelController.panel }

    private func run(_ command: String, argument: String?) async throws -> JSONValue {
        switch command {
        case "show":
            actions?.showPanel()
            return state()
        case "hide":
            actions?.hidePanel()
            return state()
        case "toggle":
            actions?.togglePanel()
            return state()
        case "type":
            panelState.inputText = argument ?? ""
            return ["inputText": .string(panelState.inputText)]
        case "submit":
            // Same as Return in the chat input: a parked chat is closed first.
            let text = argument ?? panelState.inputText
            if environment.chatParking.isParked {
                environment.startNewChat()
            }
            environment.agentLoop.send(text, attachments: panelState.attachments)
            environment.contextCapture.messageSent()
            panelState.inputText = ""
            panelState.attachments = []
            return [
                "submitted": .string(text), "isRunning": .bool(environment.agentLoop.isRunning),
                "items": .number(Double(environment.agentLoop.items.count)),
            ]
        case "key":
            return try await pressKey(argument)
        case "new-chat":
            actions?.startNewChat()
            return ["items": .number(Double(environment.agentLoop.items.count))]
        case "open-settings":
            actions?.showSettings()
            try? await Task.sleep(for: .milliseconds(300))
            return settingsState()
        case "close-settings":
            settingsController.close()
            return settingsState()
        case "open-onboarding":
            var step: OnboardingModel.Step?
            var mode = OnboardingModel.Mode.full
            if let name = argument?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                if name == "new-permissions" {
                    // What an existing user sees once after an update (with this session's settings).
                    let plan = OnboardingPlan.atLaunch(hasCompleted: true,
                                                       presented: environment.settings.presentedOnboardingPermissions,
                                                       onboardingPermissions: environment.permissions.onboardingPermissions)
                    guard let planned = plan.mode else { throw DebugError("No permission step is new") }
                    mode = planned
                } else {
                    guard let named = OnboardingModel.Step(id: name) else {
                        throw DebugError("Unknown onboarding step '\(name)'")
                    }
                    step = named
                }
            }
            onboardingController.show(at: step, mode: mode)
            try? await Task.sleep(for: .milliseconds(300))
            return onboardingState()
        case "close-onboarding":
            onboardingController.close()
            return onboardingState()
        case "state":
            return state()
        case "snapshot":
            return try snapshot(of: panel, to: try requiredPath(argument))
        case "snapshot-window":
            // The composited on-screen look, including the behind-window material.
            return try snapshot(of: panel, to: try requiredPath(argument), forceWindowCapture: true)
        case "snapshot-settings":
            guard let window = settingsController.window else {
                throw DebugError("The settings window has not been opened yet")
            }
            return try snapshot(of: window, to: try requiredPath(argument))
        case "snapshot-onboarding":
            guard let window = onboardingController.window else {
                throw DebugError("The onboarding is not open")
            }
            return try snapshot(of: window, to: try requiredPath(argument))
        case "wait-idle":
            let seconds = argument.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 30
            let idle = await waitUntilIdle(timeout: .milliseconds(Int(max(seconds, 0) * 1000)))
            guard idle else { throw DebugError("Still running after \(seconds) s") }
            return ["isRunning": false, "items": .number(Double(environment.agentLoop.items.count))]
        case "fake-frontmost":
            guard let scenes = environment.services.debugFrontmostScene else {
                throw DebugError("No fake frontmost app: start Orbit with ORBIT_DEBUG_FAKE_PERSONAL_DATA")
            }
            let name = argument?.trimmingCharacters(in: .whitespaces)
            let reply = scenes(name?.isEmpty == false ? name : nil)
            if case .object(let object) = reply, case .string(let error)? = object["error"] {
                throw DebugError(error)
            }
            return reply
        case "quit":
            return ["quitting": true]
        case "help":
            return ["commands": .array(Self.commandNames.map(JSONValue.string))]
        default:
            throw DebugError("Unknown command '\(command)'. Known: \(Self.commandNames.joined(separator: ", "))")
        }
    }

    private func requiredPath(_ argument: String?) throws -> String {
        guard let path = argument?.trimmingCharacters(in: .whitespaces), path.hasPrefix("/") else {
            throw DebugError("Expected an absolute PNG path")
        }
        guard DebugChannel.isAllowedSnapshotPath(path, dataDirectory: AppPaths.applicationSupport) else {
            throw DebugError("Snapshots go to a .png file in a temporary folder or the data folder, and replace only PNG files")
        }
        return path
    }

    // MARK: State

    private func state() -> JSONValue {
        let screen = panel.screen ?? PanelController.activeScreen()
        let agentLoop = environment.agentLoop
        let selection = (panel.firstResponder as? NSText)?.selectedRange
        return [
            "inputSelection": selection.map { ["location": .number(Double($0.location)), "length": .number(Double($0.length))] } ?? .null,
            "panelVisible": .bool(panel.isVisible),
            "panelIsKey": .bool(panel.isKeyWindow),
            "appIsActive": .bool(NSApp.isActive),
            "appIsHidden": .bool(NSApp.isHidden),
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(JSONValue.string) ?? .null,
            "panelFrame": Self.json(panel.frame),
            "screenVisibleFrame": screen.map { Self.json($0.visibleFrame) } ?? .null,
            "preferredContentHeight": .number(Double(panelState.preferredContentHeight)),
            "maximumContentHeight": .number(Double(panelState.maximumContentHeight)),
            "showCount": .number(Double(panelState.showCount)),
            "inputText": .string(panelState.inputText),
            "attachments": .array(panelState.attachments.map { .string($0.label) }),
            "contextCapture": Self.summary(of: environment.contextCapture, settings: environment.settings),
            "isRunning": .bool(agentLoop.isRunning),
            "chatParked": .bool(environment.chatParking.isParked),
            "hotkey": hotkeyManager.shortcutDescription.map(JSONValue.string) ?? .null,
            "keyWindow": NSApp.keyWindow.map { .string(Self.describe($0)) } ?? .null,
            "firstResponder": panel.firstResponder.map { .string(String(describing: type(of: $0))) } ?? .null,
            "settingsVisible": .bool(settingsController.isVisible),
            "settingsTab": .string(settingsController.navigation.tab.rawValue),
            "keyboardHandoff": Self.summary(of: panelState.keyboardHandoff),
            "onboarding": onboardingState(),
            "permissions": Self.summary(of: environment.permissions),
            "items": .array(agentLoop.items.map(Self.summary(of:))),
            "instantSearching": .bool(environment.instantSearch.isSearching),
            "instantResults": Self.summary(of: environment.instantSearch.groups),
            "quickLook": Self.summary(of: environment.quickLook),
            // ORBIT_DEBUG_FAKE_PERSONAL_DATA: invented notes, mail, contacts, events and reminders, and what Orbit did with them.
            "fakePersonalData": environment.services.debugPersonalDataState?() ?? .null,
        ]
    }

    private func onboardingState() -> JSONValue {
        let mode: JSONValue = onboardingController.model.map { model in
            .string(model.mode == .full ? "full" : "newPermissions")
        } ?? .null
        return [
            "visible": .bool(onboardingController.isVisible),
            "isKey": .bool(onboardingController.window?.isKeyWindow ?? false),
            "step": onboardingController.model.map { .string($0.step.id) } ?? .null,
            "mode": mode,
            "steps": onboardingController.model.map { .array($0.steps.map { .string($0.id) }) } ?? .null,
            "completed": .bool(environment.settings.hasCompletedOnboarding),
            "presentedPermissions": .array(environment.settings.presentedOnboardingPermissions.map(\.rawValue).sorted()
                .map(JSONValue.string)),
        ]
    }

    /// Orbit handing the keyboard to Mail's reply window: "idle", "opening",
    /// "opened" or "keptVisible" (the panel stayed up without the keyboard), and the app.
    static func summary(of handoff: KeyboardHandoff) -> JSONValue {
        let phase = switch handoff.phase {
        case .idle: "idle"
        case .opening: "opening"
        case .opened: "opened"
        case .keptVisible: "keptVisible"
        }
        return ["phase": .string(phase), "app": handoff.app.map(JSONValue.string) ?? .null]
    }

    /// The context chips' capture: whether it is on, how many ran and how the last one ended.
    static func summary(of capture: ContextCapture, settings: SettingsStore) -> JSONValue {
        [
            "enabled": .bool(settings.capturesSelectionOnOpen),
            "captures": .number(Double(capture.captureCount)),
            "isCapturing": .bool(capture.isCapturing),
            "lastOutcome": capture.lastOutcome.map { .string($0.rawValue) } ?? .null,
        ]
    }

    /// The permissions Orbit uses and their statuses as last read ("unread" before the first reading).
    static func summary(of permissions: PermissionManager) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for permission in permissions.permissions {
            object[permission.rawValue] = .string(permissions.statuses[permission]?.rawValue ?? "unread")
        }
        return .object(object)
    }

    private func settingsState() -> JSONValue {
        [
            "settingsVisible": .bool(settingsController.isVisible),
            "settingsIsKey": .bool(settingsController.window?.isKeyWindow ?? false),
            "panelVisible": .bool(panel.isVisible),
            "appIsActive": .bool(NSApp.isActive),
        ]
    }

    private static func describe(_ window: NSWindow) -> String {
        if window is OrbitPanel { return "panel" }
        return window.title.isEmpty ? String(describing: type(of: window)) : window.title
    }

    private static func json(_ rect: CGRect) -> JSONValue {
        [
            "x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
            "width": .number(Double(rect.width)), "height": .number(Double(rect.height)),
        ]
    }

    static func summary(of item: ChatItem) -> JSONValue {
        func entry(_ kind: String, _ text: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var object: [String: JSONValue] = ["kind": .string(kind), "text": .string(String(text.prefix(200)))]
            object.merge(extra) { _, new in new }
            return .object(object)
        }
        switch item.kind {
        case .user(let text, let attachments):
            return entry("user", text, ["attachments": .number(Double(attachments.count))])
        case .assistant(let text, let isStreaming):
            return entry("assistant", text, ["streaming": .bool(isStreaming)])
        case .progress(let text):
            return entry("progress", text)
        case .toolStatus(let status):
            return entry("toolStatus", status.text, ["tool": .string(status.toolName), "state": .string(status.state.rawValue)])
        case .card(let card):
            return entry("card", describe(card))
        case .confirmation(let confirmation):
            return entry("confirmation", confirmation.request.title, ["status": .string(confirmation.status.rawValue)])
        case .notice(let notice):
            var extra: [String: JSONValue] = ["style": .string(notice.style.rawValue)]
            if let action = notice.action {
                extra["action"] = .string(action.rawValue)
            }
            if let secondary = notice.secondaryAction {
                extra["secondaryAction"] = .string(secondary.rawValue)
            }
            return entry("notice", notice.message, extra)
        case .disclosure(let items, let providerName):
            let text = items.map { "\($0.kind.rawValue): \($0.count)" }.joined(separator: ", ")
            return entry("disclosure", text, ["provider": .string(providerName)])
        }
    }

    /// Instant results in display order: group, title and subtitle.
    static func summary(of groups: [SearchResultGroup]) -> JSONValue {
        .array(groups.flatMap { group in
            group.results.map { result -> JSONValue in
                var object: [String: JSONValue] = ["group": .string(group.category.rawValue), "title": .string(result.title)]
                if let subtitle = result.subtitle { object["subtitle"] = .string(subtitle) }
                return .object(object)
            }
        })
    }

    /// The Quick Look preview: on screen, with the keyboard, which file of how many (no names).
    static func summary(of quickLook: QuickLookController) -> JSONValue {
        [
            "visible": .bool(quickLook.isVisible),
            "hasKeyboard": .bool(quickLook.hasKeyboard),
            "index": quickLook.preview.map { .number(Double($0.index)) } ?? .null,
            "count": .number(Double(quickLook.itemCount)),
        ]
    }

    private static func describe(_ card: ResultCard) -> String {
        switch card {
        case .files(let items): "files(\(items.count))"
        case .mails(let items): "mails(\(items.count))"
        case .mailDraft: "mailDraft"
        case .notes(let items): "notes(\(items.count))"
        case .events(let items): "events(\(items.count))"
        case .reminders(let items): "reminders(\(items.count))"
        case .contacts(let items): "contacts(\(items.count))"
        case .photos(let items): "photos(\(items.count))"
        case .info(let item): "info: \(item.title)"
        }
    }

    // MARK: Keys

    private static let sentinelSubtype: Int16 = 0x4F52

    /// Presses a key in the key window. Normally keyDown/keyUp are posted into the app's event
    /// queue, so they take the real path (NSApp.sendEvent → key equivalents in the window, then
    /// the main menu → first responder, SwiftUI handlers); the reply waits until a sentinel
    /// event behind them has been dequeued. Without a key window (e.g. while the screen is
    /// locked) the same routing is replayed directly on the visible panel.
    private func pressKey(_ spec: String?) async throws -> JSONValue {
        guard let spec, let stroke = DebugKeyStroke(spec: spec) else {
            throw DebugError("Unknown key '\(spec ?? "")'")
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let window = NSApp.keyWindow ?? (panel.isVisible ? panel : nil) else {
            throw DebugError("No key window and the panel is hidden; show the panel first")
        }
        guard let down = stroke.event(.keyDown, windowNumber: window.windowNumber, timestamp: timestamp),
              let up = stroke.event(.keyUp, windowNumber: window.windowNumber, timestamp: timestamp + 0.02)
        else {
            throw DebugError("Could not create events for '\(spec)'")
        }
        var result: [String: JSONValue] = ["key": .string(spec), "window": .string(Self.describe(window))]
        if window.isKeyWindow {
            result["route"] = "eventQueue"
            result["delivered"] = .bool(await post([down, up]))
        } else {
            result["route"] = "direct (no key window)"
            if !window.performKeyEquivalent(with: down), !(NSApp.mainMenu?.performKeyEquivalent(with: down) ?? false) {
                window.sendEvent(down)
            }
            window.sendEvent(up)
        }
        // SwiftUI applies state changes from the handlers on the next turn.
        try? await Task.sleep(for: .milliseconds(50))
        return .object(result)
    }

    /// Posts events into the app's queue; true once a sentinel posted behind them was dequeued.
    private func post(_ events: [NSEvent]) async -> Bool {
        let token = Int.random(in: 1...Int(Int32.max))
        guard let sentinel = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: Self.sentinelSubtype, data1: token, data2: 0
        ) else { return false }

        let waiter = DebugWaiter()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            guard event.subtype.rawValue == Self.sentinelSubtype, event.data1 == token else { return event }
            waiter.finish(true)
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        for event in events + [sentinel] {
            NSApp.postEvent(event, atStart: false)
        }
        return await waiter.wait(timeout: .seconds(3))
    }

    // MARK: Waiting

    private func waitUntilIdle(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while environment.agentLoop.isRunning {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            let waiter = DebugWaiter()
            withObservationTracking {
                _ = environment.agentLoop.isRunning
            } onChange: {
                Task { @MainActor in waiter.finish(true) }
            }
            _ = await waiter.wait(timeout: remaining)
        }
        return true
    }

    // MARK: Snapshots

    /// Renders the window's content view with `cacheDisplay(in:to:)`. Behind-window materials
    /// and some SwiftUI layers do not render that way; if the result is blank or mostly
    /// transparent, the window itself is captured by window number (own windows need no
    /// Screen Recording permission).
    private func snapshot(of window: NSWindow, to path: String, forceWindowCapture: Bool = false) throws -> JSONValue {
        guard let view = window.contentView else { throw DebugError("The window has no content view") }
        view.layoutSubtreeIfNeeded()
        var image: CGImage?
        var method = "cacheDisplay"
        var cacheDisplayResult = forceWindowCapture ? "skipped" : "unavailable"
        if !forceWindowCapture, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let rendered = bitmap.cgImage {
                if SnapshotInspector.isBlank(rendered) {
                    cacheDisplayResult = "blank"
                } else {
                    cacheDisplayResult = "ok"
                    image = rendered
                }
            }
        }
        if image == nil {
            guard window.isVisible else {
                throw DebugError("cacheDisplay was \(cacheDisplayResult) and the window is not on screen")
            }
            // Occluded windows (e.g. behind the lock screen) skip drawing; force a frame.
            window.display()
            CATransaction.flush()
            guard let captured = WindowCapture.image(windowNumber: window.windowNumber) else {
                throw DebugError("cacheDisplay was \(cacheDisplayResult) and the window capture failed")
            }
            image = captured
            method = "windowCapture"
        }
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DebugError("PNG encoding failed")
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            throw DebugError("Could not write \(path): \(error.localizedDescription)")
        }
        return [
            "path": .string(path), "method": .string(method), "cacheDisplay": .string(cacheDisplayResult),
            "pixelWidth": .number(Double(image.width)), "pixelHeight": .number(Double(image.height)),
        ]
    }
}

// MARK: - Support types

struct DebugError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A command as received from orbitctl.
struct DebugRequest: Sendable, Equatable {
    var command: String
    var argument: String?
    var replyID: String
    var token: String

    init(command: String, argument: String?, replyID: String, token: String = "") {
        self.command = command
        self.argument = argument
        self.replyID = replyID
        self.token = token
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let command = userInfo?["command"] as? String, let replyID = userInfo?["replyID"] as? String else {
            return nil
        }
        self.init(command: command, argument: userInfo?["argument"] as? String, replyID: replyID,
                  token: userInfo?["token"] as? String ?? "")
    }
}

/// The files that authenticate orbitctl and carry the replies:
/// `<data dir>/Automation/token` and `reply-<id>.json`, readable only by the user.
struct DebugChannel: Sendable {
    let directory: URL

    static var standard: DebugChannel {
        DebugChannel(directory: AppPaths.applicationSupport.appendingPathComponent("Automation", isDirectory: true))
    }

    var tokenURL: URL { directory.appendingPathComponent("token") }

    /// nil unless `replyID` is a UUID (it becomes part of a file name).
    func replyURL(for replyID: String) -> URL? {
        guard let id = UUID(uuidString: replyID) else { return nil }
        return directory.appendingPathComponent("reply-\(id.uuidString.lowercased()).json")
    }

    /// A new random token for this launch, written to `tokenURL` (0600).
    func createToken() throws -> String {
        try PrivateFile.prepareDirectory(directory)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DebugError("No random bytes")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: tokenURL)
        try PrivateFile.create(at: tokenURL, contents: Data(token.utf8))
        return token
    }

    func writeReply(_ data: Data, for replyID: String) throws {
        guard let url = replyURL(for: replyID) else { throw DebugError("Invalid reply id") }
        try? FileManager.default.removeItem(at: url)
        try PrivateFile.create(at: url, contents: data)
    }

    static func matches(_ presented: String, _ expected: String) -> Bool {
        let left = Array(presented.utf8)
        let right = Array(expected.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0 && !expected.isEmpty
    }

    /// A `.png` path in a temporary folder or the data folder; an existing file
    /// there is replaced only if it is a PNG.
    static func isAllowedSnapshotPath(_ path: String, dataDirectory: URL,
                                      temporaryDirectory: String = NSTemporaryDirectory()) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized.lowercased().hasSuffix(".png") else { return false }
        let folder = canonical((standardized as NSString).deletingLastPathComponent)
        let roots = [temporaryDirectory, "/tmp", dataDirectory.path].map(canonical)
        guard roots.contains(where: { folder == $0 || folder.hasPrefix($0 == "/" ? $0 : $0 + "/") }) else {
            return false
        }
        guard FileManager.default.fileExists(atPath: standardized) else { return true }
        guard let handle = FileHandle(forReadingAtPath: standardized) else { return false }
        defer { try? handle.close() }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return (try? handle.read(upToCount: 8)).map(Array.init) == signature
    }

    /// The path with symlinks resolved (`/tmp` → `/private/tmp`), also when its
    /// last components do not exist yet.
    private static func canonical(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return path }
        defer { free(resolved) }
        return ([String(cString: resolved)] + missing).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }
}

/// Resumes one waiting task exactly once: with the value passed to `finish`, or `false` on
/// timeout. A `finish` before `wait` is remembered.
@MainActor
final class DebugWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var earlyResult: Bool?

    func wait(timeout: Duration) async -> Bool {
        if let earlyResult { return earlyResult }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resume(false)
            }
        }
    }

    func finish(_ value: Bool) {
        guard continuation != nil else {
            earlyResult = earlyResult ?? value
            return
        }
        resume(value)
    }

    private func resume(_ value: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Parses key specs like "escape", "cmd-n", "cmd-shift-z", "up" into event parameters.
struct DebugKeyStroke: Equatable, Sendable {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    var modifiers: NSEvent.ModifierFlags

    private struct Key {
        var keyCode: UInt16
        var character: String
        var isFunctionKey = false
        var isArrow = false
    }

    private static let namedKeys: [String: Key] = [
        "escape": Key(keyCode: 53, character: "\u{1B}"),
        "esc": Key(keyCode: 53, character: "\u{1B}"),
        "return": Key(keyCode: 36, character: "\r"),
        "enter": Key(keyCode: 76, character: "\u{03}"),
        "tab": Key(keyCode: 48, character: "\t"),
        "space": Key(keyCode: 49, character: " "),
        "delete": Key(keyCode: 51, character: "\u{7F}"),
        "backspace": Key(keyCode: 51, character: "\u{7F}"),
        "forwarddelete": Key(keyCode: 117, character: "\u{F728}", isFunctionKey: true),
        "up": Key(keyCode: 126, character: "\u{F700}", isFunctionKey: true, isArrow: true),
        "down": Key(keyCode: 125, character: "\u{F701}", isFunctionKey: true, isArrow: true),
        "left": Key(keyCode: 123, character: "\u{F702}", isFunctionKey: true, isArrow: true),
        "right": Key(keyCode: 124, character: "\u{F703}", isFunctionKey: true, isArrow: true),
        "home": Key(keyCode: 115, character: "\u{F729}", isFunctionKey: true),
        "end": Key(keyCode: 119, character: "\u{F72B}", isFunctionKey: true),
        "pageup": Key(keyCode: 116, character: "\u{F72C}", isFunctionKey: true),
        "pagedown": Key(keyCode: 121, character: "\u{F72D}", isFunctionKey: true),
        "comma": Key(keyCode: 43, character: ","),
        "period": Key(keyCode: 47, character: "."),
        "slash": Key(keyCode: 44, character: "/"),
        "minus": Key(keyCode: 27, character: "-"),
        "equal": Key(keyCode: 24, character: "="),
    ]

    /// ANSI key codes of the letter and digit keys.
    private static let characterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
    ]

    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command,
        "shift": .shift,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control,
    ]

    init?(spec: String) {
        let parts = spec.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for name in parts.dropLast() {
            guard let flag = Self.modifierNames[name] else { return nil }
            modifiers.insert(flag)
        }

        let key: Key
        if let named = Self.namedKeys[keyName] {
            key = named
        } else if keyName.count == 1, let character = keyName.first, let code = Self.characterKeyCodes[character] {
            key = Key(keyCode: code, character: keyName)
        } else {
            return nil
        }

        var ignoringModifiers = key.character
        var characters = key.character
        if modifiers.contains(.shift) {
            if key.keyCode == 48 {
                characters = "\u{19}"  // Shift-Tab produces a back tab.
                ignoringModifiers = "\u{19}"
            } else if !key.isFunctionKey {
                ignoringModifiers = key.character.uppercased()
                characters = ignoringModifiers
            }
        }
        if modifiers.contains(.control), !key.isFunctionKey,
           let scalar = key.character.unicodeScalars.first, ("a"..."z").contains(Character(scalar)) {
            characters = String(UnicodeScalar(UInt8(scalar.value - 96)))
        }
        if key.isFunctionKey { modifiers.insert(.function) }
        if key.isArrow { modifiers.insert(.numericPad) }

        self.keyCode = key.keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = ignoringModifiers
        self.modifiers = modifiers
    }

    func event(_ type: NSEvent.EventType, windowNumber: Int, timestamp: TimeInterval) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCode
        )
    }
}

/// Decides whether a `cacheDisplay` rendering is usable.
enum SnapshotInspector {
    /// Blank = a single color, or more than half of the pixels (almost) fully transparent:
    /// what `cacheDisplay` produces when the material is drawn by the window server.
    static func isBlank(rgba: [UInt8]) -> Bool {
        let pixelCount = rgba.count / 4
        guard pixelCount > 0 else { return true }
        var transparent = 0
        var isUniform = true
        let first = (rgba[0], rgba[1], rgba[2], rgba[3])
        for index in 0..<pixelCount {
            let offset = index * 4
            if rgba[offset + 3] < 13 { transparent += 1 }
            if isUniform {
                let pixel = (rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
                isUniform = Self.close(pixel.0, first.0) && Self.close(pixel.1, first.1)
                    && Self.close(pixel.2, first.2) && Self.close(pixel.3, first.3)
            }
        }
        return isUniform || transparent * 2 > pixelCount
    }

    /// Downsamples to at most 256 px wide RGBA8 and checks `isBlank(rgba:)`.
    static func isBlank(_ image: CGImage) -> Bool {
        let scale = min(1, 256 / Double(max(image.width, 1)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return !drawn || isBlank(rgba: pixels)
    }

    private static func close(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        abs(Int(lhs) - Int(rhs)) <= 3
    }
}

/// Captures one of Orbit's own windows. `CGWindowListCreateImage` is obsoleted in the macOS 15
/// SDK (unavailable to Swift) but still exported, so it is resolved at runtime.
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func image(windowNumber: Int) -> CGImage? {
        // RTLD_DEFAULT: CoreGraphics is already loaded through AppKit.
        guard windowNumber > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return createImage(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(windowNumber), options)?
            .takeRetainedValue()
    }
}
#endif
