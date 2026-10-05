import Foundation

/// Orbit's System Events script (`Resources/AppleScripts/system-appearance.applescript`):
/// switches between the light and the dark appearance. Live through
/// `LiveAppleScriptRunner` (needs Automation: System Events; macOS asks the
/// first time, after the user confirmed `set_appearance`); tests pass a mock
/// runner, the DEBUG fake-data mode one that records.
struct SystemEventsService: Sendable {
    /// Room for macOS's prompt the first time, within the tool deadline.
    static let appearanceScript = AppleScript(name: "system-appearance", app: .systemEvents, timeout: .seconds(30))
    static let scripts = [appearanceScript]

    /// `{"dark": true, "changed": true}`: the appearance afterwards, and
    /// whether it was different before.
    struct AppearanceAnswer: Codable, Sendable, Hashable {
        var dark: Bool
        var changed: Bool
    }

    let runner: any AppleScriptRunning

    /// Switches to the dark (`dark`) or the light appearance. Throws `AppleScriptError`.
    func setAppearance(dark: Bool) async throws -> AppearanceAnswer {
        try await runner.runJSON(Self.appearanceScript, arguments: [dark ? "dark" : "light"])
    }
}

/// `set_appearance`: switches macOS between light and dark, only after the
/// user confirmed it on a card.
struct SetAppearanceTool: Tool {
    let context: SystemToolContext

    let name = "set_appearance"
    var displayName: String { String(localized: "Change appearance") }
    var description: String {
        """
        Switches macOS between the light and the dark appearance (Dark Mode), only after the user confirmed it on a \
        card. Use it when the user asks to turn dark mode on or off, or for a light or dark look. 'dark': true for \
        dark, false for light. It controls System Events, which macOS asks the user to allow the first time. Not \
        for single apps, the screen brightness or Night Shift.
        """
    }
    var inputSchema: JSONSchema {
        .object(properties: [
            "dark": .boolean(description: "true: dark appearance; false: light appearance."),
        ], required: ["dark"])
    }
    let riskLevel: ToolRiskLevel = .write
    let category: ToolCategory = .system
    var requiredPermissions: [PermissionKind] { [.automationSystemEvents] }

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Changing the appearance…")
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        let dark = (try? arguments.bool("dark", default: true)) ?? true
        return ConfirmationRequest(
            toolName: name,
            riskLevel: riskLevel,
            title: String(localized: "Change appearance"),
            message: dark ? String(localized: "Orbit switches macOS to the dark appearance.")
                : String(localized: "Orbit switches macOS to the light appearance."),
            fields: [
                ConfirmationField(id: "dark", label: String(localized: "Appearance"),
                                  value: dark ? String(localized: "Dark") : String(localized: "Light"), kind: .readOnly),
            ],
            confirmLabel: String(localized: "Switch")
        )
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        guard arguments.has("dark") else { throw ToolError.invalidArgument("Missing required parameter 'dark'.") }
        let dark = try arguments.bool("dark", default: true)
        let answer: SystemEventsService.AppearanceAnswer
        do {
            answer = try await context.systemEvents.setAppearance(dark: dark)
        } catch let error as AppleScriptError {
            throw error.toolError(for: SystemEventsService.appearanceScript)
        }
        let mode = answer.dark ? "dark" : "light"
        let title = answer.dark ? String(localized: "Dark appearance") : String(localized: "Light appearance")
        let symbol = answer.dark ? "moon.fill" : "sun.max.fill"
        guard answer.changed else {
            return ToolResult(
                text: "macOS already used the \(mode) appearance; nothing changed.",
                card: .info(InfoItem(title: title, detail: String(localized: "Already set, nothing changed."),
                                     systemImage: symbol)),
                summary: answer.dark ? String(localized: "Appearance was already dark")
                    : String(localized: "Appearance was already light")
            )
        }
        return ToolResult(
            text: "macOS now uses the \(mode) appearance.",
            card: .info(InfoItem(title: title, detail: String(localized: "Turned on for all apps."), systemImage: symbol)),
            summary: answer.dark ? String(localized: "Dark appearance turned on")
                : String(localized: "Light appearance turned on")
        )
    }
}
