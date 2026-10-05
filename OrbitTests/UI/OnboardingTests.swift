import Foundation
import os
import Testing
@testable import Orbit

/// What `ConnectionTester` validated.
private final class ValidationLog: Sendable {
    private let state = OSAllocatedUnfairLock<[(ProviderConfiguration, String)]>(initialState: [])
    var calls: [(ProviderConfiguration, String)] { state.withLock { $0 } }
    func record(_ configuration: ProviderConfiguration, _ model: String) { state.withLock { $0.append((configuration, model)) } }
}

@Suite("Onboarding")
@MainActor
struct OnboardingTests {
    private struct Setup {
        let model: OnboardingModel
        let settings: SettingsStore
        let secrets: InMemorySecretStore
        let access: MockPermissionAccess
        let finished: () -> Int
    }

    private func setup(permissions: [PermissionKind] = [.automationMail, .automationNotes, .contacts, .fullDiskAccess],
                       access: MockPermissionAccess = MockPermissionAccess(),
                       announcer: RecordingAnnouncer? = nil) -> Setup {
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let secrets = InMemorySecretStore()
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let model = OnboardingModel(
            settings: settings, permissions: PermissionManager(access: access, permissions: permissions), secrets: secrets,
            validate: { _, _ in },
            claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
            announcer: announcer,
            onFinish: { counter.withLock { $0 += 1 } }
        )
        return Setup(model: model, settings: settings, secrets: secrets, access: access, finished: { counter.withLock { $0 } })
    }

    // MARK: Steps

    @Test func stepsAreWelcomeModelShortcutThePermissionsAndASummary() {
        let model = setup().model
        #expect(model.steps == [.welcome, .provider, .hotkey, .permission(.automationMail), .permission(.automationNotes),
                                .permission(.contacts), .done])
        #expect(model.step == .welcome)
        #expect(!model.canGoBack)
        #expect(OnboardingModel.steps(for: []) == [.welcome, .provider, .hotkey, .done])
    }

    @Test func stepIDsNameTheSteps() {
        for step in setup().model.steps {
            #expect(OnboardingModel.Step(id: step.id) == step)
        }
        #expect(OnboardingModel.Step.permission(.automationMail).id == "automationMail")
        #expect(OnboardingModel.Step(id: "calendars") == .permission(.calendars))
        #expect(OnboardingModel.Step(id: "mail") == nil)
        #expect(OnboardingModel.Step(id: "") == nil)
    }

    @Test func goingThroughEveryStepFinishesOnce() {
        let setup = setup()
        let model = setup.model
        for expected in model.steps.dropFirst() {
            model.next()
            #expect(model.step == expected)
        }
        #expect(setup.finished() == 0)
        model.next()
        #expect(setup.finished() == 1)
        #expect(model.step == .done)
    }

    @Test func backStopsAtTheWelcome() {
        let model = setup().model
        model.back()
        #expect(model.step == .welcome)
        model.next()
        model.next()
        model.back()
        #expect(model.step == .provider)
        #expect(model.canGoBack)
    }

    @Test func laterAndDoneCloseTheOnboarding() {
        let setup = setup()
        setup.model.finish()
        #expect(setup.finished() == 1)
        setup.model.go(to: .done)
        #expect(setup.model.step == .done)
        setup.model.finish()
        #expect(setup.finished() == 2)
    }

    @Test func jumpingToAStepThatIsNotThereChangesNothing() {
        let model = setup(permissions: [.contacts]).model
        model.go(to: .permission(.automationMail))
        #expect(model.step == .welcome)
        model.go(to: .permission(.contacts))
        #expect(model.step == .permission(.contacts))
    }

    // MARK: Model step

    @Test func aTypedKeyIsKeptWhenMovingOn() async throws {
        let setup = setup()
        setup.settings.providerKind = .anthropic
        await setup.model.keyEditor.load(kind: .anthropic)
        setup.model.go(to: .provider)
        setup.model.keyEditor.draft = "  sk-ant-onboarding  "
        setup.model.next()
        #expect(setup.model.step == .hotkey)
        #expect(await AgentHarness.eventually { setup.model.keyEditor.status == .saved })
        #expect(try setup.secrets.secret(for: SecretAccount.anthropicAPIKey) == "sk-ant-onboarding")
        #expect(setup.model.keyEditor.draft.isEmpty)
    }

    @Test func goingBackKeepsTheDraftWithoutSavingIt() async throws {
        let setup = setup()
        setup.settings.providerKind = .anthropic
        await setup.model.keyEditor.load(kind: .anthropic)
        setup.model.go(to: .provider)
        setup.model.keyEditor.draft = "sk-ant-draft"
        setup.model.back()
        try await Task.sleep(for: .milliseconds(30))
        #expect(try setup.secrets.secret(for: SecretAccount.anthropicAPIKey) == nil)
        #expect(setup.model.keyEditor.draft == "sk-ant-draft")
    }

    /// ONB-1: "Later" after going back to the welcome step keeps the key
    /// typed on the model step (it was lost before).
    @Test func aTypedKeyIsKeptWhenTheOnboardingIsLeftFromAnotherStep() async throws {
        let setup = setup()
        setup.settings.providerKind = .anthropic
        await setup.model.keyEditor.load(kind: .anthropic)
        setup.model.go(to: .provider)
        setup.model.keyEditor.draft = "sk-ant-typed"
        setup.model.back()
        #expect(setup.model.step == .welcome)
        setup.model.finish()
        #expect(await AgentHarness.eventually { (try? setup.secrets.secret(for: SecretAccount.anthropicAPIKey)) == "sk-ant-typed" })
        #expect(setup.finished() == 1)
    }

    /// ONB-1: closing the window (close button, ⌘W) saves a typed key through
    /// `saveDraftIfNeeded`; the window controller calls it before it drops
    /// the model (gated: `OnboardingKeyboardTests`).
    @Test func savingADraftWorksFromAnyStepAndOnlyForTheChosenProvider() async throws {
        let setup = setup()
        setup.settings.providerKind = .openAICompatible
        await setup.model.keyEditor.load(kind: .openAICompatible)
        setup.model.keyEditor.draft = "sk-local"
        setup.model.go(to: .permission(.contacts))
        setup.model.saveDraftIfNeeded()
        #expect(await AgentHarness.eventually { (try? setup.secrets.secret(for: SecretAccount.apiKey(for: .openAICompatible))) == "sk-local" })

        // A draft for another provider than the chosen one is not saved.
        let other = self.setup()
        other.settings.providerKind = .anthropic
        await other.model.keyEditor.load(kind: .anthropic)
        other.model.keyEditor.draft = "sk-ant-other"
        other.settings.providerKind = .claudeCode
        other.model.saveDraftIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(try other.secrets.secret(for: SecretAccount.anthropicAPIKey) == nil)
    }

    @Test func theClaudeSubscriptionStoresNoKey() async throws {
        let setup = setup()
        setup.settings.providerKind = .claudeCode
        setup.model.go(to: .provider)
        setup.model.keyEditor.draft = "sk-ant-ignored"
        setup.model.next()
        try await Task.sleep(for: .milliseconds(30))
        #expect(try setup.secrets.secret(for: SecretAccount.apiKey(for: .claudeCode)) == nil)
        #expect(try setup.secrets.secret(for: SecretAccount.anthropicAPIKey) == nil)
    }

    // MARK: Keyboard and VoiceOver (A11Y-2)

    /// The content of a step is replaced: VoiceOver hears the new step's title
    /// and position, whichever way the user moved.
    @Test func voiceOverHearsEachNewStep() {
        let announcer = RecordingAnnouncer()
        let model = setup(announcer: announcer).model
        model.next()
        #expect(announcer.announcements == ["Language Model, step 2 of 7"])
        #expect(announcer.priorities == [.high])
        model.next()
        model.back()
        #expect(announcer.announcements.suffix(2) == ["Keyboard Shortcut, step 3 of 7", "Language Model, step 2 of 7"])
        model.go(to: .permission(.automationMail))
        #expect(announcer.announcements.last == "Mail, step 4 of 7")
        model.go(to: .done)
        #expect(announcer.announcements.last == "All Set, step 7 of 7")
        let heard = announcer.announcements.count
        model.go(to: .done)
        model.back()
        model.go(to: .permission(.automationMail))
        model.back()
        model.back()
        model.back()
        model.back()
        #expect(model.step == .welcome)
        model.back()
        #expect(announcer.announcements.count == heard + 5, "staying on a step says nothing")
        #expect(announcer.announcements.last == "Welcome to Orbit, step 1 of 7")
    }

    /// Return presses "Continue" on the model step only when no text field
    /// needs it: with the Claude subscription there is none.
    @Test func theModelStepHasTextFieldsOnlyForAPIProviders() {
        let setup = setup()
        setup.settings.providerKind = .claudeCode
        #expect(!setup.model.providerStepHasTextFields)
        setup.settings.providerKind = .anthropic
        #expect(setup.model.providerStepHasTextFields)
        setup.settings.providerKind = .openAICompatible
        #expect(setup.model.providerStepHasTextFields)
    }

    /// Voice Control: a button's label contains the title it shows ("Click
    /// Check" must find "Check…").
    @Test func permissionButtonLabelsContainTheirVisibleTitles() {
        for permission in PermissionKind.allCases {
            for status in [PermissionStatus.notDetermined, .granted, .denied, .restricted, .unknown] {
                let title = PermissionCopy.actionTitle(permission, status: status)
                    .replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
                let label = PermissionCopy.actionAccessibilityLabel(permission, status: status)
                #expect(label.localizedCaseInsensitiveContains(title), "\(permission) \(status): \(label) / \(title)")
                #expect(label.contains(permission.displayName))
            }
        }
        #expect(PermissionCopy.actionAccessibilityLabel(.automationMail, status: .unknown) == "Check Automation: Mail")
        #expect(PermissionCopy.actionAccessibilityLabel(.automationMail, status: .notDetermined) == "Allow Automation: Mail")
        // The onboarding's button always reads "Allow…".
        #expect(PermissionCopy.requestAccessibilityLabel(.automationNotes) == "Allow Automation: Notes")
    }

    // MARK: Permission steps

    @Test func thePermissionButtonAsksOnlyWhenMacOSCan() async {
        let access = MockPermissionAccess([.automationMail: .notDetermined, .automationNotes: .unknown, .contacts: .denied,
                                           .fullDiskAccess: .granted])
        let setup = setup(access: access)
        let model = setup.model
        #expect(model.action(for: .automationMail) == .wait, "not read yet")
        await model.permissions.refresh()
        #expect(model.action(for: .automationMail) == .request)
        #expect(model.action(for: .automationNotes) == .request, "Notes is started first, then macOS answers")
        #expect(model.action(for: .contacts) == .next, "macOS does not ask again: System Settings")
        access.set(.granted, for: .contacts)
        await model.permissions.refresh([.contacts])
        #expect(model.action(for: .contacts) == .next)
    }

    @Test func whileMacOSAsksTheButtonWaits() async {
        let access = MockPermissionAccess([.contacts: .notDetermined])
        access.answer(.contacts, with: .granted)
        access.holdRequests()
        let model = setup(access: access).model
        await model.permissions.refresh()
        let request = Task { await model.permissions.request(.contacts) }
        #expect(await AgentHarness.eventually { model.action(for: .contacts) == .wait })
        access.releaseRequests()
        await request.value
        #expect(model.action(for: .contacts) == .next)
        #expect(model.permissions.statuses[.contacts] == .granted)
    }

    /// The onboarding an existing user sees after the update with the context steps.
    private func contextOnboarding(_ access: MockPermissionAccess) -> OnboardingModel {
        OnboardingModel(settings: SettingsStore(defaults: AgentTestDefaults()),
                        permissions: PermissionManager(access: access, permissions: [.automationMail, .automationFinder, .accessibility]),
                        secrets: InMemorySecretStore(), validate: { _, _ in },
                        claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
                        mode: .newPermissions([.automationFinder, .accessibility]), onFinish: {})
    }

    /// UX-2: back from System Settings (Orbit becomes active) the step reads its permission again, and the summary
    /// reads every permission it lists, so it shows "Allowed" once the user switched Orbit on.
    @Test func theStepShownReadsItsPermissionsAgain() async {
        let access = MockPermissionAccess([.accessibility: .denied, .automationFinder: .notDetermined])
        let model = contextOnboarding(access)
        #expect(model.steps == [.permission(.automationFinder), .permission(.accessibility), .done])
        #expect(model.shownPermissions == [.automationFinder])
        model.next()
        #expect(model.shownPermissions == [.accessibility])
        await model.refreshShownPermissions()
        #expect(access.reads == [.accessibility], "only what the step shows")
        await model.request(.accessibility)
        #expect(model.permissions.statuses[.accessibility] == .denied, "macOS's dialog leads to System Settings")

        access.set(.granted, for: .accessibility)
        await model.refreshShownPermissions()
        #expect(model.permissions.statuses[.accessibility] == .granted)
        #expect(model.action(for: .accessibility) == .next)

        access.set(.granted, for: .automationFinder)
        model.next()
        #expect(model.step == .done && model.shownPermissions == [.automationFinder, .accessibility])
        await model.refreshShownPermissions()
        #expect(model.shownStatus(of: .automationFinder) == .granted && model.shownStatus(of: .accessibility) == .granted,
                "the summary lists what the user allowed meanwhile")
        let welcome = setup().model
        #expect(welcome.shownPermissions.isEmpty, "the welcome step shows no permission")
    }

    /// UX-2: macOS reports an Accessibility Orbit never asked for as "not allowed"; the step shows it as not asked
    /// yet (and how macOS asks) until the user clicked "Allow…" here.
    @Test func untrustedAccessibilityLooksNeutralUntilTheUserAsked() async {
        let access = MockPermissionAccess([.accessibility: .denied, .automationFinder: .denied, .automationMail: .denied])
        let model = contextOnboarding(access)
        await model.permissions.refresh()
        #expect(model.permissions.statuses[.accessibility] == .denied)
        #expect(model.shownStatus(of: .accessibility) == .notDetermined)
        #expect(model.action(for: .accessibility) == .request)
        #expect(model.shownStatus(of: .automationFinder) == .denied, "an Apple Events refusal is the user's answer")
        #expect(model.shownStatus(of: .automationMail) == .denied)
        await model.request(.accessibility)
        #expect(access.requests == [.accessibility])
        #expect(model.shownStatus(of: .accessibility) == .denied, "after asking, \"Nicht erlaubt\" is the truth")
        model.go(to: .permission(.accessibility))
        access.set(.granted, for: .accessibility)
        await model.refreshShownPermissions()
        #expect(model.shownStatus(of: .accessibility) == .granted)
    }

    // MARK: Launch

    @Test func theOnboardingOpensByItselfUntilItWasSeen() {
        let all: [PermissionKind] = [.automationMail, .automationNotes, .contacts]
        func plan(_ completed: Bool, _ environment: [String: String]) -> OnboardingPlan {
            AppDelegate.onboardingAtLaunch(hasCompleted: completed, presented: completed ? Set(all) : [],
                                           onboardingPermissions: all, environment: environment)
        }
        #expect(plan(false, [:]) == .full)
        #expect(plan(true, [:]) == OnboardingPlan.none)
        #expect(plan(false, ["HOME": "/Users/test", "ORBIT_DATA_DIR": "/tmp/x"]) == .full)
        #if DEBUG
        #expect(plan(false, ["ORBIT_DEBUG_PROVIDER": "anthropic"]) == OnboardingPlan.none,
                "automated debug runs open it on request only")
        #expect(plan(false, ["ORBIT_DEBUG_FAKE_PERSONAL_DATA": "/tmp/x"]) == OnboardingPlan.none)
        #expect(AppDelegate.onboardingAtLaunch(hasCompleted: true, presented: [], onboardingPermissions: [.calendars],
                                               environment: ["ORBIT_DEBUG_AUTOMATION": "1"]) == OnboardingPlan.none)
        #endif
    }

    // MARK: Only new permission steps (D6)

    /// Existing users see the onboarding once more, with only the permission
    /// steps they never had, then the summary.
    @Test func afterAnUpdateOnlyTheNewPermissionStepsAppear() {
        let now: [PermissionKind] = [.automationMail, .automationNotes, .contacts, .calendars, .reminders]
        let phase3: Set<PermissionKind> = [.automationMail, .automationNotes, .contacts]
        #expect(OnboardingPlan.atLaunch(hasCompleted: true, presented: phase3, onboardingPermissions: now)
            == .newPermissions([.calendars, .reminders]))
        #expect(OnboardingPlan.atLaunch(hasCompleted: true, presented: Set(now), onboardingPermissions: now) == OnboardingPlan.none)
        #expect(OnboardingPlan.atLaunch(hasCompleted: false, presented: phase3, onboardingPermissions: now) == .full,
                "a first launch shows every step")
        #expect(OnboardingPlan.atLaunch(hasCompleted: true, presented: [.calendars], onboardingPermissions: [.calendars, .photos])
            == .newPermissions([.photos]))
        #expect(OnboardingPlan.none.mode == nil)
        #expect(OnboardingPlan.full.mode == .full)
        #expect(OnboardingPlan.newPermissions([.photos]).mode == .newPermissions([.photos]))
    }

    @Test func theNewPermissionsOnboardingHasOnlyTheirStepsAndTheSummary() {
        let permissions: [PermissionKind] = [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .fullDiskAccess]
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let model = OnboardingModel(
            settings: settings, permissions: PermissionManager(access: MockPermissionAccess(), permissions: permissions),
            secrets: InMemorySecretStore(), validate: { _, _ in },
            claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
            mode: .newPermissions([.reminders, .calendars, .fullDiskAccess]), onFinish: {})
        #expect(model.steps == [.permission(.calendars), .permission(.reminders), .done], "in display order, never Full Disk Access")
        #expect(model.permissionSteps == [.calendars, .reminders])
        #expect(!model.canGoBack, "nothing before the first new step")
        #expect(OnboardingModel.steps(for: [.contacts], mode: .full) == [.welcome, .provider, .hotkey, .permission(.contacts), .done])
        #expect(OnboardingModel.steps(for: [.contacts], mode: .newPermissions([])) == [.done])
    }

    /// Calendars, reminders, photos, accessibility and Automation: Finder get
    /// onboarding steps; Automation: System Events and Photos (macOS asks on
    /// first use) and Full Disk Access only appear in Settings.
    @Test func someNewPermissionsOnlyAppearInSettings() {
        let manager = PermissionManager(access: MockPermissionAccess(), permissions: PermissionKind.displayOrder)
        #expect(manager.onboardingPermissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
                                                  .automationFinder, .accessibility])
        #expect(PermissionKind.settingsOnly == [.fullDiskAccess, .automationSystemEvents, .automationPhotos])
    }

    @Test func thePresentedPermissionsAreRemembered() {
        let defaults = AgentTestDefaults()
        let fresh = SettingsStore(defaults: defaults)
        #expect(fresh.presentedOnboardingPermissions.isEmpty, "a new user saw no step yet")
        fresh.presentedOnboardingPermissions.formUnion([.calendars, .contacts])
        #expect(defaults.stringArray(forKey: "presentedOnboardingPermissions") == ["calendars", "contacts"])
        #expect(SettingsStore(defaults: defaults).presentedOnboardingPermissions == [.calendars, .contacts])

        // Users of the version before: the onboarding they completed asked for Mail, Notes and Contacts.
        let earlier = AgentTestDefaults()
        earlier.set(true, forKey: "hasCompletedOnboarding")
        #expect(SettingsStore(defaults: earlier).presentedOnboardingPermissions == [.automationMail, .automationNotes, .contacts])
        earlier.set(["calendars", "somethingNew"], forKey: "presentedOnboardingPermissions")
        #expect(SettingsStore(defaults: earlier).presentedOnboardingPermissions == [.calendars], "unknown names are dropped")
    }

    @Test func seeingTheOnboardingIsRemembered() {
        let defaults = AgentTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.hasCompletedOnboarding)
        settings.hasCompletedOnboarding = true
        #expect(SettingsStore(defaults: defaults).hasCompletedOnboarding)
        #expect(defaults.object(forKey: "hasOpenedSettingsForSetup") == nil, "Phase 1's setup flag is gone")
    }
}

@Suite("Connection test")
@MainActor
struct ConnectionTesterTests {
    @Test func theModelAndTheAddressAreCheckedFirst() {
        let log = ValidationLog()
        let tester = ConnectionTester { configuration, model in log.record(configuration, model) }
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let editor = APIKeyEditor(secrets: InMemorySecretStore())
        settings.providerKind = .openAICompatible
        settings.openAIModel = "  "
        tester.test(settings: settings, keyEditor: editor)
        #expect(tester.state == .failed("Please enter a model."))
        settings.openAIModel = "gpt-oss:20b"
        settings.openAIBaseURL = "kein server"
        tester.test(settings: settings, keyEditor: editor)
        #expect(tester.state == .failed(LLMError.invalidBaseURL.userMessage))
        settings.openAIBaseURL = "http://pc.fritz.box:11434/v1"
        tester.test(settings: settings, keyEditor: editor)
        #expect(tester.state == .failed(LLMError.network(.insecureConnectionBlocked).userMessage))
        #expect(log.calls.isEmpty)
        tester.reset()
        #expect(tester.state == .idle)
    }

    @Test func aTypedKeyThatWorksIsKept() async throws {
        let log = ValidationLog()
        let tester = ConnectionTester { configuration, model in log.record(configuration, model) }
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let secrets = InMemorySecretStore()
        let editor = APIKeyEditor(secrets: secrets)
        settings.providerKind = .anthropic
        await editor.load(kind: .anthropic)
        editor.draft = "sk-ant-works"
        tester.test(settings: settings, keyEditor: editor)
        #expect(tester.state == .running)
        #expect(await AgentHarness.eventually { tester.state == .succeeded })
        #expect(log.calls.map(\.0.apiKey) == ["sk-ant-works"])
        #expect(log.calls.map(\.1) == [SettingsStore.defaultAnthropicModel])
        #expect(try secrets.secret(for: SecretAccount.anthropicAPIKey) == "sk-ant-works")
    }

    /// "Test Connection" says what to check where the requests go: start
    /// the server on this Mac, or check the address of another one.
    @Test func connectionFailuresSayWhatToCheck() async {
        let tester = ConnectionTester { _, _ in throw LLMError.network(.cannotConnect) }
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let editor = APIKeyEditor(secrets: InMemorySecretStore())
        settings.providerKind = .openAICompatible
        settings.openAIModel = "gpt-oss:20b"
        tester.test(settings: settings, keyEditor: editor)
        #expect(await AgentHarness.eventually {
            tester.state == .failed(LLMError.network(.cannotConnect).userMessage(for: .thisMac(address: "localhost:11434")))
        })
        settings.openAIBaseURL = "https://llm.example.com/v1"
        tester.test(settings: settings, keyEditor: editor)
        #expect(await AgentHarness.eventually {
            tester.state == .failed(LLMError.network(.cannotConnect).userMessage(for: .server(address: "llm.example.com")))
        })
    }

    @Test func aRejectedKeyIsNotKept() async throws {
        let tester = ConnectionTester { _, _ in throw LLMError.invalidAPIKey }
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let secrets = InMemorySecretStore()
        let editor = APIKeyEditor(secrets: secrets)
        settings.providerKind = .anthropic
        await editor.load(kind: .anthropic)
        editor.draft = "sk-ant-wrong"
        tester.test(settings: settings, keyEditor: editor)
        #expect(await AgentHarness.eventually { tester.state == .failed(LLMError.invalidAPIKey.userMessage) })
        #expect(try secrets.secret(for: SecretAccount.anthropicAPIKey) == nil)
    }
}
