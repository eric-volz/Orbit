import AppKit
import Quartz

/// App-level commands shared by the menu bar item, the main menu and DEBUG automation.
@MainActor
protocol AppActions: AnyObject {
    func showPanel()
    func hidePanel()
    func togglePanel()
    func startNewChat()
    /// Hides the panel, activates Orbit and brings the settings window to the front.
    func showSettings()
    /// Shows the onboarding window ("Setup…").
    func showOnboarding()
    /// ⌘W: closes the key window (e.g. Settings); the panel is hidden instead of closed.
    func closeKeyWindow()
    func showAboutPanel()
}

/// Composition root of the AppKit shell: panel, hotkey, menu bar item, main menu,
/// settings and onboarding windows around the `AppEnvironment`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?
    private var panelController: PanelController?
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var hotkeyManager: HotkeyManager?
    private var menuBarController: MenuBarController?
    private var mainMenu: MainMenu?
    #if DEBUG
    private var debugAutomation: DebugAutomation?
    #endif

    override init() {
        super.init()
    }

    /// Tests: the app's actions on an environment that was not launched: no
    /// panel, windows, hotkey or menus.
    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance per bundle ID: a second copy (e.g. the binary started directly
        // while Orbit runs) would register the same hotkey and share the database.
        // A previous instance that is still quitting (saving chats) gets 3 s to finish.
        guard let other = Self.otherRunningInstance() else {
            finishLaunching()
            return
        }
        Task { @MainActor in
            if await Self.waitUntilTerminated(other, timeout: 3) {
                finishLaunching()
            } else {
                resolveSecondInstance(other)
            }
        }
    }

    /// Another Orbit keeps running. The same copy: it shows its panel and this
    /// one quits. Another copy (e.g. a newer download): the user chooses which
    /// one to keep, so an update never quits silently.
    private func resolveSecondInstance(_ other: NSRunningApplication) {
        let ownURL = Bundle.main.bundleURL.standardizedFileURL
        guard let otherURL = other.bundleURL?.standardizedFileURL, otherURL != ownURL else {
            Log.app.info("Orbit is already running (pid \(other.processIdentifier, privacy: .public)); showing its panel")
            Self.askRunningInstanceToShowPanel()
            NSApp.terminate(nil)
            return
        }
        let otherVersion = Bundle(url: otherURL).flatMap(Self.version(of:)) ?? "?"
        let ownVersion = Self.version(of: .main) ?? "?"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Orbit Is Already Running")
        alert.informativeText = String(format: String(localized: "Another copy of Orbit is open (version %1$@). Quit it so this copy (version %2$@) can start?"),
                                       otherVersion, ownVersion)
        alert.addButton(withTitle: String(localized: "Use This Copy"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            Self.askRunningInstanceToShowPanel()
            NSApp.terminate(nil)
            return
        }
        other.terminate()
        Task { @MainActor in
            if await Self.waitUntilTerminated(other, timeout: 5) {
                finishLaunching()
            } else {
                Log.app.error("The other instance did not quit; quitting")
                NSApp.terminate(nil)
            }
        }
    }

    private static func waitUntilTerminated(_ app: NSRunningApplication, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isTerminated, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app.isTerminated
    }

    private static func version(of bundle: Bundle) -> String? {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    // MARK: Showing the panel on request of a second launch

    /// Posted by a second launch of the same copy. It only shows the panel, like
    /// launching Orbit again does, and carries no data.
    static var showPanelNotification: Notification.Name {
        Notification.Name("\(AppPaths.bundleIdentifier).showPanel")
    }

    private static func askRunningInstanceToShowPanel() {
        DistributedNotificationCenter.default().postNotificationName(showPanelNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    private func listenForShowPanelRequests() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(didReceiveShowPanelRequest(_:)), name: Self.showPanelNotification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    @objc private nonisolated func didReceiveShowPanelRequest(_ notification: Notification) {
        Task { @MainActor in
            // Orbit was launched again: the app in front is the launcher, not the user's context.
            self.showPanel(capturingContext: false)
        }
    }

    private func finishLaunching() {
        let environment = AppEnvironment(services: .live())
        self.environment = environment

        // Settings activate Orbit themselves: the panel hides without giving focus away.
        let settingsController = SettingsWindowController(environment: environment) { [weak self] in
            self?.panelController?.hide(yieldFocus: false)
        }
        let panelController = PanelController(environment: environment) { [weak self] tab in
            self?.showSettings(tab: tab)
        }
        let hotkeyManager = HotkeyManager { [weak self] in
            self?.togglePanel()
        }
        let onboardingController = OnboardingWindowController(environment: environment) { [weak self] in
            self?.panelController?.hide(yieldFocus: false)
        }
        self.settingsController = settingsController
        self.panelController = panelController
        self.hotkeyManager = hotkeyManager
        self.onboardingController = onboardingController

        let mainMenu = MainMenu(actions: self)
        self.mainMenu = mainMenu
        // LSUIElement apps show no menu bar, but key equivalents (⌘C/⌘V, ⌘N, ⌘W, ⌘,) still
        // go through the main menu, also while the panel is key and Orbit is inactive.
        NSApp.mainMenu = mainMenu.menu
        menuBarController = MenuBarController(actions: self)
        hotkeyManager.start()
        listenForShowPanelRequests()
        // Reads the permissions in the background now and whenever they may have changed.
        environment.permissions.start()

        Task {
            // Parked: after a relaunch the panel opens in search mode.
            await environment.chatParking.restoreMostRecentChat()
        }

        #if DEBUG
        if DebugAutomation.isEnabled {
            let automation = DebugAutomation(
                environment: environment,
                panelController: panelController,
                settingsController: settingsController,
                onboardingController: onboardingController,
                hotkeyManager: hotkeyManager,
                actions: self
            )
            automation.start()
            debugAutomation = automation
        }
        #endif

        let plan = Self.onboardingAtLaunch(hasCompleted: environment.settings.hasCompletedOnboarding,
                                           presented: environment.settings.presentedOnboardingPermissions,
                                           onboardingPermissions: environment.permissions.onboardingPermissions,
                                           environment: ProcessInfo.processInfo.environment)
        if let mode = plan.mode {
            Log.app.info("Showing the onboarding (\(plan == .full ? "all steps" : "new permissions", privacy: .public))")
            onboardingController.show(mode: mode)
        }
        Log.app.info("Orbit launched")
    }

    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ownPID && !$0.isTerminated }
    }

    /// Launching Orbit again (Finder, Spotlight, `open`) brings up the panel, without
    /// context chips: the selection is then the one that launched Orbit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(capturingContext: false)
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Quick Look

    /// The end of every responder chain: controls the Quick Look panel when the search
    /// starts from a window other than the Orbit panel (e.g. the preview itself is key).
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            environment?.quickLook.acceptsPreviewPanelControl(panel) ?? false
        }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            environment?.quickLook.beginPreviewPanelControl(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            environment?.quickLook.endPreviewPanelControl(panel)
        }
    }

    /// Lets queued chat saves finish before quitting (at most 2 s), so quitting never
    /// hangs. The reply goes through the main run loop rather than a main-actor task:
    /// while AppKit waits for it, `terminate:` may be running inside a main-actor job
    /// (e.g. called from a Task), and then no other main-actor job can start.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A running request stops like with Escape, so its partial answer is saved.
        environment?.agentLoop.stopForTermination()
        guard let environment, environment.agentLoop.hasPendingSaves else { return .terminateNow }
        let latch = TerminationReplyLatch()
        Task { @MainActor in
            await environment.agentLoop.waitForPendingSaves()
            latch.reply()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            latch.reply()
        }
        return .terminateLater
    }

    /// Ends the Claude Code process and its tool bridge and removes their
    /// files, and ends a sign-in to Claude Code that still runs.
    func applicationWillTerminate(_ notification: Notification) {
        environment?.claudeCodeAccount.shutdown()
        environment?.claudeCodeRuntime.shutdown()
    }

    /// The onboarding appears at launch until it was seen once, and once more
    /// with only their steps when an update brought permissions the user never had
    /// a step for (`OnboardingPlan`). Never by itself in debug runs configured
    /// through ORBIT_DEBUG_* variables (they open it with `orbitctl
    /// open-onboarding`).
    nonisolated static func onboardingAtLaunch(hasCompleted: Bool, presented: Set<PermissionKind>,
                                               onboardingPermissions: [PermissionKind],
                                               environment: [String: String]) -> OnboardingPlan {
        #if DEBUG
        if environment.keys.contains(where: { $0.hasPrefix("ORBIT_DEBUG_") }) {
            return .none
        }
        #endif
        return OnboardingPlan.atLaunch(hasCompleted: hasCompleted, presented: presented,
                                       onboardingPermissions: onboardingPermissions)
    }
}

extension AppDelegate: AppActions {
    /// The user opens the panel (menu bar menu): with the context chips.
    func showPanel() {
        showPanel(capturingContext: true)
    }

    private func showPanel(capturingContext: Bool) {
        // A request may follow: tools need current permissions.
        environment?.permissions.refreshIfStale()
        panelController?.show(capturingContext: capturingContext)
    }

    func hidePanel() {
        panelController?.hide()
    }

    func togglePanel() {
        environment?.permissions.refreshIfStale()
        panelController?.toggle()
    }

    /// ⌘N and "New Chat" of the Chat menu and the menu bar menu.
    func startNewChat() {
        environment?.startNewChat()
    }

    func showSettings() {
        settingsController?.show()
    }

    /// Settings on `tab` (the chat's "Open Settings"); nil: the tab shown last.
    func showSettings(tab: SettingsTab?) {
        settingsController?.show(tab: tab)
    }

    func showOnboarding() {
        onboardingController?.show()
    }

    func closeKeyWindow() {
        if let keyWindow = NSApp.keyWindow, !(keyWindow is OrbitPanel) {
            keyWindow.performClose(nil)
        } else {
            hidePanel()
        }
    }

    func showAboutPanel() {
        panelController?.hide(yieldFocus: false)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

/// Answers AppKit's pending termination request exactly once, from any thread, by
/// scheduling the reply on the main run loop in its common modes (which AppKit's
/// nested termination loop runs even when the main dispatch queue is busy).
private final class TerminationReplyLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var replied = false

    func reply() {
        let shouldReply = lock.withLock {
            defer { replied = true }
            return !replied
        }
        guard shouldReply else { return }
        let mainLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        CFRunLoopWakeUp(mainLoop)
    }
}
