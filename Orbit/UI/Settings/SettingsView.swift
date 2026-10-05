import SwiftUI

/// The settings window content (about 620 × 480).
struct SettingsView: View {
    let environment: AppEnvironment
    @Bindable var navigation: SettingsNavigation

    init(environment: AppEnvironment, navigation: SettingsNavigation = SettingsNavigation()) {
        self.environment = environment
        self.navigation = navigation
    }

    var body: some View {
        TabView(selection: $navigation.tab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabContent(tab: tab, environment: environment, select: { navigation.tab = $0 })
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
        .frame(width: 620, height: 480)
        .environment(\.locale, AppLanguage.locale)
    }
}

/// The tab Settings shows: the window controller sets it to open Settings on a
/// tab (e.g. Permissions from the chat), the tab bar when the user clicks.
@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

/// The settings tabs, in display order.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case model
    case tools
    case permissions
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .model: String(localized: "Model")
        case .tools: String(localized: "Tools")
        case .permissions: String(localized: "Permissions")
        case .privacy: String(localized: "Privacy")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .model: "cpu"
        case .tools: "wrench.and.screwdriver"
        case .permissions: "lock.shield"
        case .privacy: "hand.raised"
        }
    }
}

/// The content of one tab, wired to the app's objects.
struct SettingsTabContent: View {
    let tab: SettingsTab
    let environment: AppEnvironment
    /// Switches the window to another tab (e.g. "Show Permissions…").
    var select: (SettingsTab) -> Void = { _ in }

    var body: some View {
        switch tab {
        case .general:
            GeneralSettingsView(settings: environment.settings, showPermissions: { select(.permissions) },
                                launchAtLogin: LaunchAtLoginModel(announcer: environment.services.announcer))
        case .model:
            ModelSettingsView(
                settings: environment.settings,
                secrets: environment.secrets,
                validate: { [agentLoop = environment.agentLoop] configuration, model in
                    try await agentLoop.validate(configuration: configuration, model: model)
                },
                claudeCodeAccount: ClaudeCodeAccountModel(
                    loadStatus: { [agentLoop = environment.agentLoop] in await agentLoop.claudeCodeStatus() },
                    signIn: { [agentLoop = environment.agentLoop] in try await agentLoop.signInToClaudeCode() },
                    announcer: environment.services.announcer
                ),
                usage: { [agentLoop = environment.agentLoop] in agentLoop.providerUsage },
                announcer: environment.services.announcer
            )
        case .tools:
            ToolsSettingsView(settings: environment.settings, tools: environment.agentLoop.toolInfos,
                              permissionStatuses: environment.permissions.statuses)
        case .permissions:
            PermissionsSettingsView(
                manager: environment.permissions,
                mailSearch: environment.permissions.permissions.contains(.automationMail)
                    ? environment.services.mailSpotlight : nil,
                relaunch: { AppRelauncher.relaunch() },
                announcer: environment.services.announcer
            )
        case .privacy:
            PrivacySettingsView(settings: environment.settings, announcer: environment.services.announcer,
                                clearHistory: { [agentLoop = environment.agentLoop] in await agentLoop.clearHistory() })
        }
    }
}
