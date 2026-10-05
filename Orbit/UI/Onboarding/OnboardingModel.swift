import Foundation
import Observation

/// The onboarding's steps and moving between them: welcome, the language
/// model (Claude subscription sign-in, or an API key and a connection test),
/// the keyboard shortcut, the permissions one by one, and a summary, or,
/// after an update that brought new permissions, only their steps and the
/// summary (`Mode.newPermissions`). Every step can be skipped; the window can
/// be closed at any time. VoiceOver hears the title of each step it moves to
/// (the content is replaced, the keyboard stays on the buttons).
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Hashable, Identifiable, Sendable {
        case welcome
        case provider
        case hotkey
        case permission(PermissionKind)
        case done

        /// "welcome", "provider", "hotkey", "done" or the permission ("automationMail").
        var id: String {
            switch self {
            case .welcome: "welcome"
            case .provider: "provider"
            case .hotkey: "hotkey"
            case .permission(let permission): permission.rawValue
            case .done: "done"
            }
        }

        init?(id: String) {
            switch id {
            case "welcome": self = .welcome
            case "provider": self = .provider
            case "hotkey": self = .hotkey
            case "done": self = .done
            default:
                guard let permission = PermissionKind(rawValue: id) else { return nil }
                self = .permission(permission)
            }
        }
    }

    /// Which steps the onboarding shows.
    enum Mode: Hashable, Sendable {
        /// The first launch and "Setup…": every step.
        case full
        /// At launch after an update: only the steps of these permissions (those
        /// new since the user last saw the onboarding), then the summary.
        case newPermissions([PermissionKind])
    }

    let mode: Mode
    let steps: [Step]
    private(set) var index = 0
    /// Permissions the user asked macOS for in this onboarding ("Allow…").
    private(set) var requested: Set<PermissionKind> = []

    let settings: SettingsStore
    let permissions: PermissionManager
    /// The API key of the model step (kept while the user moves between steps).
    let keyEditor: APIKeyEditor
    let tester: ConnectionTester
    let claudeCodeAccount: ClaudeCodeAccountModel
    @ObservationIgnored private let onFinish: @MainActor () -> Void
    @ObservationIgnored private let announcer: (any Announcing)?
    @ObservationIgnored private var answers = PermissionAnswers()

    init(settings: SettingsStore, permissions: PermissionManager, secrets: any SecretStoring,
         validate: @escaping @MainActor (ProviderConfiguration, String) async throws -> Void,
         claudeCodeAccount: ClaudeCodeAccountModel, announcer: (any Announcing)? = nil, mode: Mode = .full,
         onFinish: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.permissions = permissions
        keyEditor = APIKeyEditor(secrets: secrets)
        tester = ConnectionTester(validate: validate, announcer: announcer)
        self.claudeCodeAccount = claudeCodeAccount
        self.announcer = announcer
        self.onFinish = onFinish
        self.mode = mode
        steps = Self.steps(for: permissions.onboardingPermissions, mode: mode)
    }

    /// Welcome, model, shortcut, one step per permission, summary.
    nonisolated static func steps(for permissions: [PermissionKind]) -> [Step] {
        [.welcome, .provider, .hotkey] + permissions.map(Step.permission) + [.done]
    }

    /// The steps in a mode: all of them, or only the new permissions (those
    /// the onboarding asks for, in their order) and the summary.
    nonisolated static func steps(for permissions: [PermissionKind], mode: Mode) -> [Step] {
        switch mode {
        case .full: steps(for: permissions)
        case .newPermissions(let new): permissions.filter(new.contains).map(Step.permission) + [.done]
        }
    }

    /// The permissions this onboarding has a step for (the summary lists them;
    /// closing the onboarding counts them as seen).
    var permissionSteps: [PermissionKind] {
        steps.compactMap { step in
            if case .permission(let permission) = step { return permission }
            return nil
        }
    }

    var step: Step { steps[index] }
    var canGoBack: Bool { index > 0 }

    /// Whether the model step shows text fields (an API key, a server): Return
    /// belongs to them there, so "Continue" is the default button only without.
    var providerStepHasTextFields: Bool {
        settings.providerKind.usesAPIKey
    }

    func next() {
        leaveStep()
        if index + 1 < steps.count {
            show(index + 1)
        } else {
            onFinish()
        }
    }

    func back() {
        guard index > 0 else { return }
        tester.cancel()
        show(index - 1)
    }

    /// Jumps to a step (DEBUG automation: `orbitctl open-onboarding <step>`).
    func go(to step: Step) {
        guard let target = steps.firstIndex(of: step) else { return }
        tester.cancel()
        show(target)
    }

    /// "Later" and "Done": closes the onboarding.
    func finish() {
        leaveStep()
        onFinish()
    }

    /// Leaving a step keeps a typed API key (see `saveDraftIfNeeded`).
    private func leaveStep() {
        if step == .provider {
            tester.cancel()
        }
        saveDraftIfNeeded()
    }

    /// Stores an API key typed on the model step that is not saved yet,
    /// whichever step the onboarding is left from, also when its window is
    /// closed: Orbit only uses stored keys, and an unsaved one would be lost
    /// with the window. Going back keeps the draft without saving it.
    func saveDraftIfNeeded() {
        guard settings.providerKind.usesAPIKey, keyEditor.hasDraft, keyEditor.kind == settings.providerKind else { return }
        let editor = keyEditor
        Task { await editor.save() }
    }

    /// Shows the step at `newIndex`; VoiceOver hears which one it is.
    private func show(_ newIndex: Int) {
        guard newIndex != index else { return }
        index = newIndex
        announcer?.announce(Self.announcement(for: step, index: index, count: steps.count), priority: .high)
    }

    /// "Tastenkürzel, Schritt 3 von 7".
    nonisolated static func announcement(for step: Step, index: Int, count: Int) -> String {
        String(format: String(localized: "%1$@, step %2$lld of %3$lld"), step.title, index + 1, count)
    }

    // MARK: Permission steps

    /// What the main button of a permission step does.
    enum PermissionAction: Equatable {
        /// Ask macOS ("Allow…"; "Check…" while the app does not run).
        case request
        /// Go on ("Continue").
        case next
        /// The status is being read or requested.
        case wait
    }

    func action(for permission: PermissionKind) -> PermissionAction {
        guard let status = permissions.statuses[permission], !permissions.requesting.contains(permission) else {
            return .wait
        }
        return permission.canRequest(from: status) ? .request : .next
    }

    /// "Allow…" on a permission step: asks macOS; VoiceOver hears its
    /// answer (for Accessibility where to turn Orbit on), and the answer once
    /// Orbit reads it (`refreshShownPermissions`, see `PermissionAnswers`).
    func request(_ permission: PermissionKind) async {
        requested.insert(permission)
        await permissions.request(permission)
        announcer?.announce(answers.requested(permission, status: shownStatus(of: permission)), priority: .high)
    }

    /// The status a step shows. macOS knows Accessibility only as allowed or
    /// not ("not allowed" also before Orbit ever asked), so until the user
    /// clicked "Allow…" in this onboarding it shows as not asked yet: the
    /// step explains how macOS asks instead of starting with a warning.
    func shownStatus(of permission: PermissionKind) -> PermissionStatus? {
        let status = permissions.statuses[permission]
        if permission == .accessibility, status == .denied, !requested.contains(permission) {
            return .notDetermined
        }
        return status
    }

    /// The permissions the current step shows: its own on a permission step,
    /// all of this onboarding's in the summary.
    var shownPermissions: [PermissionKind] {
        switch step {
        case .permission(let permission): [permission]
        case .done: permissionSteps
        case .welcome, .provider, .hotkey: []
        }
    }

    /// Reads what the current step shows again: when the step appears, and
    /// when Orbit becomes active (back from System Settings, where the user
    /// may have switched Orbit on).
    func refreshShownPermissions() async {
        await permissions.refresh(shownPermissions)
        for answer in answers.statusesRead(permissions.statuses) {
            announcer?.announce(answer, priority: .high)
        }
    }
}

/// Which onboarding Orbit shows by itself at launch: the whole one until it
/// was seen once; afterwards (once) only the steps of permissions the user
/// never had a step for (an update brought tools that need them). Every other
/// launch shows none; the menu bar menu always opens the whole onboarding.
enum OnboardingPlan: Hashable, Sendable {
    case none
    case full
    case newPermissions([PermissionKind])

    /// The plan for this launch. `presented`: the permissions earlier
    /// onboardings had a step for (`SettingsStore.presentedOnboardingPermissions`).
    static func atLaunch(hasCompleted: Bool, presented: Set<PermissionKind>,
                         onboardingPermissions: [PermissionKind]) -> OnboardingPlan {
        guard hasCompleted else { return .full }
        let new = onboardingPermissions.filter { !presented.contains($0) }
        return new.isEmpty ? .none : .newPermissions(new)
    }

    /// The onboarding's mode for the plan; nil for `.none`.
    var mode: OnboardingModel.Mode? {
        switch self {
        case .none: nil
        case .full: .full
        case .newPermissions(let permissions): .newPermissions(permissions)
        }
    }
}
