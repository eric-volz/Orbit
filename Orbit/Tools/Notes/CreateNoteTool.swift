import Foundation

/// `create_note`: creates a note in Apple Notes, only after the user
/// confirmed it on a card where title, text and folder can still be edited.
struct CreateNoteTool: Tool {
    static let maxBodyCharacters = 100_000

    let context: NotesToolContext

    let name = "create_note"
    var displayName: String { String(localized: "Create note") }
    let description = """
        Creates a new note in Apple Notes with a title and a plain-text body, optionally in a folder given by its \
        name (without one, in the default folder). Use it when the user asks to write something down, save a \
        list or an idea, or keep text as a note. The user first sees a confirmation card where they can edit the \
        title, the text and the folder; the note is only created after they confirm, so never say it exists \
        unless the result confirms it. The body is plain text exactly as it should appear: one line per line, \
        no Markdown (write "- " for list items). The title becomes the note's first line, so do not repeat it in \
        the body. Returns the new note's id for open_note.
        """
    var inputSchema: JSONSchema {
        .object(properties: [
            "title": .string(description: "The note's title (its first line), e.g. \"Einkaufsliste\"."),
            "body": .string(description: "The note's text below the title, plain text with line breaks; may be empty."),
            "folder": .string(description: "Name of an existing Notes folder, e.g. \"Rezepte\". Leave it out for the default folder."),
        ], required: ["title", "body"])
    }
    let riskLevel: ToolRiskLevel = .write
    let category: ToolCategory = .notes
    var requiredPermissions: [PermissionKind] { [.automationNotes] }

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Creating note…")
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        ConfirmationRequest(
            toolName: name,
            riskLevel: riskLevel,
            title: String(localized: "Create note"),
            message: String(localized: "Orbit creates this note in Notes. Without a folder, it goes to the default folder."),
            fields: [
                ConfirmationField(id: "title", label: String(localized: "Title"),
                                  value: NoteText.singleLine(arguments.optionalString("title") ?? ""), kind: .text),
                ConfirmationField(id: "body", label: String(localized: "Text"),
                                  value: arguments["body"]?.stringValue ?? "", kind: .multilineText),
                ConfirmationField(id: "folder", label: String(localized: "Folder"),
                                  value: arguments.optionalString("folder") ?? "", kind: .text),
            ],
            confirmLabel: String(localized: "Create")
        )
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let title = NoteText.singleLine(arguments.optionalString("title") ?? "")
        guard !title.isEmpty else {
            throw ToolError.invalidArgument("'title' must not be empty.")
        }
        let body = NoteText.cleaned(arguments["body"]?.stringValue ?? "")
        guard body.count <= Self.maxBodyCharacters else {
            throw ToolError.invalidArgument("'body' may have at most \(Self.maxBodyCharacters) characters.")
        }
        let folder = arguments.optionalString("folder").map(NoteText.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        let html = NoteText.html(title: title, body: body)
        let created: CreatedNote
        do {
            created = try await context.perform(NotesService.createScript) {
                try await context.notes.create(html: html, folder: folder)
            }
        } catch NotesFailure.folderNotFound(let name, let existing) {
            return NotesToolContext.folderNotFound(name, existing: existing, action: "no note was created")
        }
        let shownTitle = created.name.isEmpty ? title : created.name
        let place = created.folder.isEmpty ? "" : " in the folder \"\(NotesToolContext.inline(created.folder, maxCharacters: 100))\""
        let item = NotesToolContext.item(id: created.id, title: shownTitle,
                                         excerpt: NoteText.excerpt(from: body, title: title, maxCharacters: SearchNotesTool.excerptCharacters),
                                         folder: created.folder, modified: context.now())
        return ToolResult(
            text: "Created the note \"\(NotesToolContext.inline(shownTitle))\"\(place) in Notes (id \(created.id)). Use open_note with this id to show it.",
            card: .notes([item]),
            summary: String(format: String(localized: "Created note “%@”"), shownTitle),
            // The folder's name (the model may not have named it: the default folder).
            disclosure: created.folder.isEmpty ? nil : ContentDisclosure(kind: .folderNames, count: 1)
        )
    }
}
