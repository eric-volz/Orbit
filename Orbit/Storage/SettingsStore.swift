import Foundation
import Observation

/// Non-secret settings, persisted in UserDefaults. API keys are in the keychain
/// (`SecretStoring`), never here.
@MainActor
@Observable
final class SettingsStore {
    static let defaultAnthropicModel = "claude-sonnet-5-5"
    /// Claude Code model alias; resolves to the CLI's current Sonnet.
    static let defaultClaudeCodeModel = "sonnet"
    static let defaultOpenAIBaseURL = "http://localhost:11434/v1"
    static let defaultEffort: ReasoningEffort = .low

    @ObservationIgnored private let defaults: UserDefaults
    /// DEBUG launch overrides (ORBIT_DEBUG_*): applied in memory, never persisted.
    @ObservationIgnored private var persistsChanges = true

    var providerKind: ProviderKind {
        didSet { store(providerKind.rawValue, Key.providerKind) }
    }

    var anthropicModel: String {
        didSet { store(anthropicModel, Key.anthropicModel) }
    }

    /// Empty = https://api.anthropic.com. Other values point to proxies or
    /// Anthropic-compatible servers (e.g. Ollama at http://localhost:11434).
    var anthropicBaseURL: String {
        didSet { store(anthropicBaseURL, Key.anthropicBaseURL) }
    }

    var openAIModel: String {
        didSet { store(openAIModel, Key.openAIModel) }
    }

    /// Chat Completions base URL, e.g. http://localhost:11434/v1 (Ollama),
    /// http://localhost:1234/v1 (LM Studio) or https://api.openai.com/v1.
    var openAIBaseURL: String {
        didSet { store(openAIBaseURL, Key.openAIBaseURL) }
    }

    /// Claude Code: model alias (sonnet, opus, haiku) or full model id.
    var claudeCodeModel: String {
        didSet { store(claudeCodeModel, Key.claudeCodeModel) }
    }

    /// Claude Code: explicit path of the `claude` executable; empty = auto-detect.
    var claudeCodePath: String {
        didSet { store(claudeCodePath, Key.claudeCodePath) }
    }

    /// nil = do not send an effort setting.
    var effort: ReasoningEffort? {
        didSet { store(effort?.rawValue ?? "", Key.effort) }
    }

    /// Tools the user switched off.
    var disabledToolNames: Set<String> {
        didSet { store(Array(disabledToolNames).sorted(), Key.disabledToolNames) }
    }

    /// The onboarding was seen (finished, skipped or closed); it then no
    /// longer opens by itself at launch.
    var hasCompletedOnboarding: Bool {
        didSet { store(hasCompletedOnboarding, Key.hasCompletedOnboarding) }
    }

    /// The permissions an onboarding has shown a step for (it was closed
    /// afterwards). A permission that is new since then gets its step once
    /// more at launch, without the rest of the onboarding (`OnboardingPlan`).
    var presentedOnboardingPermissions: Set<PermissionKind> {
        didSet { store(presentedOnboardingPermissions.map(\.rawValue).sorted(), Key.presentedOnboardingPermissions) }
    }

    /// What the onboarding asked for before Orbit remembered its permission
    /// steps (the mail, notes and contact tools): assumed seen by everyone who
    /// completed that onboarding.
    static let firstOnboardingPermissions: Set<PermissionKind> = [.automationMail, .automationNotes, .contacts]

    /// The chat the user left with "New Chat"; it is not restored at the next launch.
    var dismissedConversationID: UUID? {
        didSet { store(dismissedConversationID?.uuidString ?? "", Key.dismissedConversationID) }
    }

    /// "Use the selection when opening": opening the panel takes the Finder
    /// selection or the selected text of the frontmost app as context chips
    /// (`ContextCapture`). On by default.
    var capturesSelectionOnOpen: Bool {
        didSet { store(capturesSelectionOnOpen, Key.capturesSelectionOnOpen) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        providerKind = defaults.string(forKey: Key.providerKind).flatMap(ProviderKind.init(rawValue:)) ?? .anthropic
        anthropicModel = defaults.string(forKey: Key.anthropicModel).nonEmpty ?? Self.defaultAnthropicModel
        anthropicBaseURL = defaults.string(forKey: Key.anthropicBaseURL) ?? ""
        openAIModel = defaults.string(forKey: Key.openAIModel) ?? ""
        openAIBaseURL = defaults.string(forKey: Key.openAIBaseURL).nonEmpty ?? Self.defaultOpenAIBaseURL
        claudeCodeModel = defaults.string(forKey: Key.claudeCodeModel).nonEmpty ?? Self.defaultClaudeCodeModel
        claudeCodePath = defaults.string(forKey: Key.claudeCodePath) ?? ""
        if let stored = defaults.string(forKey: Key.effort) {
            effort = ReasoningEffort(rawValue: stored)
        } else {
            effort = Self.defaultEffort
        }
        disabledToolNames = Set(defaults.stringArray(forKey: Key.disabledToolNames) ?? [])
        let completed = defaults.bool(forKey: Key.hasCompletedOnboarding)
        hasCompletedOnboarding = completed
        if let presented = defaults.stringArray(forKey: Key.presentedOnboardingPermissions) {
            presentedOnboardingPermissions = Set(presented.compactMap(PermissionKind.init(rawValue:)))
        } else {
            presentedOnboardingPermissions = completed ? Self.firstOnboardingPermissions : []
        }
        dismissedConversationID = defaults.string(forKey: Key.dismissedConversationID).flatMap(UUID.init(uuidString:))
        capturesSelectionOnOpen = defaults.object(forKey: Key.capturesSelectionOnOpen) as? Bool ?? true
        #if DEBUG
        applyDebugOverrides(ProcessInfo.processInfo.environment)
        #endif
    }

    /// The model of the selected provider.
    var model: String {
        switch providerKind {
        case .anthropic: anthropicModel
        case .openAICompatible: openAIModel
        case .claudeCode: claudeCodeModel
        }
    }

    /// The base URL of the selected provider; nil = provider default.
    var baseURL: URL? {
        let text: String
        switch providerKind {
        case .anthropic: text = anthropicBaseURL
        case .openAICompatible: text = openAIBaseURL
        case .claudeCode: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    func providerConfiguration(apiKey: String) -> ProviderConfiguration {
        let path = claudeCodePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderConfiguration(kind: providerKind, apiKey: apiKey, baseURL: baseURL,
                                     executablePath: providerKind == .claudeCode && !path.isEmpty ? path : nil)
    }

    /// First launch only (no provider stored yet): prefer the Claude subscription
    /// through Claude Code when the CLI is installed. Called by the app, not by
    /// tests, so tests never depend on what is installed on the machine.
    func applyFirstLaunchProviderDefault() {
        guard persistsChanges, defaults.object(forKey: Key.providerKind) == nil else { return }
        providerKind = Self.defaultProviderKind()
    }

    /// The Claude subscription through Claude Code when it is installed in one of
    /// its standard locations (including the Claude app's own copy), otherwise the
    /// Anthropic API.
    static func defaultProviderKind(home: String = NSHomeDirectory()) -> ProviderKind {
        let candidates = ClaudeCodeLocator.standardCandidates(home: home)
        return candidates.contains(where: ClaudeCodeLocator.isUsableExecutable) ? .claudeCode : .anthropic
    }

    func isToolEnabled(_ name: String) -> Bool {
        !disabledToolNames.contains(name)
    }

    func setTool(_ name: String, enabled: Bool) {
        if enabled {
            disabledToolNames.remove(name)
        } else {
            disabledToolNames.insert(name)
        }
    }

    // MARK: Persistence

    private enum Key {
        static let providerKind = "providerKind"
        static let anthropicModel = "anthropicModel"
        static let anthropicBaseURL = "anthropicBaseURL"
        static let openAIModel = "openAIModel"
        static let openAIBaseURL = "openAIBaseURL"
        static let claudeCodeModel = "claudeCodeModel"
        static let claudeCodePath = "claudeCodePath"
        static let effort = "reasoningEffort"
        static let disabledToolNames = "disabledToolNames"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let presentedOnboardingPermissions = "presentedOnboardingPermissions"
        static let dismissedConversationID = "dismissedConversationID"
        static let capturesSelectionOnOpen = "capturesSelectionOnOpen"
    }

    private func store(_ value: Any, _ key: String) {
        guard persistsChanges else { return }
        defaults.set(value, forKey: key)
    }

    #if DEBUG
    /// ORBIT_DEBUG_PROVIDER (anthropic|openAICompatible|claudeCode), ORBIT_DEBUG_MODEL,
    /// ORBIT_DEBUG_BASE_URL, ORBIT_DEBUG_EFFORT (low|medium|high|none).
    /// Once any override is present, changes are no longer persisted, so debug
    /// runs never modify the user's real settings.
    private func applyDebugOverrides(_ environment: [String: String]) {
        let keys = ["ORBIT_DEBUG_PROVIDER", "ORBIT_DEBUG_MODEL", "ORBIT_DEBUG_BASE_URL", "ORBIT_DEBUG_EFFORT"]
        guard keys.contains(where: { environment[$0] != nil }) else { return }
        persistsChanges = false
        if let provider = environment["ORBIT_DEBUG_PROVIDER"].flatMap(ProviderKind.init(rawValue:)) {
            providerKind = provider
        }
        if let model = environment["ORBIT_DEBUG_MODEL"] {
            switch providerKind {
            case .anthropic: anthropicModel = model
            case .openAICompatible: openAIModel = model
            case .claudeCode: claudeCodeModel = model
            }
        }
        if let baseURL = environment["ORBIT_DEBUG_BASE_URL"] {
            switch providerKind {
            case .anthropic: anthropicBaseURL = baseURL
            case .openAICompatible: openAIBaseURL = baseURL
            case .claudeCode: claudeCodePath = baseURL  // ORBIT_DEBUG_BASE_URL = path of a fake `claude`
            }
        }
        if let effortText = environment["ORBIT_DEBUG_EFFORT"] {
            effort = ReasoningEffort(rawValue: effortText)
        }
    }
    #endif
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
