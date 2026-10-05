import SwiftUI

/// Settings of the Claude-subscription provider: whether Claude Code is
/// installed and signed in, sign-in through Anthropic's own flow, the usage
/// of the subscription, and the model.
struct ClaudeCodeSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var account: ClaudeCodeAccountModel
    /// The latest usage state reported by Claude Code (read in `body`, so it updates).
    let usage: @MainActor () -> RateLimitInfo?

    static let modelSuggestions = ["sonnet", "opus", "haiku"]

    var body: some View {
        Section("Account") {
            ClaudeCodeStatusRow(account: account)
            if let usage = usage(), let text = ProviderUsage.usageText(for: usage) {
                usageRow(text: text, info: usage)
            }
        }
        .task { await account.refreshIfNeeded() }

        Section("Model") {
            modelRow
            Picker("Reasoning effort", selection: $settings.effort) {
                Text("Automatic").tag(ReasoningEffort?.none)
                Text("Low").tag(ReasoningEffort?.some(.low))
                Text("Medium").tag(ReasoningEffort?.some(.medium))
                Text("High").tag(ReasoningEffort?.some(.high))
            }
            .help(Text("How thoroughly the model thinks. Higher is more thorough but slower. “Automatic” uses Claude Code’s default."))
        }

        Section {
            DisclosureGroup("Advanced") {
                TextField(text: $settings.claudeCodePath, prompt: Text("Detect automatically")) {
                    Text("Program path")
                }
                .onSubmit { Task { await account.refresh() } }
                Text("Leave empty to find Claude Code automatically (from the Claude app or an installation in Terminal).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Usage and model

    private func usageRow(text: String, info: RateLimitInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Usage")
                Spacer()
                Text(verbatim: text)
                    .foregroundStyle(info.isRejected ? .red : .secondary)
            }
            if let utilization = info.utilization {
                ProgressView(value: min(max(utilization, 0), 1))
                    .tint(utilization >= ProviderUsage.warningThresholds[0] ? .orange : .accentColor)
                    .accessibilityHidden(true)
            }
            if let reset = ProviderUsage.resetText(for: info) {
                Text(verbatim: reset)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelRow: some View {
        HStack(spacing: 6) {
            TextField(text: $settings.claudeCodeModel, prompt: Text(verbatim: SettingsStore.defaultClaudeCodeModel)) {
                Text("Model")
            }
            Menu {
                ForEach(Self.modelSuggestions, id: \.self) { model in
                    Button {
                        settings.claudeCodeModel = model
                    } label: {
                        Text(verbatim: Self.modelTitle(model))
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

    // MARK: Texts

    /// "Verbunden mit deinem Claude-Abo (Max)".
    static func readyTitle(for status: ClaudeCodeStatus) -> String {
        guard let plan = planName(status.subscriptionType) else {
            return String(localized: "Connected to your Claude account")
        }
        return String(format: String(localized: "Connected to your Claude subscription (%@)"), plan)
    }

    /// "max" → "Max", "pro" → "Pro"; nil when not reported.
    static func planName(_ subscriptionType: String?) -> String? {
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return nil }
        return type.prefix(1).uppercased() + type.dropFirst()
    }

    /// "Claude Code 2.1.284 aus der Claude-App" or "Claude Code 2.1.251 (~/.local/bin/claude)".
    static func installationText(for status: ClaudeCodeStatus, home: String = NSHomeDirectory()) -> String {
        let name = status.version.map { "Claude Code \($0)" } ?? "Claude Code"
        guard let path = status.executablePath else { return name }
        if ClaudeCodeLocator.isBundledWithClaudeApp(path, home: home) {
            return String(format: String(localized: "%@ from the Claude app"), name)
        }
        let shortPath = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return "\(name) (\(shortPath))"
    }

    static func modelTitle(_ alias: String) -> String {
        switch alias {
        case "sonnet": String(localized: "Sonnet: balanced (default)")
        case "opus": String(localized: "Opus: most capable")
        case "haiku": String(localized: "Haiku: fastest")
        default: alias
        }
    }
}

/// Whether Claude Code is installed and signed in, with "Sign In…" and
/// "Check Status" (Settings → Model and the onboarding).
struct ClaudeCodeStatusRow: View {
    @Bindable var account: ClaudeCodeAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusLabel
                Spacer(minLength: 8)
                actionButtons
            }
            if let detail = statusDetail {
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = account.signInError {
                Label {
                    Text(verbatim: error)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if account.isSigningIn {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in through your browser…")
            }
        } else {
            switch account.state {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking Claude Code…")
                        .foregroundStyle(.secondary)
                }
            case .unavailable:
                Label("Status unavailable", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            case .status(let status):
                switch status.availability {
                case .ready:
                    Label {
                        Text(verbatim: ClaudeCodeSettingsSection.readyTitle(for: status))
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                    }
                    .foregroundStyle(.green)
                case .notLoggedIn:
                    Label("Claude Code is not signed in", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                case .notInstalled:
                    Label("Claude Code was not found", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                case .unknown:
                    Label("Claude Code’s status could not be checked", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if account.isSigningIn {
            Button("Cancel") { account.cancelSignIn() }
        } else {
            if case .status(let status) = account.state, status.availability == .notLoggedIn {
                Button("Sign In…") { account.signIn() }
                    .help(Text("Opens Anthropic’s sign-in in your browser. Orbit never sees your credentials."))
            }
            Button("Check Status") {
                Task { await account.refresh() }
            }
            .disabled(account.state == .checking)
        }
    }

    /// The second line under the status.
    private var statusDetail: String? {
        guard !account.isSigningIn, case .status(let status) = account.state else { return nil }
        switch status.availability {
        case .ready:
            var parts = [ClaudeCodeSettingsSection.installationText(for: status)]
            if status.authMethod.map({ $0 != "claude.ai" }) == true {
                parts.append(String(localized: "Claude Code is not signed in with a Claude subscription; usage is billed through the Anthropic Console."))
            }
            return parts.joined(separator: "\n")
        case .notLoggedIn:
            return ClaudeCodeSettingsSection.installationText(for: status) + "\n"
                + String(localized: "Sign in with your Claude account. Signing in happens in your browser, through Anthropic.")
        case .notInstalled:
            return String(localized: "Install the Claude app from claude.ai/download or Claude Code in Terminal, then click “Check Status”.")
        case .unknown:
            return ClaudeCodeSettingsSection.installationText(for: status)
        }
    }
}

/// Status and sign-in of Claude Code for the settings (through the agent loop).
/// VoiceOver hears how a sign-in ended (connected, or why not), which
/// otherwise only appears next to the button.
@MainActor
@Observable
final class ClaudeCodeAccountModel {
    enum State: Equatable {
        case checking
        case status(ClaudeCodeStatus)
        /// No account service (e.g. previews).
        case unavailable
    }

    private(set) var state: State = .checking
    private(set) var isSigningIn = false
    /// Why the last sign-in failed (localized), if it did.
    private(set) var signInError: String?

    @ObservationIgnored private let loadStatus: @MainActor () async -> ClaudeCodeStatus?
    @ObservationIgnored private let runSignIn: @MainActor () async throws -> Void
    @ObservationIgnored private let announcer: (any Announcing)?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false

    init(loadStatus: @escaping @MainActor () async -> ClaudeCodeStatus?,
         signIn: @escaping @MainActor () async throws -> Void,
         announcer: (any Announcing)? = nil) {
        self.loadStatus = loadStatus
        runSignIn = signIn
        self.announcer = announcer
    }

    /// Loads the status the first time the section appears.
    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        hasLoaded = true
        state = .checking
        let status = await loadStatus()
        state = status.map(State.status) ?? .unavailable
    }

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        signInTask = Task {
            var signedIn = false
            do {
                try await runSignIn()
                signedIn = true
            } catch LLMError.cancelled {
                // Stopped by the user.
            } catch is CancellationError {
                // Stopped by the user.
            } catch let error as LLMError {
                signInError = error == .claudeCodeNotLoggedIn
                    ? String(localized: "Sign-in was not completed. Please try again.")
                    : error.userMessage
            } catch {
                signInError = String(localized: "Sign-in was not completed. Please try again.")
            }
            isSigningIn = false
            signInTask = nil
            if let signInError {
                announcer?.announce(signInError, priority: .high)
            }
            await refresh()
            if signedIn, case .status(let status) = state, status.availability == .ready {
                announcer?.announce(ClaudeCodeSettingsSection.readyTitle(for: status), priority: .high)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }
}
