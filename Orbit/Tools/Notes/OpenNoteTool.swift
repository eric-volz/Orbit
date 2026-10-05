import Foundation

/// `open_note`: shows one note in the Notes app (Notes comes to the front).
struct OpenNoteTool: Tool {
    let context: NotesToolContext

    let name = "open_note"
    var displayName: String { String(localized: "Open note") }
    let description = """
        Opens one note in the Notes app: brings Notes to the front and shows the note, by the id search_notes or \
        create_note returned. Use it when the user wants to see, edit or continue a note themselves, or to unlock \
        a locked note. It changes nothing in the note.
        """
    var inputSchema: JSONSchema {
        .object(properties: [
            "id": .string(description: NotesToolContext.idDescription),
        ], required: ["id"])
    }
    let riskLevel: ToolRiskLevel = .draft
    let category: ToolCategory = .notes
    var requiredPermissions: [PermissionKind] { [.automationNotes] }

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Opening note…")
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let id = try NotesToolContext.noteID(in: arguments)
        let name = try await context.perform(NotesService.openScript) {
            try await context.notes.open(id: id)
        }
        let title = name.isEmpty ? String(localized: "New Note") : name
        return ToolResult(text: "Opened the note \"\(NotesToolContext.inline(name.isEmpty ? "(untitled)" : name))\" in Notes.",
                          summary: String(format: String(localized: "Opened “%@” in Notes"), title))
    }
}
