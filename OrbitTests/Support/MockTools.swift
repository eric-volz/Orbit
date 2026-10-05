import Foundation
import os
@testable import Orbit

/// Records tool invocations across tasks.
final class MockToolLog: Sendable {
    struct Entry: Sendable, Hashable {
        var tool: String
        var arguments: ToolArguments
    }

    private let state = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    var entries: [Entry] { state.withLock { $0 } }

    func record(_ tool: String, _ arguments: ToolArguments) {
        state.withLock { $0.append(Entry(tool: tool, arguments: arguments)) }
    }

    func arguments(of tool: String) -> [ToolArguments] {
        entries.filter { $0.tool == tool }.map(\.arguments)
    }
}

/// Measures how many tool runs overlap.
actor MockConcurrencyTracker {
    private(set) var running = 0
    private(set) var maximum = 0

    func begin() {
        running += 1
        maximum = max(maximum, running)
    }

    func end() {
        running -= 1
    }
}

/// `search_files`: read-only, returns a card, a summary and a disclosure.
struct MockSearchFilesTool: Tool {
    var log: MockToolLog
    var name = "search_files"
    var description = "Searches the user's files by name and content."
    var inputSchema: JSONSchema = .object(properties: [
        "query": .string(description: "Words to search for."),
        "limit": .integer(description: "Maximum number of results.", minimum: 1, maximum: 50),
    ], required: ["query"])
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .files

    static let files = [
        FileItem(path: "/Users/test/Documents/Rechnung-März.pdf", name: "Rechnung-März.pdf", contentType: "com.adobe.pdf"),
        FileItem(path: "/Users/test/Documents/Rechnung-April.pdf", name: "Rechnung-April.pdf", contentType: "com.adobe.pdf"),
    ]

    func statusText(for arguments: ToolArguments) -> String {
        "Searching files…"
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        let query = try arguments.string("query")
        let lines = Self.files.map { "- \($0.name) (\($0.path))" }.joined(separator: "\n")
        return ToolResult(
            text: "Found \(Self.files.count) files for '\(query)':\n\(lines)",
            card: .files(Self.files),
            summary: "2 Dateien gefunden",
            disclosure: ContentDisclosure(kind: .fileNames, count: Self.files.count)
        )
    }
}

/// A read-only tool that takes a while and records overlapping runs.
struct MockSlowReadTool: Tool {
    var name: String
    var delay: Duration
    var tracker: MockConcurrencyTracker
    var log: MockToolLog
    var description = "Slow read-only test tool."
    var inputSchema: JSONSchema = .empty
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .files

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        await tracker.begin()
        do {
            try await Task.sleep(for: delay)
        } catch {
            await tracker.end()
            throw error
        }
        await tracker.end()
        return ToolResult(text: "result of \(name)", card: .info(InfoItem(title: name, systemImage: "doc")), summary: "\(name) fertig")
    }
}

/// `create_note`: a write tool with editable confirmation fields.
struct MockCreateNoteTool: Tool {
    var log: MockToolLog
    var name = "create_note"
    var description = "Creates a note in Apple Notes."
    var inputSchema: JSONSchema = .object(properties: [
        "title": .string(description: "Title of the note.", minLength: 1),
        "body": .string(description: "Text of the note."),
    ], required: ["title", "body"])
    var riskLevel: ToolRiskLevel = .write
    var category: ToolCategory = .notes

    func statusText(for arguments: ToolArguments) -> String {
        "Creating note…"
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        ConfirmationRequest(
            toolName: name,
            riskLevel: .read, // deliberately wrong: the agent loop must enforce the tool's level
            title: "Create note",
            message: "Orbit möchte eine Notiz erstellen.",
            fields: [
                ConfirmationField(id: "title", label: "Titel", value: arguments.optionalString("title") ?? "", kind: .text),
                ConfirmationField(id: "body", label: "Text", value: arguments.optionalString("body") ?? "", kind: .multilineText),
            ]
        )
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        let title = try arguments.string("title")
        return ToolResult(
            text: "Created the note '\(title)'.",
            card: .info(InfoItem(title: title, detail: "Notiz erstellt", systemImage: "note.text")),
            summary: "Notiz erstellt"
        )
    }
}

/// `open_app`: a draft-level tool (no confirmation, but not read-only).
struct MockOpenAppTool: Tool {
    var log: MockToolLog
    var tracker: MockConcurrencyTracker
    var name = "open_app"
    var description = "Opens an app."
    var inputSchema: JSONSchema = .object(properties: ["name": .string(description: "App name.")], required: ["name"])
    var riskLevel: ToolRiskLevel = .draft
    var category: ToolCategory = .apps

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        await tracker.begin()
        try? await Task.sleep(for: .milliseconds(30))
        await tracker.end()
        return ToolResult(text: "Opened \(try arguments.string("name")).", summary: "App geöffnet")
    }
}

/// `search_mail`: needs the Mail automation permission.
struct MockSearchMailTool: Tool {
    var log: MockToolLog
    var name = "search_mail"
    var description = "Searches mail."
    var inputSchema: JSONSchema = .object(properties: ["query": .string()])
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .mail
    var requiredPermissions: [PermissionKind] = [.automationMail]

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        return ToolResult(text: "No mails.", summary: "Keine Mails", disclosure: ContentDisclosure(kind: .emails, count: 3))
    }
}

/// A tool that throws.
struct MockFailingTool: Tool {
    enum Failure: Error { case boom }

    var name = "failing_tool"
    var error: any Error & Sendable = Failure.boom
    var description = "Always fails."
    var inputSchema: JSONSchema = .empty
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .system

    func run(arguments: ToolArguments) async throws -> ToolResult {
        throw error
    }
}

/// A tool that never finishes and ignores cancellation until `release` opens.
struct MockStuckTool: Tool {
    var release: AsyncGate
    var name = "stuck_tool"
    var description = "Never finishes."
    var inputSchema: JSONSchema = .empty
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .system

    func run(arguments: ToolArguments) async throws -> ToolResult {
        await release.waitIgnoringCancellation()
        return ToolResult(text: "finally")
    }
}

/// A tool whose run blocks until the test opens `release` (cancellation-aware).
struct MockBlockingTool: Tool {
    var started: AsyncGate
    var release: AsyncGate
    var log: MockToolLog
    var name = "blocking_tool"
    var description = "Waits for the test."
    var inputSchema: JSONSchema = .empty
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .system

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        started.open()
        await release.wait()
        try Task.checkCancellation()
        return ToolResult(text: "released")
    }
}

/// Returns a result far beyond the global cap.
struct MockLongOutputTool: Tool {
    static let length = 50_000
    var name = "long_output"
    var description = "Returns a lot of text."
    var inputSchema: JSONSchema = .empty
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .files

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let line = String(repeating: "x", count: 99) + "\n"
        return ToolResult(text: String(repeating: line, count: Self.length / 100))
    }
}
