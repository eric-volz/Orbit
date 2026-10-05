import SwiftUI

/// "Tools": every tool can be switched off, grouped by category, with its
/// risk level and (when macOS does not allow it) the missing permission.
struct ToolsSettingsView: View {
    @Bindable var settings: SettingsStore
    let tools: [ToolInfo]
    /// The permissions as last read (`PermissionManager.statuses`).
    var permissionStatuses: [PermissionKind: PermissionStatus] = [:]

    var body: some View {
        if tools.isEmpty {
            ContentUnavailableView {
                Label("No Tools Available", systemImage: "wrench.and.screwdriver")
            } description: {
                Text("As soon as Orbit brings tools for files, mail, calendars and more, you can turn each of them on and off here.")
            }
        } else {
            Form {
                ForEach(ToolSection.sections(for: tools)) { section in
                    Section {
                        ForEach(section.tools) { tool in
                            Toggle(isOn: binding(for: tool)) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        if tool.displayName.isEmpty || tool.displayName == tool.name {
                                            Text(verbatim: tool.name)
                                                .font(.system(size: 12.5, design: .monospaced))
                                        } else {
                                            Text(verbatim: tool.displayName)
                                            Text(verbatim: tool.name)
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        if let missing = missingPermission(of: tool) {
                                            Label {
                                                Text(verbatim: String(format: String(localized: "Missing permission: %@"), missing.displayName))
                                            } icon: {
                                                Image(systemName: "lock.fill")
                                            }
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.orange)
                                            .help(Text("Allow access in Settings > Permissions. Until then, Orbit does not offer this tool."))
                                        }
                                    }
                                    RiskBadge(level: tool.riskLevel)
                                }
                            }
                        }
                    } header: {
                        Label(section.category.displayName, systemImage: section.category.systemImage)
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Orbit does not offer turned-off tools to the model, and it never carries out actions with consequences without your confirmation.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The first permission macOS does not allow for this tool, if any.
    func missingPermission(of tool: ToolInfo) -> PermissionKind? {
        tool.requiredPermissions.first { permission in
            permissionStatuses[permission].map { !$0.allowsUse } ?? false
        }
    }

    private func binding(for tool: ToolInfo) -> Binding<Bool> {
        Binding {
            settings.isToolEnabled(tool.name)
        } set: { isEnabled in
            settings.setTool(tool.name, enabled: isEnabled)
        }
    }
}

/// Tools of one category in the order they are registered (the most used
/// first, e.g. Search files, Read file, Open file; an alphabetical sort
/// would read at random); categories in their declared order.
struct ToolSection: Identifiable, Equatable {
    var category: ToolCategory
    var tools: [ToolInfo]

    var id: ToolCategory { category }

    static func sections(for tools: [ToolInfo]) -> [ToolSection] {
        ToolCategory.allCases.compactMap { category in
            let matching = tools.filter { $0.category == category }
            return matching.isEmpty ? nil : ToolSection(category: category, tools: matching)
        }
    }
}

/// A small colored label for a tool's risk level.
struct RiskBadge: View {
    let level: ToolRiskLevel

    var body: some View {
        Text(Self.title(level))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.color(for: level))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.color(for: level).opacity(0.14)))
            .help(Self.explanation(level))
    }

    static func title(_ level: ToolRiskLevel) -> String {
        switch level {
        case .read: String(localized: "Read")
        case .draft: String(localized: "Draft")
        case .write: String(localized: "Asks first")
        case .destructive: String(localized: "With warning")
        }
    }

    static func explanation(_ level: ToolRiskLevel) -> Text {
        switch level {
        case .read: Text("Only reads and runs without asking.")
        case .draft: Text("Opens or drafts something without sending it. Runs without asking.")
        case .write: Text("Changes something. Orbit asks first.")
        case .destructive: Text("Cannot be undone. Orbit asks first and shows a clear warning.")
        }
    }
}
