import AppKit
import os
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// A11Y-2 and ONB-1: the onboarding from the keyboard: Return is the main
    /// button (on the model step only without text fields), Escape skips, and
    /// closing its window keeps a typed API key. The view runs in an offscreen
    /// panel on mocks (permissions, Claude Code, keys in memory); the window
    /// controller's window is made but never shown.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter OnboardingKeyboard
    @MainActor
    @Suite("OnboardingKeyboard", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct OnboardingKeyboardTests {
        struct Harness {
            let model: OnboardingModel
            let settings: SettingsStore
            let access: MockPermissionAccess
            let panel: OffscreenKeyPanel
            let finished: () -> Int
        }

        private func makeHarness(provider: ProviderKind) async throws -> Harness {
            _ = NSApplication.shared
            let settings = SettingsStore(defaults: AgentTestDefaults())
            settings.providerKind = provider
            let access = MockPermissionAccess([.automationMail: .notDetermined, .automationNotes: .notDetermined,
                                               .contacts: .notDetermined])
            let ready = ClaudeCodeStatus(availability: .ready, executablePath: "/Applications-Orbit-Test/claude", version: "2.1.284",
                                         subscriptionType: "max", authMethod: "claude.ai")
            let counter = OSAllocatedUnfairLock(initialState: 0)
            let model = OnboardingModel(
                settings: settings,
                permissions: PermissionManager(access: access, permissions: [.automationMail, .automationNotes, .contacts]),
                secrets: InMemorySecretStore(), validate: { _, _ in },
                claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { ready }, signIn: {}),
                announcer: RecordingAnnouncer(),
                onFinish: { counter.withLock { $0 += 1 } }
            )
            let panel = OffscreenKeyPanel(size: OnboardingView.size)
            panel.contentView = NSHostingView(rootView: OnboardingView(model: model))
            panel.makeKeyAndOrderFront(nil)
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)
            return Harness(model: model, settings: settings, access: access, panel: panel,
                           finished: { counter.withLock { $0 } })
        }

        /// Return or Escape as a key window handles them: the default and cancel
        /// buttons' key equivalents first, then the focused view.
        private func press(_ harness: Harness, keyCode: UInt16, characters: String) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: harness.panel.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: keyCode) else { continue }
                if type == .keyDown, harness.panel.performKeyEquivalent(with: event) {
                    continue
                }
                NSApp.sendEvent(event)
            }
            await SnapshotRenderer.settle(0.2)
        }

        private func pressReturn(_ harness: Harness) async {
            await press(harness, keyCode: 36, characters: "\r")
        }

        private func pressEscape(_ harness: Harness) async {
            await press(harness, keyCode: 53, characters: "\u{1B}")
        }

        /// UX-2: back from System Settings (Orbit becomes active), the step shows what the user allowed there.
        @Test func becomingActiveReadsTheStepsPermissionAgain() async throws {
            _ = NSApplication.shared
            let access = MockPermissionAccess([.accessibility: .denied])
            let model = OnboardingModel(settings: SettingsStore(defaults: AgentTestDefaults()),
                                        permissions: PermissionManager(access: access, permissions: [.accessibility]),
                                        secrets: InMemorySecretStore(), validate: { _, _ in },
                                        claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
                                        mode: .newPermissions([.accessibility]), onFinish: {})
            let panel = OffscreenKeyPanel(size: OnboardingView.size)
            panel.contentView = NSHostingView(rootView: OnboardingView(model: model))
            panel.makeKeyAndOrderFront(nil)
            defer { panel.orderOut(nil) }
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)
            #expect(model.step == .permission(.accessibility))
            #expect(model.permissions.statuses[.accessibility] == .denied, "read when the step appeared")
            access.set(.granted, for: .accessibility)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            #expect(await AgentHarness.eventually { model.permissions.statuses[.accessibility] == .granted })
            await SnapshotRenderer.settle(0.1)
            #expect(model.action(for: .accessibility) == .next, "the step now offers “Continue”")
        }

        @Test func returnGoesOnFromTheModelStepWithTheClaudeSubscription() async throws {
            let harness = try await makeHarness(provider: .claudeCode)
            defer { harness.panel.orderOut(nil) }
            await pressReturn(harness)
            #expect(harness.model.step == .provider, "Return is “Get Started” on the welcome step")
            await pressReturn(harness)
            #expect(harness.model.step == .hotkey, "no text field on the step: Return is “Continue”")
        }

        @Test func returnBelongsToTheTextFieldsOfAnAPIProvider() async throws {
            let harness = try await makeHarness(provider: .anthropic)
            defer { harness.panel.orderOut(nil) }
            harness.model.go(to: .provider)
            await SnapshotRenderer.settle(0.3)
            await pressReturn(harness)
            #expect(harness.model.step == .provider)
        }

        @Test func escapeSkipsAPermissionAndLeavesFromTheWelcome() async throws {
            let harness = try await makeHarness(provider: .claudeCode)
            defer { harness.panel.orderOut(nil) }
            harness.model.go(to: .permission(.automationMail))
            await SnapshotRenderer.settle(0.3)
            await pressEscape(harness)
            #expect(harness.model.step == .permission(.automationNotes), "“Skip”")
            #expect(harness.access.requests.isEmpty, "nothing was asked")
            harness.model.go(to: .welcome)
            await SnapshotRenderer.settle(0.3)
            await pressEscape(harness)
            #expect(harness.finished() == 1, "“Later”")
        }

        /// ONB-1: the close button and ⌘W leave from any step; a key typed on
        /// the model step is stored before the window lets go of the model.
        @Test func closingTheWindowKeepsATypedKey() async throws {
            _ = NSApplication.shared
            let environment = SnapshotEnvironment.make()
            environment.settings.providerKind = .anthropic
            let controller = OnboardingWindowController(environment: environment, hidePanel: {})
            let window = controller.prepareWindow()
            defer { window.orderOut(nil) }
            #expect(!window.isVisible)
            let model = try #require(controller.model)
            await model.keyEditor.load(kind: .anthropic)
            model.keyEditor.draft = "sk-ant-closing"
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            #expect(controller.model == nil && controller.window == nil)
            #expect(environment.settings.hasCompletedOnboarding)
            #expect(await AgentHarness.eventually {
                (try? environment.secrets.secret(for: SecretAccount.anthropicAPIKey)) == "sk-ant-closing"
            })
        }
    }
}
