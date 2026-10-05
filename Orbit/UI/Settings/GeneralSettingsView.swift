import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// "General": keyboard shortcut, the context taken when Orbit opens and
/// launch at login. Orbit's language is chosen in System Settings, like any
/// app's (see `AppLanguage`).
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    /// Opens Settings → Permissions.
    var showPermissions: () -> Void = {}
    @State private var launchAtLogin: LaunchAtLoginModel

    init(settings: SettingsStore, showPermissions: @escaping () -> Void = {},
         launchAtLogin: LaunchAtLoginModel = LaunchAtLoginModel()) {
        self.settings = settings
        self.showPermissions = showPermissions
        _launchAtLogin = State(initialValue: launchAtLogin)
    }

    /// System Settings → Keyboard (to free ⌘Space from Spotlight).
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Orbit") {
                    HotkeyRecorder(name: .togglePanel)
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To open Orbit with ⌘ Space, first turn off Spotlight’s shortcut: System Settings > Keyboard > Keyboard Shortcuts > Spotlight > “Show Spotlight search”. Then you can record ⌘ Space here.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = Self.keyboardSettingsURL {
                        Button("Open Keyboard Settings…") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use the selection when opening", isOn: $settings.capturesSelectionOnOpen)
            } header: {
                Text("Context")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When you open Orbit, it takes the items selected in Finder or the text selected in the app you come from as context for your question. The context appears above the input field; remove it with its × or with ⌫ in the empty input field. Orbit never reads password fields or password apps. This needs “Automation: Finder” and “Accessibility”.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show Permissions…") {
                        showPermissions()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isOn },
                    set: { newValue in Task { await launchAtLogin.setEnabled(newValue) } }
                ))
                .disabled(launchAtLogin.isUpdating)
                if let message = launchAtLogin.statusMessage {
                    Label {
                        Text(verbatim: message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if launchAtLogin.offersLoginItemsSettings {
                    Button("Open Login Items…") {
                        launchAtLogin.openLoginItemsSettings()
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Label {
                        Text(verbatim: error)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Text("Orbit follows the language of macOS: English or German, whichever comes first in your preferred languages, otherwise English. To choose a language just for Orbit, go to System Settings > General > Language & Region > Applications; it takes effect after Orbit restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Language")
            }
        }
        .formStyle(.grouped)
        .task {
            await launchAtLogin.refresh()
        }
        // Back from System Settings (e.g. "Open Login Items…"): show what was allowed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await launchAtLogin.refresh() }
        }
    }
}

/// Starts a fresh instance of Orbit and quits this one (the new instance waits
/// until this one has terminated).
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.app.error("Relaunch failed: \(String(describing: type(of: error)), privacy: .public)")
                return
            }
            Task { @MainActor in
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        }
    }
}

/// Orbit's login item. Live: `SMAppService.mainApp`; tests use a fake, because
/// registering a login item changes the user's system.
protocol LoginItemControlling: Sendable {
    func status() -> SMAppService.Status
    func register() throws
    func unregister() throws
    /// System Settings → General → Login Items.
    func openSystemSettings()
}

/// `SMAppService.mainApp`, Orbit itself as login item.
struct MainAppLoginItem: LoginItemControlling {
    func status() -> SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Launch at login via `SMAppService.mainApp`. Registration talks to a system
/// daemon, so it runs off the main thread; the status is always read back,
/// also when Orbit becomes active again (the user may have allowed it in
/// System Settings meanwhile). VoiceOver hears what appears next to the
/// switch after it was used (the keyboard stays on the switch): why it failed,
/// or that macOS wants the user's approval.
@MainActor
@Observable
final class LaunchAtLoginModel {
    enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user still has to allow it in System Settings.
        case requiresApproval
    }

    private(set) var state: State = .disabled
    private(set) var errorMessage: String?
    private(set) var isUpdating = false

    @ObservationIgnored private let service: any LoginItemControlling
    @ObservationIgnored private let announcer: (any Announcing)?

    init(service: any LoginItemControlling = MainAppLoginItem(), announcer: (any Announcing)? = nil) {
        self.service = service
        self.announcer = announcer
    }

    var isOn: Bool {
        state == .enabled || state == .requiresApproval
    }

    var statusMessage: String? {
        state == .requiresApproval
            ? String(localized: "Allow Orbit in System Settings > General > Login Items.")
            : nil
    }

    /// "Open Login Items…": only while macOS waits for the user's approval.
    var offersLoginItemsSettings: Bool {
        state == .requiresApproval
    }

    func openLoginItemsSettings() {
        service.openSystemSettings()
    }

    /// Reads the state again. An error from before goes once the state
    /// changed (e.g. the user allowed Orbit in System Settings meanwhile).
    func refresh() async {
        let service = service
        let status = await Task.detached(priority: .userInitiated) {
            service.status()
        }.value
        let newState = Self.state(for: status)
        if newState != state {
            errorMessage = nil
        }
        state = newState
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        let service = service
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SMAppService.Status, any Error> in
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
                return .success(service.status())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let status):
            state = Self.state(for: status)
        case .failure(let error):
            let nsError = error as NSError
            Log.app.error("Launch at login update failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            errorMessage = Self.message(for: nsError, enabling: enabled)
            await refresh()
        }
        isUpdating = false
        if let text = errorMessage ?? statusMessage {
            announcer?.announce(text, priority: .high)
        }
    }

    /// `.notFound` counts as off: some installations report it until the first
    /// registration, so the user can still try (a failure is shown then).
    nonisolated static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    nonisolated static func message(for error: NSError, enabling: Bool) -> String {
        if error.code == kSMErrorInvalidSignature {
            return String(localized: "Orbit is not validly signed, so it cannot open at login.")
        }
        if error.code == kSMErrorJobNotFound || error.code == kSMErrorServiceUnavailable {
            return String(localized: "Opening at login is not available for this copy of Orbit. Move Orbit to the Applications folder and open it from there.")
        }
        if error.code == kSMErrorLaunchDeniedByUser {
            return String(localized: "Opening at login was denied in System Settings.")
        }
        return enabling
            ? String(localized: "Orbit could not be added to the login items.")
            : String(localized: "Orbit could not be removed from the login items.")
    }
}
