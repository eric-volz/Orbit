import Foundation

/// Shared server state: the JSONL request log and the thinking blocks the
/// server issued, so it can check that clients echo them back unchanged.
actor ServerState {
    /// A `#thinking` turn the server produced.
    private struct IssuedThinking {
        var text: String
        var toolUseIDs: Set<String>
        var replyText: String
    }

    private let logHandle: FileHandle?
    private var issuedThinking: [String: IssuedThinking] = [:]
    private var issuedRedacted: Set<String> = []

    init(logURL: URL?) throws {
        if let logURL {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: logURL.path])
                }
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            logHandle = handle
        } else {
            logHandle = nil
        }
    }

    // MARK: Log

    /// Appends a request body as one JSON line (compacted if it spans lines).
    func logRequestBody(_ body: Data, parsed: JSON?) {
        guard let logHandle else { return }
        var line: Data
        if let parsed {
            let isSingleLine = !body.contains(UInt8(ascii: "\n")) && !body.contains(UInt8(ascii: "\r"))
            line = isSingleLine ? body : parsed.serializedData
        } else {
            let text = String(decoding: body, as: UTF8.self)
            line = (["event": "INVALID_REQUEST_BODY", "body": .string(text)] as JSON).serializedData
        }
        line.append(UInt8(ascii: "\n"))
        write(line, to: logHandle)
    }

    /// Appends a server event line, e.g. `{"event":"THINKING_ECHO_OK",…}`.
    func logEvent(_ name: String, details: [(key: String, value: JSON)] = []) {
        guard let logHandle else { return }
        var line = JSON.object([(key: "event", value: .string(name))] + details).serializedData
        line.append(UInt8(ascii: "\n"))
        write(line, to: logHandle)
    }

    private func write(_ data: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            printError("FakeLLMServer: cannot write the request log: \(error.localizedDescription)")
        }
    }

    func close() {
        try? logHandle?.synchronize()
        try? logHandle?.close()
    }

    // MARK: Thinking echo

    /// Remembers the thinking blocks of a turn that was just sent.
    func registerIssued(turn: ScriptedTurn) {
        let toolUseIDs = Set(turn.blocks.compactMap { block -> String? in
            if case .toolUse(let id, _, _) = block { return id }
            return nil
        })
        for block in turn.blocks {
            switch block {
            case .thinking(let text, let signature):
                issuedThinking[signature] = IssuedThinking(text: text, toolUseIDs: toolUseIDs, replyText: turn.visibleText)
            case .redactedThinking(let data):
                issuedRedacted.insert(data)
            default:
                break
            }
        }
    }

    /// Checks that every thinking block this server issued comes back
    /// unchanged in an Anthropic request. Returns nil when the request carries
    /// no thinking-related history, else the problems found (empty = OK).
    func verifyThinkingEcho(in body: JSON) -> [String]? {
        guard !issuedThinking.isEmpty || !issuedRedacted.isEmpty else { return nil }
        var checked = 0
        var problems: [String] = []
        let messages = body["messages"]?.arrayValue ?? []
        for (messageIndex, message) in messages.enumerated() where message["role"]?.stringValue == "assistant" {
            let blocks = message["content"]?.arrayValue ?? []
            var sawThinking = false
            for (blockIndex, block) in blocks.enumerated() {
                let location = "messages.\(messageIndex).content.\(blockIndex)"
                switch block["type"]?.stringValue {
                case "thinking":
                    sawThinking = true
                    checked += 1
                    let text = block["thinking"]?.stringValue ?? ""
                    let signature = block["signature"]?.stringValue ?? ""
                    if let issued = issuedThinking[signature] {
                        if !Array(issued.text.unicodeScalars).elementsEqual(text.unicodeScalars) {
                            problems.append("\(location): thinking text differs from what was sent")
                        }
                    } else if issuedThinking.values.contains(where: { Array($0.text.unicodeScalars).elementsEqual(text.unicodeScalars) }) {
                        problems.append("\(location): signature differs from what was sent")
                    } else {
                        problems.append("\(location): unknown thinking block (not issued by this server)")
                    }
                case "redacted_thinking":
                    sawThinking = true
                    checked += 1
                    if !issuedRedacted.contains(block["data"]?.stringValue ?? "") {
                        problems.append("\(location): redacted_thinking data differs from what was sent")
                    }
                default:
                    continue
                }
            }
            if !sawThinking, let dropped = droppedThinking(in: blocks) {
                checked += 1
                problems.append("messages.\(messageIndex): \(dropped)")
            }
        }
        return checked == 0 ? nil : problems
    }

    /// Detects an assistant message this server sent with thinking whose
    /// thinking blocks the client dropped.
    private func droppedThinking(in blocks: [JSON]) -> String? {
        let toolUseIDs = Set(blocks.compactMap { $0["type"]?.stringValue == "tool_use" ? $0["id"]?.stringValue : nil })
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
        for issued in issuedThinking.values {
            if !issued.toolUseIDs.isDisjoint(with: toolUseIDs) || (!issued.replyText.isEmpty && issued.replyText == text) {
                return "thinking block missing (dropped by the client)"
            }
        }
        return nil
    }
}

/// Writes a line to standard error.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Writes a line to standard output (unbuffered).
func printOutput(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}
