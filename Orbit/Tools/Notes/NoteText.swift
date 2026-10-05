import Foundation

/// Converts between the HTML bodies of Apple Notes and plain text. Pure and
/// linear (no regular expressions, no WebKit), so it runs anywhere off the
/// main actor.
enum NoteText {
    /// Longest title Orbit gives a new note.
    static let maxTitleCharacters = 300
    /// Nested lists are indented up to this many levels; deeper ones keep that
    /// indent (thousands of nested lists would otherwise mean megabytes of spaces).
    static let maxListIndentLevels = 8

    // MARK: HTML → text

    /// The text of a note body the way Notes shows it: one line per paragraph
    /// (`<div>`, `<p>`, headings) and line break, empty lines where the note
    /// has them (`<div><br></div>`), list items as "- " or "1. " (nested lists
    /// indented), table rows with their cells separated by " | ", a link's
    /// address after its text when they differ, images and attachments as
    /// "[image]" and "[attachment]", entities decoded, runs of spaces and of
    /// empty lines collapsed. Comments, scripts and styles are dropped. With
    /// `maxCharacters` it stops once the text is longer than that (the caller
    /// cuts it and says so).
    static func plainText(fromHTML html: String, maxCharacters: Int? = nil) -> String {
        var builder = TextBuilder()
        var index = html.startIndex
        while index < html.endIndex {
            if let maxCharacters, builder.characters > maxCharacters { break }
            guard let open = html[index...].firstIndex(of: "<") else {
                builder.text(html[index...])
                break
            }
            if open > index { builder.text(html[index..<open]) }
            if html[open...].hasPrefix("<!--") {
                index = html.range(of: "-->", range: open..<html.endIndex)?.upperBound ?? html.endIndex
                continue
            }
            // Like browsers: "<" starts a tag only before a letter, "/", "!" or "?"; otherwise it is text.
            let next = html.index(after: open)
            guard next < html.endIndex, html[next].isLetter || "/!?".contains(html[next]) else {
                builder.text("<")
                index = next
                continue
            }
            guard let close = tagEnd(in: html, from: next) else { break }
            let tag = Tag(html[next..<close])
            index = html.index(after: close)
            if !tag.isClosing, skippedElements.contains(tag.name) {
                if let end = html.range(of: "</" + tag.name, options: .caseInsensitive, range: index..<html.endIndex) {
                    index = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                } else {
                    index = html.endIndex
                }
                continue
            }
            builder.handle(tag)
        }
        return builder.finish()
    }

    private static let skippedElements: Set<String> = ["script", "style", "noscript", "template", "svg", "head", "title"]

    /// The position of the ">" that ends the tag starting at `start` (quotes
    /// in attribute values respected), or nil for an unterminated tag.
    private static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = start
        while index < html.endIndex {
            let character = html[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    /// A start or end tag: its lowercased name and attributes.
    struct Tag {
        var name: String
        var isClosing: Bool
        private var attributes: Substring

        init(_ inner: Substring) {
            isClosing = inner.hasPrefix("/")
            let rest = inner.drop(while: { $0 == "/" })
            let name = rest.prefix(while: { $0.isLetter || $0.isNumber })
            self.name = name.lowercased()
            attributes = rest.dropFirst(name.count)
        }

        /// The value of attribute `name` (entities decoded), or nil.
        func attribute(_ name: String) -> String? {
            var rest = attributes[...]
            while let range = rest.range(of: name, options: .caseInsensitive) {
                let before = rest[..<range.lowerBound].last
                var after = rest[range.upperBound...].drop(while: { $0 == " " })
                rest = rest[range.upperBound...]
                guard before == nil || before?.isWhitespace == true, after.first == "=" else { continue }
                after = after.dropFirst().drop(while: { $0 == " " })
                let value: Substring
                if let quote = after.first, quote == "\"" || quote == "'" {
                    value = after.dropFirst().prefix(while: { $0 != quote })
                } else {
                    value = after.prefix(while: { !$0.isWhitespace && $0 != ">" && $0 != "/" })
                }
                return FileTextExtractor.decodingEntities(String(value))
            }
            return nil
        }
    }

    /// Collects lines while the HTML is scanned.
    private struct TextBuilder {
        private struct List {
            var isOrdered: Bool
            var count = 0
        }

        private var lines: [String] = []
        /// Characters of the lines so far, each with its line break (empty lines not counted).
        private(set) var characters = 0
        private var current = ""
        /// Written before the current line's first text ("- ", "  1. ").
        private var prefix = ""
        /// Prefix of further lines of the same list item (same width, spaces).
        private var continuation = ""
        private var pendingSpace = false
        private var lists: [List] = []
        private var cellDepth = 0
        private var cellsInRow = 0
        private var link: (href: String, text: String)?

        mutating func text(_ fragment: Substring) {
            let decoded = FileTextExtractor.decodingEntities(String(fragment))
            for character in decoded {
                if character.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace, !current.isEmpty, current.last != " " { append(" ") }
                pendingSpace = false
                append(String(character))
            }
        }

        mutating func handle(_ tag: Tag) {
            switch tag.name {
            case "br":
                if cellDepth > 0 { pendingSpace = true } else { lineBreak() }
            case "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "section", "article",
                 "header", "footer", "address", "figure", "figcaption", "dl", "dt", "dd", "main", "nav", "aside":
                if cellDepth > 0 { pendingSpace = true } else { breakLine() }
            case "ul", "ol":
                breakLine()
                if tag.isClosing {
                    if !lists.isEmpty { lists.removeLast() }
                } else {
                    lists.append(List(isOrdered: tag.name == "ol"))
                }
                if lists.isEmpty {
                    prefix = ""
                    continuation = ""
                }
            case "li":
                breakLine()
                if tag.isClosing {
                    prefix = ""
                    continuation = ""
                } else {
                    var marker = "- "
                    if let last = lists.indices.last, lists[last].isOrdered {
                        lists[last].count += 1
                        marker = "\(lists[last].count). "
                    }
                    let indent = String(repeating: "  ", count: min(max(0, lists.count - 1), NoteText.maxListIndentLevels))
                    prefix = indent + marker
                    continuation = indent + String(repeating: " ", count: marker.count)
                }
            case "table":
                breakLine()
                cellDepth = 0
            case "tr":
                breakLine()
                cellsInRow = 0
            case "td", "th":
                if tag.isClosing {
                    cellDepth = max(0, cellDepth - 1)
                } else {
                    if cellsInRow > 0 {
                        pendingSpace = false
                        append(" | ")
                    }
                    cellsInRow += 1
                    cellDepth += 1
                }
            case "a":
                if tag.isClosing {
                    finishLink()
                } else {
                    finishLink()
                    link = tag.attribute("href").flatMap(Self.linkAddress).map { ($0, "") }
                }
            case "img":
                if !tag.isClosing { inline("[image]") }
            case "object", "embed", "iframe", "video", "audio":
                if !tag.isClosing { inline("[attachment]") }
            case "hr":
                breakLine()
                lines.append("---")
                characters += 4
            default:
                break
            }
        }

        mutating func finish() -> String {
            finishLink()
            breakLine()
            var result: [String] = []
            for line in lines {
                if line.isEmpty, result.last?.isEmpty ?? true { continue }
                result.append(line)
            }
            while result.last?.isEmpty == true { result.removeLast() }
            return result.joined(separator: "\n")
        }

        // MARK: Helpers

        private mutating func append(_ text: String) {
            current += text
            if link != nil { link?.text += text }
        }

        private mutating func inline(_ placeholder: String) {
            if !current.isEmpty, current.last != " " { append(" ") }
            append(placeholder)
            pendingSpace = true
        }

        /// Ends the current line if it has text.
        private mutating func breakLine() {
            pendingSpace = false
            let text = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !text.isEmpty else { return }
            lines.append(prefix + text)
            characters += prefix.count + text.count + 1
            if !prefix.isEmpty { prefix = continuation }
        }

        /// `<br>`: ends the current line, or adds an empty one.
        private mutating func lineBreak() {
            if current.trimmingCharacters(in: .whitespaces).isEmpty {
                current = ""
                pendingSpace = false
                lines.append("")
            } else {
                breakLine()
            }
        }

        private mutating func finishLink() {
            guard let (href, text) = link else { return }
            link = nil
            let shown = text.trimmingCharacters(in: .whitespaces)
            let bare = href.hasPrefix("mailto:") ? String(href.dropFirst("mailto:".count)) : href
            guard !shown.isEmpty, shown != href, shown != bare else { return }
            current += " (\(bare))"
        }

        /// Web and mail addresses only (no javascript:, file: or data: links).
        private static func linkAddress(_ href: String) -> String? {
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:"),
                  trimmed.count <= 500, !trimmed.contains(where: \.isWhitespace) else { return nil }
            return trimmed
        }
    }

    // MARK: Text → HTML

    /// The HTML body for a new note: the title as its first line (a heading;
    /// Notes takes the first line as the note's name), then the text with one
    /// `<div>` per line and `<div><br></div>` for empty lines. Everything is
    /// escaped, so text like "<b>" stays text; leading spaces and tabs keep
    /// their width.
    static func html(title: String, body: String) -> String {
        var parts = ["<div><h1>\(escaped(singleLine(title)))</h1></div>"]
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    parts.append("<div><br></div>")
                } else {
                    parts.append("<div>\(escapedKeepingIndent(text))</div>")
                }
            }
        }
        return parts.joined()
    }

    /// `text` with &, <, >, " and ' escaped.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func escapedKeepingIndent(_ line: String) -> String {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return String(repeating: "&nbsp;", count: width) + escaped(String(line.dropFirst(indent.count)))
    }

    /// Text from the model or the user without control characters (except
    /// tabs and line breaks); NUL cannot be passed to a script at all.
    static func cleaned(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar == "\r" || !(scalar.value < 0x20 || scalar.value == 0x7F)
        }))
    }

    /// A title on one line, trimmed and at most `maxTitleCharacters` long.
    static func singleLine(_ title: String) -> String {
        let line = cleaned(title).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(line.prefix(maxTitleCharacters))
    }

    // MARK: Excerpts

    /// A short excerpt of a note's text for result rows and cards: without the
    /// first line when it is the title (Notes starts the text with it),
    /// whitespace collapsed, at most `maxCharacters` (cut at a word, with "…").
    /// nil when nothing is left.
    static func excerpt(from text: String, title: String, maxCharacters: Int) -> String? {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = lines.first, first == title.trimmingCharacters(in: .whitespaces) {
            lines.removeFirst()
        }
        let collapsed = lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxCharacters else { return collapsed }
        let limit = max(1, maxCharacters - 1)
        let kept = collapsed.prefix(limit)
        // A word that ends right at the limit stays whole; otherwise cut at the
        // last space unless that would drop more than 40 % of the excerpt.
        if kept.endIndex < collapsed.endIndex, collapsed[kept.endIndex] == " " {
            return kept + "…"
        }
        if let space = kept.lastIndex(of: " "), kept.distance(from: kept.startIndex, to: space) >= limit * 6 / 10 {
            return kept[..<space] + "…"
        }
        return kept + "…"
    }
}
