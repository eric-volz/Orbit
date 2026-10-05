import AppKit
import KeyboardShortcuts
import os
import Testing
@testable import Orbit

/// Results that appear next to a button in Settings or the onboarding,
/// where the keyboard stays, so VoiceOver would not notice them: the
/// connection test, macOS's answer to "Allow…", the deleted history and
/// a recorded shortcut (D3).
@MainActor
@Suite("Settings announcements")
struct SettingsAnnouncementTests {
    private func tester(_ announcer: RecordingAnnouncer, fails: LLMError? = nil) -> (ConnectionTester, SettingsStore, APIKeyEditor) {
        let settings = SettingsStore(defaults: AgentTestDefaults())
        settings.providerKind = .anthropic
        let editor = APIKeyEditor(secrets: InMemorySecretStore([SecretAccount.anthropicAPIKey: "sk-ant-test"]))
        let tester = ConnectionTester(validate: { _, _ in if let fails { throw fails } }, announcer: announcer)
        return (tester, settings, editor)
    }

    @Test func theConnectionTestsResultIsRead() async {
        let announcer = RecordingAnnouncer()
        let (tester, settings, editor) = tester(announcer)
        tester.test(settings: settings, keyEditor: editor)
        #expect(await AgentHarness.eventually { tester.state == .succeeded })
        #expect(announcer.announcements == ["Connection successful"])
        #expect(announcer.priorities == [.high])

        let failing = self.tester(announcer, fails: .invalidAPIKey)
        failing.0.test(settings: failing.1, keyEditor: failing.2)
        #expect(await AgentHarness.eventually { failing.0.state != .running && failing.0.state != .idle })
        guard case .failed(let message) = failing.0.state else {
            Issue.record("a failed test")
            return
        }
        #expect(announcer.announcements.last == message)
        // Resetting (typing) says nothing.
        failing.0.reset()
        #expect(announcer.announcements.count == 2)
        #expect(ConnectionTester.announcement(for: .running) == nil && ConnectionTester.announcement(for: .idle) == nil)
    }

    /// A failure found before connecting (no model, an invalid address) is
    /// read on every press, also when it is the same as before, so the
    /// button never seems to do nothing.
    @Test func aRepeatedFailureIsReadAgain() {
        let announcer = RecordingAnnouncer()
        let (tester, settings, editor) = tester(announcer)
        settings.anthropicModel = "  "
        tester.test(settings: settings, keyEditor: editor)
        tester.test(settings: settings, keyEditor: editor)
        #expect(announcer.announcements == ["Please enter a model.", "Please enter a model."])
        settings.anthropicModel = "claude-sonnet-5-5"
        settings.anthropicBaseURL = "ftp://example.com"
        tester.test(settings: settings, keyEditor: editor)
        tester.test(settings: settings, keyEditor: editor)
        #expect(announcer.announcements.suffix(2) == [LLMError.invalidBaseURL.userMessage, LLMError.invalidBaseURL.userMessage])
        #expect(announcer.priorities == [.high, .high, .high, .high])
        #expect(tester.state == .failed(LLMError.invalidBaseURL.userMessage))
    }

    @Test func macOSsAnswerToAllowIsRead() async {
        let access = MockPermissionAccess([.contacts: .notDetermined])
        access.answer(.contacts, with: .granted)
        let announcer = RecordingAnnouncer()
        let model = OnboardingModel(settings: SettingsStore(defaults: AgentTestDefaults()),
                                    permissions: PermissionManager(access: access, permissions: [.contacts]),
                                    secrets: InMemorySecretStore(), validate: { _, _ in },
                                    claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
                                    announcer: announcer, onFinish: {})
        await model.permissions.refresh()
        await model.request(.contacts)
        #expect(announcer.announcements.last == "Contacts: Allowed")
        #expect(PermissionCopy.requestOutcome(.automationMail, status: .denied) == "Automation: Mail: Not allowed")
    }

    /// A11Y-3: "Allow…" for Accessibility only shows macOS's hint, which leads to System Settings, and
    /// returns at once: VoiceOver hears where to turn Orbit on (not "Not allowed" while the hint opens), and
    /// the status once Orbit reads it changed (back from System Settings), once.
    @Test func accessibilityIsAnsweredInSystemSettings() async {
        let access = MockPermissionAccess([.accessibility: .denied])
        let announcer = RecordingAnnouncer()
        let model = OnboardingModel(settings: SettingsStore(defaults: AgentTestDefaults()),
                                    permissions: PermissionManager(access: access, permissions: [.accessibility]),
                                    secrets: InMemorySecretStore(), validate: { _, _ in },
                                    claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
                                    announcer: announcer, onFinish: {})
        model.go(to: .permission(.accessibility))
        await model.refreshShownPermissions()
        #expect(model.action(for: .accessibility) == .request)
        await model.request(.accessibility)
        #expect(announcer.announcements.last
            == "Accessibility: macOS shows a notice that leads to System Settings, where you turn on Orbit.")
        #expect(announcer.priorities.last == .high)

        // Back from System Settings without a change: nothing new to say.
        let afterRequest = announcer.announcements.count
        await model.refreshShownPermissions()
        #expect(announcer.announcements.count == afterRequest)

        // The user turned Orbit on there.
        access.set(.granted, for: .accessibility)
        await model.refreshShownPermissions()
        #expect(announcer.announcements.last == "Accessibility: Allowed")
        #expect(announcer.priorities.last == .high)
        await model.refreshShownPermissions()
        #expect(announcer.announcements.count == afterRequest + 1, "once")
    }

    /// Settings → Permissions hears the same (`PermissionAnswers`): macOS's answer at once for the others.
    @Test func permissionAnswersWaitForSystemSettingsOnlyForAccessibility() {
        var answers = PermissionAnswers()
        #expect(answers.requested(.contacts, status: .granted) == "Contacts: Allowed")
        #expect(answers.requested(.automationMail, status: .denied) == "Automation: Mail: Not allowed")
        #expect(answers.requested(.accessibility, status: .granted) == "Accessibility: Allowed", "already on")
        #expect(answers.statusesRead([.accessibility: .denied, .contacts: .denied]).isEmpty, "nothing awaited")

        #expect(answers.requested(.accessibility, status: .denied)
            == "Accessibility: macOS shows a notice that leads to System Settings, where you turn on Orbit.")
        #expect(answers.statusesRead([.accessibility: .denied]).isEmpty)
        #expect(answers.statusesRead([.accessibility: .granted, .contacts: .denied]) == ["Accessibility: Allowed"])
        #expect(answers.statusesRead([.accessibility: .denied]).isEmpty, "said once")
    }

    /// "Sign In…" in Settings → Model and the onboarding: VoiceOver hears how
    /// the sign-in ended: connected (the button is gone then), or why not. A
    /// sign-in the user stopped says nothing.
    @Test func howASignInEndedIsRead() async {
        let ready = ClaudeCodeStatus(availability: .ready, version: "2.1.999", subscriptionType: "max", authMethod: "claude.ai")
        let signedOut = ClaudeCodeStatus(availability: .notLoggedIn)
        let announcer = RecordingAnnouncer()
        let succeeding = ClaudeCodeAccountModel(loadStatus: { ready }, signIn: {}, announcer: announcer)
        succeeding.signIn()
        #expect(await AgentHarness.eventually { succeeding.state == .status(ready) })
        #expect(announcer.announcements == ["Connected to your Claude subscription (Max)"])
        #expect(announcer.priorities == [.high])

        let failing = ClaudeCodeAccountModel(loadStatus: { signedOut }, signIn: { throw LLMError.claudeCodeNotLoggedIn },
                                             announcer: announcer)
        failing.signIn()
        #expect(await AgentHarness.eventually { failing.state == .status(signedOut) })
        #expect(failing.signInError == "Sign-in was not completed. Please try again.")
        #expect(announcer.announcements.last == failing.signInError)
        #expect(announcer.priorities.last == .high)

        let stopped = ClaudeCodeAccountModel(loadStatus: { signedOut }, signIn: { throw LLMError.cancelled }, announcer: announcer)
        stopped.signIn()
        #expect(await AgentHarness.eventually { stopped.state == .status(signedOut) })
        #expect(announcer.announcements.count == 2)
    }

    @Test func theHistorysDeletionIsRead() {
        #expect(PrivacySettingsView.clearOutcome(true) == "Chat history deleted")
        #expect(PrivacySettingsView.clearOutcome(false) == "The chat history could not be deleted. Please try again.")
    }

    @Test func aRecordedShortcutAndWhyOneWasRefusedAreRead() {
        let name = KeyboardShortcuts.Name("orbitTestAnnouncedRecorder")
        KeyboardShortcuts.reset(name)
        defer { KeyboardShortcuts.reset(name) }
        let announcer = RecordingAnnouncer()
        let model = HotkeyRecorderModel(name: name, announcer: announcer)
        model.save(KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option]))
        #expect(announcer.announcements == ["Keyboard shortcut: ⌥⌘K"])
        model.clear()
        #expect(announcer.announcements.last == "No Shortcut")
        #expect(HotkeyRecorderModel.Feedback.needsModifier.text == "Use at least one of the keys ⌘, ⌥ or ⌃.")
        #expect(HotkeyRecorderModel.Feedback.takenByMenu("New Chat").text == "Orbit already uses this shortcut for “New Chat”.")
    }
}

/// D4: a long answer that finishes streaming is not built again as a whole.
@Suite("Answer rendering")
struct AnswerRenderingTests {
    /// While streaming, the stable paragraphs and the growing rest are two views; once complete,
    /// the whole text goes to the first (the view that showed the stable part), so SwiftUI keeps
    /// it and only rebuilds the blocks that changed.
    @Test func theCompleteAnswerKeepsTheViewOfItsStableParagraphs() {
        let text = "Erster Absatz.\n\nZweiter **Absatz** wächst noch"
        let streaming = AnswerParts(text: text, isStreaming: true)
        #expect(streaming.main == "Erster Absatz.")
        #expect(streaming.tail == "Zweiter **Absatz** wächst noch")
        let complete = AnswerParts(text: text, isStreaming: false)
        #expect(complete.main == text && complete.tail.isEmpty)
        // Before anything is stable, the growing text is the beginning: it streams in the first view too.
        // Open markers are closed only while streaming.
        let first = AnswerParts(text: "Ein **fetter", isStreaming: true)
        #expect(first.main == "Ein **fetter**" && first.tail.isEmpty)
        let done = AnswerParts(text: "Ein **fetter", isStreaming: false)
        #expect(done.main == "Ein **fetter" && done.tail.isEmpty)
    }
}
