import Foundation

/// Metadata about a tool, for settings and the system prompt.
struct ToolInfo: Sendable, Hashable, Identifiable {
    var name: String
    /// Localized name for the UI (empty = use `name`).
    var displayName: String = ""
    var description: String
    var category: ToolCategory
    var riskLevel: ToolRiskLevel
    var requiredPermissions: [PermissionKind]

    var id: String { name }
}

/// Whether a tool can be used right now, and why not.
struct ToolAvailability: Sendable, Hashable, Identifiable {
    enum Reason: Sendable, Hashable {
        case disabledByUser
        case permissionMissing(PermissionKind)
    }

    var info: ToolInfo
    /// nil = available.
    var unavailableReason: Reason?

    var id: String { info.name }
    var isAvailable: Bool { unavailableReason == nil }

    /// English explanation for the model.
    var reasonForModel: String? {
        switch unavailableReason {
        case nil: nil
        case .disabledByUser: "disabled by the user in Orbit's settings"
        case .permissionMissing(let permission): "macOS permission '\(permission.displayName)' was not granted"
        }
    }
}

/// All tools Orbit knows. Immutable after creation.
final class ToolRegistry: Sendable {
    let tools: [any Tool]

    init(tools: [any Tool]) {
        var seen = Set<String>()
        for tool in tools {
            precondition(seen.insert(tool.name).inserted, "Duplicate tool name \(tool.name)")
        }
        self.tools = tools
    }

    var infos: [ToolInfo] {
        tools.map { tool in
            ToolInfo(name: tool.name, displayName: tool.displayName, description: tool.description, category: tool.category,
                     riskLevel: tool.riskLevel, requiredPermissions: tool.requiredPermissions)
        }
    }

    /// Looks a tool up by name. Tolerates names that differ only in case or in
    /// `_`/`-` (models occasionally produce those); returns nil when ambiguous.
    func tool(named name: String) -> (any Tool)? {
        if let exact = tools.first(where: { $0.name == name }) { return exact }
        if let match = JSONSchema.matchPropertyName(name, in: tools.map(\.name)) {
            return tools.first(where: { $0.name == match })
        }
        return nil
    }

    func availability(disabledToolNames: Set<String>, permissions: any PermissionStatusProviding) -> [ToolAvailability] {
        infos.map { info in
            if disabledToolNames.contains(info.name) {
                return ToolAvailability(info: info, unavailableReason: .disabledByUser)
            }
            if let missing = info.requiredPermissions.first(where: { !permissions.status(of: $0).allowsUse }) {
                return ToolAvailability(info: info, unavailableReason: .permissionMissing(missing))
            }
            return ToolAvailability(info: info, unavailableReason: nil)
        }
    }
}
