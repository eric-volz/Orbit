import AppKit
import KeyboardShortcuts
import SwiftUI

/// The onboarding window's content: one step at a time, with the step
/// indicator and the buttons below. Return is the step's main button (on the
/// model step only when it shows no text field), Escape skips ("Later",
/// "Skip").
struct OnboardingView: View {
    static let size = CGSize(width: 640, height: 560)

    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 44)
                    .padding(.top, 34)
                    .padding(.bottom, 24)
            }
            .id(model.step)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The permissions a step shows are read when it appears, and again when Orbit becomes active, back
        // from System Settings, where the user may have switched Orbit on.
        .task(id: model.step) {
            await model.refreshShownPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshShownPermissions() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            OnboardingWelcomeStep()
        case .provider:
            OnboardingProviderStep(model: model)
        case .hotkey:
            OnboardingHotkeyStep()
        case .permission(let permission):
            OnboardingPermissionStep(model: model, permission: permission)
        case .done:
            OnboardingDoneStep(model: model)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            OnboardingStepIndicator(count: model.steps.count, current: model.index)
            Spacer()
            buttons
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.step {
        case .welcome:
            Button("Later") { model.finish() }
                .keyboardShortcut(.cancelAction)
                .help(Text("Closes the setup. It is always available from Orbit’s menu in the menu bar."))
            Button("Get Started") { model.next() }
                .keyboardShortcut(.defaultAction)
        case .provider:
            Button("Back") { model.back() }
            // Return belongs to the text fields when the step shows some.
            Button("Continue") { model.next() }
                .keyboardShortcut(model.providerStepHasTextFields ? nil : .defaultAction)
        case .hotkey:
            Button("Back") { model.back() }
            Button("Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
        case .permission(let permission):
            permissionButtons(permission)
        case .done:
            Button("Back") { model.back() }
            Button("Done") { model.finish() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func permissionButtons(_ permission: PermissionKind) -> some View {
        let action = model.action(for: permission)
        // After an update the first step may be a permission: nothing before it.
        Button("Back") { model.back() }
            .disabled(!model.canGoBack)
        if action != .next {
            Button("Skip") { model.next() }
                .keyboardShortcut(.cancelAction)
                .help(Text(verbatim: PermissionCopy.skipHelp(permission)))
        }
        switch action {
        case .request:
            // Also while Notes or Mail does not run (status unknown): the step says it is started first.
            Button("Allow…") {
                Task { await model.request(permission) }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text(verbatim: PermissionCopy.requestAccessibilityLabel(permission)))
        case .next:
            Button("Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
        case .wait:
            Button("Continue") { model.next() }
                .disabled(true)
        }
    }
}

/// Dots for the steps, the current one in the accent color, and, with
/// Differentiate Without Color, wider, so it is not told by its color alone.
struct OnboardingStepIndicator: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// The width of a dot (all are 7 pt high).
    static func dotWidth(isCurrent: Bool, differentiateWithoutColor: Bool) -> CGFloat {
        isCurrent && differentiateWithoutColor ? 18 : 7
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: Self.dotWidth(isCurrent: index == current, differentiateWithoutColor: differentiateWithoutColor),
                           height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(format: String(localized: "Step %1$lld of %2$lld"), current + 1, count)))
    }
}

extension OnboardingModel.Step {
    /// The step's title: its header, and what VoiceOver hears when it appears.
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome to Orbit")
        case .provider: String(localized: "Language Model")
        case .hotkey: String(localized: "Keyboard Shortcut")
        case .permission(let permission): PermissionCopy.headline(permission)
        case .done: String(localized: "All Set")
        }
    }
}

/// Icon, title and text at the top of a step.
struct OnboardingHeader: View {
    var systemImage: String?
    var image: NSImage?
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                    .accessibilityHidden(true)
            }
            Text(verbatim: title)
                .font(.system(size: 24, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: text)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingHeader(
                image: NSApplication.shared.applicationIconImage,
                title: OnboardingModel.Step.welcome.title,
                text: String(localized: "Orbit brings search and an assistant to your Mac. Open it with a keyboard shortcut, then type a name or ask a question.")
            )
            VStack(alignment: .leading, spacing: 14) {
                feature("magnifyingglass", String(localized: "Find Instantly"),
                        String(localized: "Apps, files and contacts appear as you type."))
                feature("bubble.left.and.text.bubble.right", String(localized: "Ask and Get Things Done"),
                        String(localized: "The assistant finds files, mail and notes and drafts replies for you."))
                feature("checkmark.shield", String(localized: "You Stay in Control"),
                        String(localized: "Orbit carries out actions with consequences only after you confirm them. It never sends mail by itself."))
                feature("lock", String(localized: "Private"),
                        String(localized: "Content goes only to the language model you choose, and only when a question needs it. The chat shows what was sent."))
            }
            Text("The setup takes about a minute. You can skip any step.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func feature(_ systemImage: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .fontWeight(.semibold)
                Text(verbatim: text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model

/// The language model: the Claude subscription (status and sign-in), or an
/// API key with a connection test, or an OpenAI-compatible server.
struct OnboardingProviderStep: View {
    @Bindable var model: OnboardingModel

    private var settings: SettingsStore { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(
                systemImage: "cpu",
                title: OnboardingModel.Step.provider.title,
                text: String(localized: "Orbit’s assistant needs a language model. The easiest way is your Claude subscription, no API key needed.")
            )
            Picker(selection: Bindable(settings).providerKind) {
                Text("Claude subscription (via Claude Code)").tag(ProviderKind.claudeCode)
                Text("Anthropic API").tag(ProviderKind.anthropic)
                Text("OpenAI-compatible (e.g. Ollama, LM Studio)").tag(ProviderKind.openAICompatible)
            } label: {
                Text("Provider")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel(Text("Provider"))

            GroupBox {
                details
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("More options, such as the model and the reasoning effort, are in Settings under “Model”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: settings.providerKind) {
            model.tester.reset()
            if settings.providerKind == .claudeCode {
                await model.claudeCodeAccount.refreshIfNeeded()
            } else {
                await model.keyEditor.load(kind: settings.providerKind)
            }
        }
        .onChange(of: settings.model) { model.tester.reset() }
        .onChange(of: settings.baseURL) { model.tester.reset() }
        .onChange(of: model.keyEditor.draft) { _, draft in if !draft.isEmpty { model.tester.reset() } }
    }

    @ViewBuilder
    private var details: some View {
        switch settings.providerKind {
        case .claudeCode:
            VStack(alignment: .leading, spacing: 10) {
                Text("Uses your Claude subscription (Pro or Max) through Claude Code. Usage counts toward your subscription’s limits; Orbit never sees your sign-in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ClaudeCodeStatusRow(account: model.claudeCodeAccount)
            }
        case .anthropic:
            VStack(alignment: .leading, spacing: 10) {
                Text("You can get an API key in the Anthropic Console. Orbit stores it in your keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    keyRow(prompt: Text(verbatim: "sk-ant-…"))
                }
                keyStatus
                testRow
            }
        case .openAICompatible:
            VStack(alignment: .leading, spacing: 10) {
                Text("Any server with a Chat Completions API, including local models with Ollama or LM Studio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Server address")
                            .gridColumnAlignment(.trailing)
                        TextField(text: Bindable(settings).openAIBaseURL, prompt: Text(verbatim: SettingsStore.defaultOpenAIBaseURL)) {
                            Text("Server address")
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Model")
                        TextField(text: Bindable(settings).openAIModel, prompt: Text("e.g. gpt-oss:20b")) {
                            Text("Model")
                        }
                        .labelsHidden()
                    }
                    keyRow(prompt: Text("Optional"))
                }
                keyStatus
                testRow
            }
        }
    }

    private func keyRow(prompt: Text) -> some View {
        GridRow {
            Text("API key")
                .gridColumnAlignment(.trailing)
            SecureField(text: Bindable(model.keyEditor).draft, prompt: prompt) {
                Text("API key")
            }
            .labelsHidden()
            .onSubmit { Task { await model.keyEditor.save() } }
        }
    }

    @ViewBuilder
    private var keyStatus: some View {
        HStack(spacing: 8) {
            switch model.keyEditor.status {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .saved:
                Label("Saved in keychain", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .notSaved:
                Label("No key saved", systemImage: "key")
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
            if model.keyEditor.hasDraft {
                Text("Not saved")
                    .foregroundStyle(.orange)
                Button("Save") {
                    Task { await model.keyEditor.save() }
                }
            }
        }
        .font(.callout)
    }

    private var testRow: some View {
        HStack(spacing: 10) {
            Button("Test Connection") {
                model.tester.test(settings: settings, keyEditor: model.keyEditor)
            }
            .disabled(model.tester.state == .running)
            ConnectionTestStatus(state: model.tester.state)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shortcut

struct OnboardingHotkeyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(
                systemImage: "keyboard",
                title: OnboardingModel.Step.hotkey.title,
                text: String(localized: "This shortcut opens Orbit from anywhere, like Spotlight. Click the field to record a different one.")
            )
            GroupBox {
                LabeledContent("Open Orbit") {
                    HotkeyRecorder(name: .togglePanel)
                }
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("To open Orbit with ⌘ Space, first turn off Spotlight’s shortcut: System Settings > Keyboard > Keyboard Shortcuts > Spotlight > “Show Spotlight search”. Then you can record ⌘ Space here.")
                    .fixedSize(horizontal: false, vertical: true)
                if let url = GeneralSettingsView.keyboardSettingsURL {
                    Button("Open Keyboard Settings…") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions

/// One permission: why Orbit needs it, how macOS asks, its status. The button
/// in the footer asks macOS.
struct OnboardingPermissionStep: View {
    @Bindable var model: OnboardingModel
    let permission: PermissionKind

    private var status: PermissionStatus? { model.shownStatus(of: permission) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.mode != .full {
                // After an update: why the onboarding is back.
                Label("New in Orbit", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
            OnboardingHeader(
                systemImage: PermissionCopy.systemImage(permission),
                title: OnboardingModel.Step.permission(permission).title,
                text: PermissionCopy.purpose(permission)
            )
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(verbatim: permission.displayName)
                            .fontWeight(.medium)
                        Spacer()
                        PermissionStatusLabel(status: status, isRequesting: model.permissions.requesting.contains(permission))
                    }
                    .accessibilityElement(children: .combine)
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(PermissionCopy.isWarning(status) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if let status, !permission.canRequest(from: status), status != .granted {
                        Button("Open System Settings…") {
                            Task { await model.permissions.openSystemSettings(for: permission) }
                        }
                        .accessibilityLabel(Text(verbatim: PermissionCopy.actionAccessibilityLabel(permission, status: status)))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(verbatim: PermissionCopy.onboardingFootnote(permission,
                                                             capturesSelectionOnOpen: model.settings.capturesSelectionOnOpen))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How macOS asks, or, when it cannot ask any more, what to do instead.
    private var detail: String {
        switch status {
        case .granted:
            String(localized: "Orbit has access. You can change this anytime in System Settings.")
        case .denied, .restricted, .writeOnly:
            PermissionCopy.hint(permission, status: status) ?? PermissionCopy.howMacOSAsks(permission)
        case nil, .notDetermined, .unknown:
            PermissionCopy.howMacOSAsks(permission)
        }
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(systemImage: "checkmark.circle", title: OnboardingModel.Step.done.title, text: openingText)
            if !model.permissionSteps.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.permissionSteps) { permission in
                            HStack(spacing: 10) {
                                Image(systemName: PermissionCopy.systemImage(permission))
                                    .foregroundStyle(.tint)
                                    .frame(width: 22)
                                    .accessibilityHidden(true)
                                Text(verbatim: permission.displayName)
                                Spacer()
                                PermissionStatusLabel(status: model.shownStatus(of: permission),
                                                      isRequesting: model.permissions.requesting.contains(permission))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(8)
                }
            }
            Text("You can change everything later in Settings. The setup is always available from Orbit’s menu in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openingText: String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .togglePanel) else {
            return String(localized: "Open Orbit from its icon in the menu bar, then type a name or ask a question.")
        }
        return String(format: String(localized: "Press %@ to open Orbit, then type a name or ask a question."),
                      HotkeyFormatter.string(for: shortcut))
    }
}
