import Foundation

/// `reveal_in_finder`: shows a file or folder selected in a Finder window.
/// Nothing is opened or disclosed, so it also works for apps, scripts and items
/// in ~/Library, but never for secrets or outside a debug scope.
struct RevealInFinderTool: Tool {
    let context: FileToolContext

    let name = "reveal_in_finder"
    var displayName: String { String(localized: "Show in Finder") }
    let description = """
        Shows a file or folder in Finder, selected in its enclosing folder, without opening it. Use it when the \
        user asks where a file is or wants to see it in Finder, and for items open_file refuses (apps, scripts, \
        installers). Takes a path from search_files, recent_files or the Finder selection.
        """
    var inputSchema: JSONSchema {
        .object(properties: [
            "path": .string(description: FileToolContext.pathDescription(of: "file or folder")),
        ], required: ["path"])
    }
    let riskLevel: ToolRiskLevel = .draft
    let category: ToolCategory = .files

    func statusText(for arguments: ToolArguments) -> String {
        String(format: String(localized: "Showing “%@” in Finder…"), FileToolContext.fileName(in: arguments))
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        var path = try context.absolutePath(try arguments.string("path"), parameter: "path")
        if let denied = try context.checkAccess(&path, purpose: .reveal) {
            return denied
        }
        await context.workspace.reveal(URL(fileURLWithPath: path))
        return ToolResult(text: "Showed \(context.display(path)) in Finder.",
                          summary: String(localized: "Shown in Finder"))
    }
}
