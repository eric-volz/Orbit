import Foundation

/// The API dialect of a chat request.
enum Flavor: String, Sendable {
    case anthropic
    case openAI = "openai"
}

/// What the fake server needs to know about a chat request, independent of
/// the dialect.
struct ChatRequest: Sendable {
    var flavor: Flavor
    var model: String
    var stream: Bool
    /// OpenAI `stream_options.include_usage`.
    var includeUsage: Bool
    var messageCount: Int
    var toolCount: Int
    var systemPromptLength: Int
    /// The scenario source: the last text block of the last user message, or
    /// the last one that contains a `#command` line (context blocks may follow).
    var lastUserText: String?
    /// Texts of the tool results in the last message, nil when it has none.
    var toolResults: [String]?
    var body: JSON

    enum Invalid: Error, CustomStringConvertible {
        case notAnObject
        case missingMessages

        var description: String {
            switch self {
            case .notAnObject: "request body must be a JSON object"
            case .missingMessages: "messages: field required"
            }
        }
    }

    init(flavor: Flavor, body: JSON) throws {
        guard body.isObject else { throw Invalid.notAnObject }
        guard let messages = body["messages"]?.arrayValue else { throw Invalid.missingMessages }
        self.flavor = flavor
        self.body = body
        model = body["model"]?.stringValue ?? "fake-model"
        stream = body["stream"]?.boolValue ?? false
        includeUsage = body["stream_options"]?["include_usage"]?.boolValue ?? false
        messageCount = messages.count
        toolCount = body["tools"]?.arrayValue?.count ?? 0

        switch flavor {
        case .anthropic:
            systemPromptLength = Self.texts(of: body["system"]).joined().count
            lastUserText = messages.last(where: { $0["role"]?.stringValue == "user" })
                .flatMap { Self.scenarioText(in: Self.texts(of: $0["content"], blockType: "text")) }
            if let last = messages.last, last["role"]?.stringValue == "user",
               let blocks = last["content"]?.arrayValue {
                let results = blocks.filter { $0["type"]?.stringValue == "tool_result" }
                toolResults = results.isEmpty ? nil : results.map { Self.texts(of: $0["content"]).joined(separator: "\n") }
            } else {
                toolResults = nil
            }
        case .openAI:
            systemPromptLength = messages
                .filter { ["system", "developer"].contains($0["role"]?.stringValue ?? "") }
                .map { Self.texts(of: $0["content"]).joined() }
                .joined().count
            lastUserText = messages.last(where: { $0["role"]?.stringValue == "user" })
                .flatMap { Self.scenarioText(in: Self.texts(of: $0["content"])) }
            let trailingToolMessages = messages.reversed().prefix(while: { $0["role"]?.stringValue == "tool" }).reversed()
            toolResults = trailingToolMessages.isEmpty
                ? nil
                : trailingToolMessages.map { Self.texts(of: $0["content"]).joined(separator: "\n") }
        }
    }

    static func scenarioText(in texts: [String]) -> String? {
        let hasCommand = { (text: String) in
            text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        }
        return texts.last(where: hasCommand) ?? texts.last
    }

    /// Text of a `content` value: a plain string, or the `text` of each block
    /// (optionally only blocks of `blockType`).
    static func texts(of content: JSON?, blockType: String? = nil) -> [String] {
        switch content {
        case .string(let text):
            return [text]
        case .array(let blocks):
            return blocks.compactMap { block in
                if let blockType, block["type"]?.stringValue != blockType { return nil }
                return block["text"]?.stringValue
            }
        default:
            return []
        }
    }
}

/// A scripted assistant turn, rendered by the dialect-specific streamers.
struct ScriptedTurn: Sendable {
    enum Block: Sendable {
        case thinking(text: String, signature: String)
        case redactedThinking(data: String)
        case text(String)
        /// `inputJSON` is sent verbatim, so it may be invalid or truncated.
        case toolUse(id: String, name: String, inputJSON: String)
    }

    enum Stop: Sendable {
        case endTurn
        case toolUse
        case maxTokens
        case refusal(category: String)
    }

    var blocks: [Block]
    /// nil: the stream ends with an `overloaded_error` event instead of a stop.
    var stop: Stop?
    /// Pause before each streamed chunk.
    var chunkDelay: Duration

    var visibleText: String {
        blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }
}

/// What to answer: a scripted turn or an HTTP error.
enum Scenario: Sendable {
    case turn(ScriptedTurn, name: String)
    case httpError(status: Int, message: String?)

    var name: String {
        switch self {
        case .turn(_, let name): name
        case .httpError(let status, _): "error \(status)"
        }
    }
}

/// Parses the scenario commands from the last user text:
///
///     #markdown | #tool <name> [json] | #error <status> [message] | #midstream-error
///     #refusal | #slow | #maxtokens | (anything else: echo)
///
/// `#thinking` and `#redacted` are flags that prefix any command, e.g.
/// `#thinking #tool search_files {"query":"x"}`.
struct Command: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case echo(String)
        case markdown
        case tool(name: String, json: String)
        case error(status: Int, message: String?)
        case midstreamError
        case refusal
        case slow
        case maxTokens
    }

    var thinking = false
    var redacted = false
    var action: Action

    static func parse(_ text: String) -> Command {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The command may follow context lines; it starts at the first line beginning with '#'.
        let lines = trimmed.components(separatedBy: "\n")
        guard let commandLine = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) else {
            return Command(action: .echo(trimmed))
        }
        var rest = Substring(lines[commandLine...].joined(separator: "\n").trimmingCharacters(in: .whitespaces))
        var command = Command(action: .echo(trimmed))
        while let token = rest.split(whereSeparator: \.isWhitespace).first, token.hasPrefix("#") {
            let remainder = rest.dropFirst(token.count).drop(while: \.isWhitespace)
            switch token.lowercased() {
            case "#thinking":
                command.thinking = true
            case "#redacted":
                command.redacted = true
            case "#markdown":
                command.action = .markdown
                return command
            case "#midstream-error":
                command.action = .midstreamError
                return command
            case "#refusal":
                command.action = .refusal
                return command
            case "#slow":
                command.action = .slow
                return command
            case "#maxtokens":
                command.action = .maxTokens
                return command
            case "#tool":
                let name = remainder.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "tool"
                let json = remainder.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
                command.action = .tool(name: name, json: json.isEmpty ? "{}" : json)
                return command
            case "#error":
                let parts = remainder.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                let status = parts.first.flatMap { Int($0) }.flatMap { (400...599).contains($0) ? $0 : nil } ?? 500
                let message = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
                command.action = .error(status: status, message: message)
                return command
            default:
                // Unknown command: echo the whole text.
                return Command(action: .echo(trimmed))
            }
            rest = remainder
        }
        // Only flags: echo what follows them (or the full text when nothing does).
        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        command.action = .echo(remainder.isEmpty ? trimmed : remainder)
        return command
    }
}

// MARK: - Building turns

enum ScenarioBuilder {
    static let defaultChunkDelay: Duration = .milliseconds(25)
    static let slowChunkDelay: Duration = .milliseconds(300)

    /// Thinking text with characters a client could mangle (quotes, backslash,
    /// newline, tab, a decomposed "é", emoji); the echo check compares scalars.
    static let thinkingText = """
        Der Nutzer möchte eine Antwort. Ich prüfe „Umlaute“, "Anführungszeichen", Backslash \\ und Tab\t.
        Zweite Zeile: zerlegtes e\u{301}, vorkomponiertes é, Emoji 🚀, Pfad /tmp/test.
        """

    static let markdownReply = """
        ## Überschrift

        Ein Absatz mit **fett**, *kursiv*, `Code` und einem [Link](https://example.com).

        - Erster Punkt
        - Zweiter Punkt
          - Unterpunkt

        1. Eins
        2. Zwei

        | Datei | Größe | Geändert |
        |:------|------:|---------:|
        | Rechnung.pdf | 120 KB | 03.03.2026 |
        | Notizen.txt | 2 KB | 12.07.2026 |

        ```swift
        let greeting = "Hallo, Welt"
        print(greeting)
        ```

        > Ein Zitat zum Schluss.
        """

    static func scenario(for request: ChatRequest, chunkDelay: Duration = defaultChunkDelay) -> Scenario {
        if let results = request.toolResults {
            let joined = results.joined(separator: "\n")
            let turn = ScriptedTurn(blocks: [.text("Tool result: " + String(joined.prefix(200)))],
                                    stop: .endTurn, chunkDelay: chunkDelay)
            return .turn(turn, name: "tool-result")
        }

        let command = Command.parse(request.lastUserText ?? "")
        var blocks: [ScriptedTurn.Block] = []
        if command.thinking {
            blocks.append(.thinking(text: thinkingText, signature: "fake/sig+" + randomBase64(bytes: 48)))
        }
        if command.redacted {
            blocks.append(.redactedThinking(data: "fake/redacted+" + randomBase64(bytes: 64)))
        }
        var name = [command.thinking ? "thinking" : nil, command.redacted ? "redacted" : nil].compactMap { $0 }

        let stop: ScriptedTurn.Stop?
        var delay = chunkDelay
        switch command.action {
        case .echo(let text):
            let footer = "_Nachrichten im Verlauf: \(request.messageCount) · Werkzeuge: \(request.toolCount) · System-Prompt: \(request.systemPromptLength) Zeichen_"
            blocks.append(.text("**Echo:** \(text.isEmpty ? "(leer)" : text)\n\n\(footer)"))
            stop = .endTurn
            name.append("echo")
        case .markdown:
            blocks.append(.text(markdownReply))
            stop = .endTurn
            name.append("markdown")
        case .tool(let toolName, let json):
            blocks.append(.text("Ich verwende das Werkzeug `\(toolName)`."))
            blocks.append(.toolUse(id: identifier(for: request.flavor, tool: true), name: toolName, inputJSON: json))
            stop = .toolUse
            name.append("tool(\(toolName))")
        case .error(let status, let message):
            return .httpError(status: status, message: message)
        case .midstreamError:
            blocks.append(.text("Das ist der Anfang einer Antwort, die gleich mit einem Fehler abbricht."))
            stop = nil
            name.append("midstream-error")
        case .refusal:
            blocks.append(.text("Ich beginne mit einer Antwort, aber"))
            stop = .refusal(category: "cyber")
            name.append("refusal")
        case .slow:
            blocks.append(.text((1...60).map { "Wort-\($0)" }.joined(separator: " ")))
            stop = .endTurn
            delay = slowChunkDelay
            name.append("slow")
        case .maxTokens:
            blocks.append(.toolUse(id: identifier(for: request.flavor, tool: true), name: "search_files",
                                   inputJSON: #"{"query": "Rechnung März", "kind": "pd"#))
            stop = .maxTokens
            name.append("maxtokens")
        }
        return .turn(ScriptedTurn(blocks: blocks, stop: stop, chunkDelay: delay), name: name.joined(separator: "+"))
    }

    // MARK: Helpers

    /// Splits text into word-sized chunks whose concatenation is the input.
    static func wordChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var inWhitespace = false
        for character in text {
            if character.isWhitespace {
                inWhitespace = true
            } else if inWhitespace {
                chunks.append(current)
                current = ""
                inWhitespace = false
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Splits tool input JSON into 2 or 3 fragments (fewer for tiny inputs).
    static func fragments(_ json: String) -> [String] {
        let characters = Array(json)
        switch characters.count {
        case 0: return [""]
        case 1: return [json]
        case 2: return [String(characters[0..<1]), String(characters[1...])]
        default:
            let first = characters.count / 3
            let second = 2 * characters.count / 3
            return [String(characters[..<first]), String(characters[first..<second]), String(characters[second...])]
        }
    }

    static func randomHex(_ count: Int) -> String {
        String((0..<count).map { _ in "0123456789abcdef".randomElement()! })
    }

    static func randomBase64(bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    static func identifier(for flavor: Flavor, tool: Bool) -> String {
        switch (flavor, tool) {
        case (.anthropic, true): "toolu_fake_" + randomHex(20)
        case (.anthropic, false): "msg_fake_" + randomHex(20)
        case (.openAI, true): "call_fake_" + randomHex(16)
        case (.openAI, false): "chatcmpl-fake-" + randomHex(16)
        }
    }
}
