import SwiftUI

/// "Model": provider, then either the Claude subscription (Claude Code status,
/// sign-in, usage, model) or API key (keychain), model, server address, effort
/// and a connection test.
struct ModelSettingsView: View {
    @Bindable var settings: SettingsStore
    /// Runs `AgentLoop.validate(configuration:model:)`.
    let validate: @MainActor (ProviderConfiguration, String) async throws -> Void
    /// `AgentLoop.providerUsage`.
    let usage: @MainActor () -> RateLimitInfo?

    @State private var keyEditor: APIKeyEditor
    @State private var claudeCodeAccount: ClaudeCodeAccountModel
    @State private var tester: ConnectionTester

    static let anthropicModelSuggestions = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5"]

    init(settings: SettingsStore, secrets: any SecretStoring,
         validate: @escaping @MainActor (ProviderConfiguration, String) async throws -> Void,
         claudeCodeAccount: ClaudeCodeAccountModel,
         usage: @escaping @MainActor () -> RateLimitInfo? = { nil },
         announcer: (any Announcing)? = nil) {
        self.settings = settings
        self.validate = validate
        self.usage = usage
        _keyEditor = State(initialValue: APIKeyEditor(secrets: secrets))
        _claudeCodeAccount = State(initialValue: claudeCodeAccount)
        _tester = State(initialValue: ConnectionTester(validate: validate, announcer: announcer))
    }

    private var isAnthropic: Bool {
        settings.providerKind == .anthropic
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.providerKind) {
                    Text("Claude subscription (via Claude Code)").tag(ProviderKind.claudeCode)
                    Text("Anthropic API").tag(ProviderKind.anthropic)
                    Text("OpenAI-compatible").tag(ProviderKind.openAICompatible)
                }
            } footer: {
                Group {
                    switch settings.providerKind {
                    case .claudeCode:
                        Text("Uses your Claude subscription (Pro or Max) through Claude Code, no API key needed. Usage counts toward your subscription’s limits. Orbit never sees your Claude sign-in.")
                    case .anthropic:
                        Text("Claude through the Anthropic API. You can get an API key in the Anthropic Console.")
                    case .openAICompatible:
                        Text("Any server with a Chat Completions API, including local models with Ollama or LM Studio.")
                    }
                }
                .foregroundStyle(.secondary)
            }

            if settings.providerKind == .claudeCode {
                ClaudeCodeSettingsSection(settings: settings, account: claudeCodeAccount, usage: usage)
            } else {
                apiSections
            }
        }
        .formStyle(.grouped)
        .task(id: settings.providerKind) {
            tester.reset()
            // Claude Code has no API key: its keychain entry is never read.
            guard settings.providerKind.usesAPIKey else { return }
            await keyEditor.load(kind: settings.providerKind)
        }
        .onChange(of: settings.model) { tester.reset() }
        .onChange(of: settings.baseURL) { tester.reset() }
        // Typing a key resets the result; the draft emptying after a save does not.
        .onChange(of: keyEditor.draft) { _, draft in if !draft.isEmpty { tester.reset() } }
        .onDisappear { tester.cancel() }
    }

    /// Key, model, server address, effort and the connection test of the API providers.
    @ViewBuilder
    private var apiSections: some View {
        Section("Account") {
            SecureField(text: $keyEditor.draft, prompt: isAnthropic ? Text(verbatim: "sk-ant-…") : Text("Optional")) {
                Text("API key")
            }
            .onSubmit(saveKey)
            keyStatusRow
        }

        Section("Model") {
            modelRow
            TextField(text: baseURLBinding, prompt: Text(verbatim: isAnthropic ? "https://api.anthropic.com" : SettingsStore.defaultOpenAIBaseURL)) {
                Text("Server address")
            }
            baseURLHint
            Picker("Reasoning effort", selection: $settings.effort) {
                Text("Automatic").tag(ReasoningEffort?.none)
                Text("Low").tag(ReasoningEffort?.some(.low))
                Text("Medium").tag(ReasoningEffort?.some(.medium))
                Text("High").tag(ReasoningEffort?.some(.high))
            }
            .help(Text("How thoroughly the model thinks. Higher is more thorough but slower. “Automatic” sends no setting."))
        }

        Section {
            HStack(spacing: 10) {
                Button("Test Connection") {
                    tester.test(settings: settings, keyEditor: keyEditor)
                }
                .disabled(tester.state == .running)
                ConnectionTestStatus(state: tester.state)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var keyStatusRow: some View {
        HStack(spacing: 8) {
            switch keyEditor.status {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .saved:
                Label("Saved in keychain", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .notSaved:
                Group {
                    if isAnthropic {
                        Label("No key saved", systemImage: "key")
                    } else {
                        Label("No key saved (not needed for local servers)", systemImage: "key")
                    }
                }
                .foregroundStyle(.secondary)
            case .failed(let message):
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            }
            Spacer(minLength: 8)
            if keyEditor.hasDraft {
                Text("Not saved")
                    .foregroundStyle(.orange)
                Button("Save", action: saveKey)
            } else if keyEditor.status == .saved {
                Button("Remove", role: .destructive) {
                    Task { await keyEditor.remove() }
                }
            }
        }
        .font(.callout)
    }

    private var modelRow: some View {
        HStack(spacing: 6) {
            TextField(text: modelBinding, prompt: isAnthropic ? Text(verbatim: SettingsStore.defaultAnthropicModel) : Text("e.g. gpt-oss:20b")) {
                Text("Model")
            }
            if isAnthropic {
                Menu {
                    ForEach(Self.anthropicModelSuggestions, id: \.self) { model in
                        Button {
                            settings.anthropicModel = model
                        } label: {
                            if model == SettingsStore.defaultAnthropicModel {
                                Text(verbatim: String(format: String(localized: "%@ (default)"), model))
                            } else {
                                Text(verbatim: model)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Suggestions"))
                .accessibilityLabel(Text("Model suggestions"))
            }
        }
    }

    @ViewBuilder
    private var baseURLHint: some View {
        let text = isAnthropic ? settings.anthropicBaseURL : settings.openAIBaseURL
        switch BaseURLCheck.check(text) {
        case .invalid:
            // Verbatim texts: a LocalizedStringKey would turn the URLs into links.
            Label {
                Text(verbatim: String(localized: "Invalid address. Example: http://localhost:11434/v1"))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
        case .cleartextBlocked:
            Label {
                Text(verbatim: LLMError.network(.insecureConnectionBlocked).userMessage)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        case .insecure:
            Label("Unencrypted connection: the key and content would be sent in plain text. Use it only for servers on this Mac or in your local network.",
                  systemImage: "lock.open.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .empty, .valid:
            Text(verbatim: isAnthropic
                 ? String(localized: "Optional. Leave empty for api.anthropic.com, or enter the address of a compatible server, e.g. http://localhost:11434 for Ollama.")
                 : String(localized: "For example, http://localhost:11434/v1 for Ollama or http://localhost:1234/v1 for LM Studio."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bindings and actions

    private var modelBinding: Binding<String> {
        isAnthropic ? $settings.anthropicModel : $settings.openAIModel
    }

    private var baseURLBinding: Binding<String> {
        isAnthropic ? $settings.anthropicBaseURL : $settings.openAIBaseURL
    }

    private func saveKey() {
        Task { await keyEditor.save() }
    }
}

enum ConnectionTestState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed(String)
}

/// "Test Connection" for the API providers, in Settings → Model and in the
/// onboarding: validates the provider with the typed (or stored) key and
/// keeps a typed key that works. VoiceOver hears the result; the keyboard
/// stays on the button, next to which it appears.
@MainActor
@Observable
final class ConnectionTester {
    private(set) var state: ConnectionTestState = .idle {
        didSet {
            if let text = Self.announcement(for: state), state != oldValue {
                announcer?.announce(text, priority: .high)
            }
        }
    }

    @ObservationIgnored private let validate: @MainActor (ProviderConfiguration, String) async throws -> Void
    @ObservationIgnored private let announcer: (any Announcing)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(validate: @escaping @MainActor (ProviderConfiguration, String) async throws -> Void,
         announcer: (any Announcing)? = nil) {
        self.validate = validate
        self.announcer = announcer
    }

    /// What VoiceOver hears of a result ("Connection successful", or why it failed); nil while there is none.
    nonisolated static func announcement(for state: ConnectionTestState) -> String? {
        switch state {
        case .succeeded: String(localized: "Connection successful")
        case .failed(let message): message
        case .idle, .running: nil
        }
    }

    /// A result (or a running test) no longer matches changed inputs.
    func reset() {
        cancel()
        state = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func test(settings: SettingsStore, keyEditor: APIKeyEditor) {
        task?.cancel()
        // Each press is answered: the same failure again (e.g. still no model) is a new result that VoiceOver hears.
        state = .idle
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            state = .failed(String(localized: "Please enter a model."))
            return
        }
        let isAnthropic = settings.providerKind == .anthropic
        switch BaseURLCheck.check(isAnthropic ? settings.anthropicBaseURL : settings.openAIBaseURL) {
        case .invalid:
            state = .failed(LLMError.invalidBaseURL.userMessage)
            return
        case .cleartextBlocked:
            state = .failed(LLMError.network(.insecureConnectionBlocked).userMessage)
            return
        case .empty, .valid, .insecure:
            break
        }
        let kind = settings.providerKind
        let baseURL = settings.baseURL
        let validate = validate
        state = .running
        task = Task {
            let result: ConnectionTestState
            do {
                let usesTypedKey = keyEditor.hasDraft
                let key = try await keyEditor.keyForConnectionTest()
                try await validate(ProviderConfiguration(kind: kind, apiKey: key, baseURL: baseURL), model)
                // A typed key that works is kept; Orbit only uses stored keys.
                if usesTypedKey, !Task.isCancelled, keyEditor.kind == kind {
                    await keyEditor.save()
                }
                result = .succeeded
            } catch is CancellationError {
                return
            } catch let error as LLMError {
                if error == .cancelled { return }
                // E.g. "Der Server auf diesem Mac (localhost:11434) ist nicht erreichbar. Starte Ollama …".
                result = .failed(error.userMessage(for: ProviderDestination(kind: kind, baseURL: baseURL)))
            } catch {
                result = .failed(String(localized: "The connection could not be established."))
            }
            guard !Task.isCancelled else { return }
            state = result
        }
    }
}

/// The result of "Test Connection" next to the button.
struct ConnectionTestStatus: View {
    let state: ConnectionTestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            ProgressView()
                .controlSize(.small)
            Text("Connecting…")
                .foregroundStyle(.secondary)
        case .succeeded:
            Label("Connection successful", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .foregroundStyle(.red)
        }
    }
}

/// Checks the server address field.
enum BaseURLCheck: Equatable, Sendable {
    /// Nothing entered (provider default).
    case empty
    case valid
    case invalid
    /// Plain http to an IP address outside this Mac and the local network.
    case insecure
    /// Plain http to a DNS name such as "pc.fritz.box": macOS (App Transport
    /// Security) blocks it; https, the IP address or a ".local" name work.
    case cleartextBlocked

    static func check(_ text: String) -> BaseURLCheck {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false), !host.isEmpty,
              scheme == "http" || scheme == "https" else {
            return .invalid
        }
        guard scheme == "http", !isLocal(host: host) else { return .valid }
        return isIPAddress(host) ? .insecure : .cleartextBlocked
    }

    static func isIPAddress(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { return true } // IPv6 literal
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// This Mac, a private address, a ".local" name or a single-label name:
    /// the hosts App Transport Security allows over plain http.
    static func isLocal(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        if !host.contains("."), !host.contains(":") { return true } // e.g. "gaming-pc"
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

/// Edits the API key of one provider. The stored key is never read into the
/// UI; the field only accepts a new key. Keychain access runs off the main
/// thread (it can block, e.g. while macOS asks for keychain access).
@MainActor
@Observable
final class APIKeyEditor {
    enum Status: Equatable, Sendable {
        case loading
        case saved
        case notSaved
        case failed(String)
    }

    private(set) var status: Status = .loading
    /// A new key typed by the user, not yet saved.
    var draft = ""
    private(set) var kind: ProviderKind = .anthropic
    /// Unsaved keys of the other providers, so switching back and forth keeps them.
    @ObservationIgnored private var drafts: [ProviderKind: String] = [:]

    @ObservationIgnored private let secrets: any SecretStoring

    init(secrets: any SecretStoring) {
        self.secrets = secrets
    }

    var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var account: String {
        SecretAccount.apiKey(for: kind)
    }

    func load(kind: ProviderKind) async {
        drafts[self.kind] = draft.isEmpty ? nil : draft
        self.kind = kind
        draft = drafts[kind] ?? ""
        status = .loading
        let secrets = secrets
        let account = account
        let result = await Task.detached(priority: .userInitiated) {
            Result { try secrets.secret(for: account) != nil }
        }.value
        guard self.kind == kind else { return }
        switch result {
        case .success(let exists):
            status = exists ? .saved : .notSaved
        case .failure:
            Log.storage.error("Reading the API key status failed")
            status = .failed(String(localized: "The keychain could not be read."))
        }
    }

    func save() async {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let kind = kind
        let secrets = secrets
        let account = account
        let result = await Task.detached(priority: .userInitiated) {
            Result { try secrets.setSecret(key, for: account) }
        }.value
        if case .success = result {
            drafts[kind] = nil
        }
        // The user switched providers meanwhile: this status is not theirs.
        guard self.kind == kind else { return }
        switch result {
        case .success:
            draft = ""
            status = .saved
        case .failure:
            Log.storage.error("Saving the API key failed")
            status = .failed(String(localized: "The key could not be saved in the keychain."))
        }
    }

    func remove() async {
        let secrets = secrets
        let account = account
        let result = await Task.detached(priority: .userInitiated) {
            Result { try secrets.setSecret(nil, for: account) }
        }.value
        switch result {
        case .success:
            status = .notSaved
        case .failure:
            Log.storage.error("Removing the API key failed")
            status = .failed(String(localized: "The key could not be removed."))
        }
    }

    /// The key for "Test Connection": the typed (unsaved) key if any,
    /// otherwise the stored one ("" when there is none).
    func keyForConnectionTest() async throws -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let secrets = secrets
        let account = account
        return try await Task.detached(priority: .userInitiated) {
            try secrets.secret(for: account) ?? ""
        }.value
    }
}
