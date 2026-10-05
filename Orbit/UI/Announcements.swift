import AppKit

/// Speaks a short text through VoiceOver, for changes it does not notice by
/// itself, such as the row the arrow keys moved to while the keyboard stays in
/// the input. Live: `VoiceOverAnnouncer`; tests record what would be said.
@MainActor
protocol Announcing: Sendable {
    /// `.high` interrupts what VoiceOver is saying (the latest arrow key
    /// wins); `.medium` lets it finish first.
    func announce(_ text: String, priority: NSAccessibilityPriorityLevel)
}

/// Asks VoiceOver (or another assistive app) to announce a text; nothing
/// happens when none is running.
struct VoiceOverAnnouncer: Announcing {
    func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        guard !text.isEmpty, let application = NSApp else { return }
        NSAccessibility.post(element: application, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: priority.rawValue,
        ])
    }
}

/// What VoiceOver hears of a request while the keyboard stays in the input:
/// each tool's outcome, a confirmation card that waits, and the answer once
/// it is complete, not the running steps or the streamed words. Notices are
/// announced where they are added (`AgentLoop`).
enum ChatAnnouncement {
    /// An answer longer than this is read up to here; the chat has all of it.
    static let maxAnswerCharacters = 2_000
    /// Of a longer answer only this much Markdown is turned into plain text
    /// (cut at a line break where it can): it holds more than VoiceOver reads
    /// unless it is mostly markup, and the main thread does not convert an
    /// answer of 30,000 characters (also without VoiceOver) for 2,000 of them.
    static let maxParsedCharacters = 3 * maxAnswerCharacters

    /// A finished tool call: its result line ("Found 3 emails"); a
    /// failure, or a result without its own line, with the tool's name
    /// ("Search mail: Timed out").
    static func toolFinished(toolName: String, status: String, failed: Bool, hasSummary: Bool) -> String {
        guard failed || !hasSummary else { return status }
        return String(format: String(localized: "%1$@: %2$@"), toolName, status)
    }

    /// A reply opened in Mail: its window takes the keyboard, and the panel tells
    /// VoiceOver where the reply's text is once its card is in view; the tool's
    /// result line would say less, first.
    static func isAnnouncedByThePanel(_ card: ResultCard?) -> Bool {
        if case .mailDraft(let draft)? = card { return draft.reply != nil }
        return false
    }

    /// A confirmation card appeared: what it asks for and the keys that decide
    /// it, or, while the panel does not have the keyboard (it is hidden, or Mail's
    /// reply window has the keyboard), that Orbit has to be opened first: the
    /// keys would reach the app in front.
    static func confirmation(title: String, hasKeyboard: Bool = true) -> String {
        guard hasKeyboard else {
            return String(format: String(localized: "Confirmation needed: %@. Open Orbit to run or cancel the action."),
                          title)
        }
        return String(format: String(localized: "Confirmation needed: %@. ⌘↩ runs the action, ⌘. cancels it."), title)
    }

    /// The complete answer as plain text, a long one up to
    /// `maxAnswerCharacters` (of its first `maxParsedCharacters`), then where
    /// the rest is. nil when it has no text.
    static func answer(_ markdown: String) -> String? {
        // Fewer bytes than the limit: fewer characters too, nothing to cut.
        let (source, isCut) = markdown.utf8.count <= maxParsedCharacters
            ? (markdown, false) : Truncation.cut(markdown, maxCharacters: maxParsedCharacters)
        let text = MarkdownPlainText.text(from: source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let cut = Truncation.cutPoint(in: text, maxCharacters: maxAnswerCharacters)
        guard cut != nil || isCut else { return text }
        let start = (cut.map { text[..<$0.index] } ?? text[...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return start + " … " + String(localized: "The full answer is in the chat.")
    }
}

/// Markdown as plain text, as the answer view shows it without its markup:
/// for VoiceOver, which reads the text of an answer when it is complete.
enum MarkdownPlainText {
    static func text(from markdown: String) -> String {
        lines(of: MarkdownParser.parse(markdown)).joined(separator: "\n")
    }

    private static func lines(of blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let text), .heading(_, let text):
                return [inline(text)]
            case .list(let list):
                return list.items.enumerated().flatMap { index, item -> [String] in
                    var itemLines = lines(of: item.blocks)
                    guard !itemLines.isEmpty else { return [] }
                    if let isChecked = item.isChecked {
                        itemLines[0] = (isChecked ? String(localized: "Completed") : String(localized: "Not completed")) + ": " + itemLines[0]
                    } else if list.isOrdered {
                        itemLines[0] = "\(list.start + index). " + itemLines[0]
                    }
                    return itemLines
                }
            case .codeBlock(_, let code, _):
                return [code]
            case .blockQuote(let inner):
                return lines(of: inner)
            case .thematicBreak:
                return []
            case .table(let table):
                return ([table.header] + table.rows).map { row in row.map(inline).joined(separator: ", ") }
            }
        }
    }

    /// Inline Markdown without its markers (emphasis, code spans, links show their text).
    static func inline(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(parsed.characters)
    }
}
