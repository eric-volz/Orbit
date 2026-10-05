import Foundation

/// A block-level Markdown element produced by `MarkdownParser`. Inline
/// formatting stays as Markdown text and is rendered by `MarkdownInline`.
enum MarkdownBlock: Hashable, Sendable {
    /// Inline Markdown. Line breaks inside the paragraph are kept as "\n".
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(MarkdownList)
    /// `isClosed` is false while a streamed fence has not been closed yet.
    case codeBlock(language: String?, code: String, isClosed: Bool)
    case blockQuote([MarkdownBlock])
    case thematicBreak
    case table(MarkdownTable)
}

struct MarkdownList: Hashable, Sendable {
    var isOrdered: Bool
    /// Number of the first item of an ordered list.
    var start: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Hashable, Sendable {
    /// Task list state ("- [ ]" / "- [x]"); nil for ordinary items.
    var isChecked: Bool?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable {
        case leading
        case center
        case trailing
    }

    /// One entry per column; nil = default (leading).
    var alignments: [Alignment?]
    var header: [String]
    /// Every row has exactly `header.count` cells.
    var rows: [[String]]
}

/// Splits Markdown into blocks: paragraphs, ATX headings, bullet and ordered
/// lists (nested by indentation, task items), fenced code blocks, block quotes,
/// thematic breaks and GFM tables.
///
/// The parser is tuned for streamed model output: it never fails, an unclosed
/// fence turns the rest of the text into code, and indentation is interpreted
/// leniently (a list marker indented by two or more spaces under an item is
/// nested, whatever the marker width). Indented code blocks, setext headings,
/// HTML blocks and link reference definitions are not supported; such lines
/// render as text.
enum MarkdownParser {
    /// Deeper quotes and lists are rendered as plain paragraphs (guards the
    /// recursion against pathological input).
    static let maximumNestingDepth = 24

    static func parse(_ text: String) -> [MarkdownBlock] {
        parseBlocks(lines(of: text), depth: 0)
    }

    // MARK: Blocks

    private static func parseBlocks(_ lines: [String], depth: Int) -> [MarkdownBlock] {
        guard depth <= maximumNestingDepth else {
            let text = lines.filter { !$0.isBlankLine }.map { $0.trimmingLeadingWhitespace() }.joined(separator: "\n")
            return text.isEmpty ? [] : [.paragraph(text)]
        }
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.isBlankLine {
                index += 1
            } else if let fence = Fence(opening: line) {
                index = parseCodeBlock(lines, from: index, fence: fence, into: &blocks)
            } else if let heading = heading(line) {
                blocks.append(heading)
                index += 1
            } else if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += 1
            } else if quoteContent(line) != nil {
                index = parseBlockQuote(lines, from: index, depth: depth, into: &blocks)
            } else if let marker = ListMarker(line) {
                index = parseList(lines, from: index, first: marker, depth: depth, into: &blocks)
            } else if let head = tableHead(lines, at: index) {
                index = parseTable(lines, from: index, head: head, into: &blocks)
            } else {
                index = parseParagraph(lines, from: index, into: &blocks)
            }
        }
        return blocks
    }

    private static func parseCodeBlock(_ lines: [String], from start: Int, fence: Fence,
                                       into blocks: inout [MarkdownBlock]) -> Int {
        var code: [String] = []
        var index = start + 1
        var isClosed = false
        while index < lines.count {
            let line = lines[index]
            index += 1
            if fence.isClosing(line) {
                isClosed = true
                break
            }
            code.append(line.droppingIndent(upTo: fence.indent))
        }
        if !isClosed {
            // Streaming: hide the trailing newline and a closing fence that is
            // still being typed ("`", "``").
            while let last = code.last, last.isBlankLine || fence.isPartialClosing(last) {
                code.removeLast()
            }
        }
        blocks.append(.codeBlock(language: fence.language, code: code.joined(separator: "\n"), isClosed: isClosed))
        return index
    }

    private static func parseBlockQuote(_ lines: [String], from start: Int, depth: Int,
                                        into blocks: inout [MarkdownBlock]) -> Int {
        var inner: [String] = []
        var index = start
        var lastWasText = false
        while index < lines.count {
            let line = lines[index]
            if let content = quoteContent(line) {
                inner.append(content)
                lastWasText = endsWithParagraphText(content)
            } else if lastWasText, !line.isBlankLine, !interruptsParagraph(line) {
                // Lazy continuation of a quoted paragraph.
                inner.append(line)
            } else {
                break
            }
            index += 1
        }
        blocks.append(.blockQuote(parseBlocks(inner, depth: depth + 1)))
        return index
    }

    private static func parseList(_ lines: [String], from start: Int, first: ListMarker, depth: Int,
                                  into blocks: inout [MarkdownBlock]) -> Int {
        var items: [MarkdownListItem] = []
        var marker = first
        var index = start
        while true {
            let (item, next) = parseListItem(lines, from: index, marker: marker, depth: depth)
            items.append(item)
            index = next

            // The list continues with a sibling marker of the same kind,
            // possibly after blank lines.
            var probe = index
            while probe < lines.count, lines[probe].isBlankLine { probe += 1 }
            guard probe < lines.count, !isThematicBreak(lines[probe]),
                  let sibling = ListMarker(lines[probe]), sibling.isOrdered == first.isOrdered else { break }
            marker = sibling
            index = probe
        }
        blocks.append(.list(MarkdownList(isOrdered: first.isOrdered, start: first.number, items: items)))
        return index
    }

    /// Collects the lines of one list item (dedented to its content column)
    /// and parses them recursively.
    private static func parseListItem(_ lines: [String], from start: Int, marker: ListMarker,
                                      depth: Int) -> (MarkdownListItem, next: Int) {
        var itemLines = [marker.content]
        var openFence = Fence(opening: marker.content)
        var lastWasText = openFence == nil && endsWithParagraphText(marker.content)
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if let fence = openFence {
                // Inside a fenced code block: everything up to the closing fence
                // belongs to the item, however it is indented.
                let dedented = line.droppingIndent(upTo: marker.contentOffset)
                itemLines.append(dedented)
                if fence.isClosing(dedented) { openFence = nil }
                index += 1
                continue
            }
            if line.isBlankLine {
                // A blank line continues the item only if more item content follows.
                var probe = index + 1
                while probe < lines.count, lines[probe].isBlankLine { probe += 1 }
                guard probe < lines.count, belongs(lines[probe], to: marker) else { break }
                itemLines.append("")
                lastWasText = false
                index += 1
                continue
            }
            if belongs(line, to: marker) {
                let dedented = line.droppingIndent(upTo: marker.contentOffset)
                itemLines.append(dedented)
                openFence = Fence(opening: dedented)
                lastWasText = openFence == nil && endsWithParagraphText(dedented)
                index += 1
                continue
            }
            if lastWasText, ListMarker(line) == nil, !interruptsParagraph(line) {
                // Lazy continuation of the item's paragraph.
                itemLines.append(line.trimmingLeadingWhitespace())
                index += 1
                continue
            }
            break
        }

        var isChecked: Bool?
        if let (checked, rest) = taskMarker(itemLines[0]) {
            isChecked = checked
            itemLines[0] = rest
        }
        return (MarkdownListItem(isChecked: isChecked, blocks: parseBlocks(itemLines, depth: depth + 1)), index)
    }

    /// Whether a non-blank line belongs to the list item started by `marker`:
    /// indented to the item's content, or a list marker indented at least two
    /// spaces deeper than the item's marker (a nested list).
    private static func belongs(_ line: String, to marker: ListMarker) -> Bool {
        let indent = line.leadingSpaceCount
        if indent >= marker.contentOffset { return true }
        return indent >= marker.indent + 2 && ListMarker(line) != nil
    }

    private static func taskMarker(_ text: String) -> (Bool, String)? {
        let characters = Array(text)
        guard characters.count >= 3, characters[0] == "[", characters[2] == "]" else { return nil }
        let checked: Bool
        switch characters[1] {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        guard characters.count == 3 || characters[3] == " " else { return nil }
        return (checked, String(characters.dropFirst(characters.count == 3 ? 3 : 4)))
    }

    private static func parseParagraph(_ lines: [String], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var textLines = [lines[start]]
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.isBlankLine || interruptsParagraph(line) || tableHead(lines, at: index) != nil { break }
            textLines.append(line)
            index += 1
        }
        let text = textLines.map { line -> String in
            var trimmed = line.trimmingLeadingWhitespace().trimmingTrailingWhitespace()
            // A trailing backslash marks a hard line break; lines are kept anyway.
            if trimmed.hasSuffix("\\"), !trimmed.hasSuffix("\\\\") { trimmed.removeLast() }
            return trimmed
        }.joined(separator: "\n")
        blocks.append(.paragraph(text))
        return index
    }

    // MARK: Tables

    private struct TableHead {
        var header: [String]
        var alignments: [MarkdownTable.Alignment?]
    }

    /// A header row followed by a delimiter row ("| a | b |" + "|---|:-:|").
    private static func tableHead(_ lines: [String], at index: Int) -> TableHead? {
        guard index + 1 < lines.count, lines[index].contains("|"), lines[index + 1].contains("|"),
              let alignments = delimiterRow(lines[index + 1]) else { return nil }
        let header = tableCells(lines[index])
        guard !header.isEmpty else { return nil }
        return TableHead(header: header, alignments: alignments)
    }

    private static func parseTable(_ lines: [String], from start: Int, head: TableHead,
                                   into blocks: inout [MarkdownBlock]) -> Int {
        let columns = head.header.count
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            guard !line.isBlankLine, line.contains("|"), !interruptsParagraph(line) else { break }
            rows.append(normalized(tableCells(line), count: columns))
            index += 1
        }
        let alignments = (0..<columns).map { column in
            column < head.alignments.count ? head.alignments[column] : nil
        }
        blocks.append(.table(MarkdownTable(alignments: alignments, header: head.header, rows: rows)))
        return index
    }

    private static func normalized(_ cells: [String], count: Int) -> [String] {
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private static func delimiterRow(_ line: String) -> [MarkdownTable.Alignment?]? {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment?] = []
        for cell in cells {
            let leftColon = cell.hasPrefix(":")
            let rightColon = cell.count > 1 && cell.hasSuffix(":")
            let dashes = cell.dropFirst(leftColon ? 1 : 0).dropLast(rightColon ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leftColon, rightColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            case (true, false): alignments.append(.leading)
            case (false, false): alignments.append(nil)
            }
        }
        return alignments
    }

    /// Splits a table row at unescaped pipes outside code spans.
    static func tableCells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        let codeRanges = codeSpanRanges(in: characters)
        var cells: [String] = []
        var current = ""
        var index = 0
        var sawPipe = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if character == "|", !codeRanges.contains(where: { $0.contains(index) }) {
                if sawPipe || index > 0 { cells.append(current) }
                current = ""
                sawPipe = true
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        // A trailing pipe closes the row; text after the last pipe is a cell.
        if !current.trimmingCharacters(in: .whitespaces).isEmpty || characters.last != "|" {
            cells.append(current)
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Ranges of backtick code spans (a run of n backticks closed by the next
    /// run of exactly n backticks).
    static func codeSpanRanges(in characters: [Character]) -> [ClosedRange<Int>] {
        var runs: [(start: Int, length: Int)] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                runs.append((start, index - start))
            } else {
                index += 1
            }
        }
        var ranges: [ClosedRange<Int>] = []
        var runIndex = 0
        while runIndex < runs.count {
            let opening = runs[runIndex]
            if let closingIndex = runs[(runIndex + 1)...].firstIndex(where: { $0.length == opening.length }) {
                let closing = runs[closingIndex]
                ranges.append(opening.start...(closing.start + closing.length - 1))
                runIndex = closingIndex + 1
            } else {
                runIndex += 1
            }
        }
        return ranges
    }

    // MARK: Line classification

    /// Lines of the text with CR/CRLF normalized and leading tabs expanded to
    /// four-column stops.
    private static func lines(of text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { expandingLeadingTabs(String($0)) }
    }

    private static func expandingLeadingTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { return line }
        var column = 0
        var prefixLength = 0
        for character in line {
            if character == " " {
                column += 1
            } else if character == "\t" {
                column += 4 - column % 4
            } else {
                break
            }
            prefixLength += 1
        }
        return String(repeating: " ", count: column) + line.dropFirst(prefixLength)
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let rest = line.trimmingLeadingBlanks
        guard rest.first == "#" else { return nil }
        let level = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let afterHashes = rest.dropFirst(level)
        guard afterHashes.isEmpty || afterHashes.first == " " else { return nil }
        var text = afterHashes.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##".
        if let closing = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, text: text)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.leadingSpaceCount <= 3,
              let first = line.first(where: { !$0.isWhitespace }), first == "-" || first == "*" || first == "_" else {
            return false
        }
        var count = 0
        for character in line where !character.isWhitespace {
            guard character == first else { return false }
            count += 1
        }
        return count >= 3
    }

    private static func quoteContent(_ line: String) -> String? {
        let rest = line.trimmingLeadingBlanks
        guard rest.first == ">" else { return nil }
        let content = rest.dropFirst()
        return String(content.first == " " ? content.dropFirst() : content)
    }

    /// Lines that end a paragraph without a blank line (CommonMark rules:
    /// ordered lists interrupt only when they start with 1, and empty items
    /// never interrupt).
    private static func interruptsParagraph(_ line: String) -> Bool {
        if Fence(opening: line) != nil || heading(line) != nil || isThematicBreak(line) || quoteContent(line) != nil {
            return true
        }
        if let marker = ListMarker(line), !marker.content.isBlankLine {
            return !marker.isOrdered || marker.number == 1
        }
        return false
    }

    /// Whether a line ends with paragraph text that a following line could
    /// lazily continue.
    private static func endsWithParagraphText(_ line: String) -> Bool {
        var current = line
        // Iterative (and bounded) so deeply nested markers cannot exhaust the stack.
        for _ in 0...maximumNestingDepth {
            if current.isBlankLine || Fence(opening: current) != nil || heading(current) != nil || isThematicBreak(current) {
                return false
            }
            if let marker = ListMarker(current) {
                current = marker.content
            } else if let content = quoteContent(current) {
                current = content
            } else {
                return true
            }
        }
        return true
    }
}

// MARK: - Line elements

/// An opening code fence (``` or ~~~, at least three).
private struct Fence {
    let character: Character
    let length: Int
    let indent: Int
    let language: String?

    init?(opening line: String) {
        let indent = line.leadingSpaceCount
        let rest = line.droppingLeadingSpaces(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // An info string of a backtick fence cannot contain backticks
        // ("```code```" on one line is inline code).
        if character == "`", info.contains("`") { return nil }
        self.character = character
        self.length = length
        self.indent = indent
        let word = info.split(separator: " ").first.map(String.init)
        self.language = word.flatMap { $0.isEmpty ? nil : $0 }
    }

    func isClosing(_ line: String) -> Bool {
        let rest = line.trimmingLeadingBlanks
        let run = rest.prefix(while: { $0 == character }).count
        return run >= length && rest.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    /// A closing fence that is still being streamed ("`" or "``").
    func isPartialClosing(_ line: String) -> Bool {
        let rest = line.trimmingCharacters(in: .whitespaces)
        return !rest.isEmpty && rest.count < length && rest.allSatisfy { $0 == character }
    }
}

/// A list item marker: "-", "*", "+", or "1." / "1)" followed by a space or
/// the end of the line.
private struct ListMarker {
    let indent: Int
    let isOrdered: Bool
    /// The number of an ordered item (1 for bullets).
    let number: Int
    /// Column where the item's content starts.
    let contentOffset: Int
    /// The rest of the first line.
    let content: String

    init?(_ line: String) {
        let indent = line.leadingSpaceCount
        let rest = line.droppingLeadingSpaces(indent)
        guard let first = rest.first else { return nil }
        let markerWidth: Int
        if first == "-" || first == "*" || first == "+" {
            isOrdered = false
            number = 1
            markerWidth = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count <= 9, let value = Int(digits) else { return nil }
            let delimiter = rest.dropFirst(digits.count).first
            guard delimiter == "." || delimiter == ")" else { return nil }
            isOrdered = true
            number = value
            markerWidth = digits.count + 1
        } else {
            return nil
        }
        let afterMarker = rest.dropFirst(markerWidth)
        if afterMarker.isEmpty {
            contentOffset = indent + markerWidth + 1
            content = ""
        } else {
            guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
            let spaces = afterMarker.prefix(while: { $0 == " " || $0 == "\t" }).count
            let padding = spaces > 4 ? 1 : spaces
            contentOffset = indent + markerWidth + padding
            content = String(afterMarker.dropFirst(padding))
        }
        self.indent = indent
    }
}

// MARK: - String helpers

private extension String {
    var isBlankLine: Bool {
        for byte in utf8 where byte != 0x20 && byte != 0x09 {
            // ASCII decides quickly; other scripts (e.g. no-break spaces) need Character.
            return byte < 0x80 ? false : allSatisfy(\.isWhitespace)
        }
        return true
    }

    /// Leading spaces (tabs are expanded before parsing). Scans UTF-8 for speed.
    var leadingSpaceCount: Int {
        var count = 0
        for byte in utf8 {
            guard byte == 0x20 else { break }
            count += 1
        }
        return count
    }

    /// The line without its first `count` characters, which must be spaces.
    func droppingLeadingSpaces(_ count: Int) -> Substring {
        self[utf8.index(startIndex, offsetBy: count)...]
    }

    func droppingIndent(upTo count: Int) -> String {
        String(droppingLeadingSpaces(Swift.min(leadingSpaceCount, count)))
    }

    /// The line without leading spaces and tabs. Scans UTF-8 for speed.
    var trimmingLeadingBlanks: Substring {
        var index = utf8.startIndex
        while index != utf8.endIndex, utf8[index] == 0x20 || utf8[index] == 0x09 {
            index = utf8.index(after: index)
        }
        return self[index...]
    }

    func trimmingLeadingWhitespace() -> String {
        String(trimmingLeadingBlanks)
    }

    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }
}

/// Presentation tweaks for answers that are still streaming in.
enum MarkdownStreaming {
    /// Closes inline markers the model opened on the last line but has not
    /// closed yet ("**Cmd+B" → "**Cmd+B**"), so a partial answer renders
    /// without stray asterisks or backticks. A marker with nothing after it
    /// is dropped instead. Text inside an open code fence is left alone. Only
    /// used for display while streaming; the stored answer is never changed.
    static func closingOpenInlineMarkers(_ text: String) -> String {
        guard !isInsideOpenFence(text) else { return text }
        let lastLineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let head = text[..<lastLineStart]
        var line = String(text[lastLineStart...])
        while line.last == " " || line.last == "\t" { line.removeLast() }

        // An unclosed code span: close it and leave everything else.
        if line.filter({ $0 == "`" }).count % 2 == 1 {
            if line.hasSuffix("`") {
                line.removeLast()
                return head + line
            }
            return head + line + "`"
        }
        let outsideCode = line.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined()
        for marker in ["**", "~~"] where occurrences(of: marker, in: outsideCode) % 2 == 1 {
            if line.hasSuffix(marker) {
                line.removeLast(marker.count)
                while line.last == " " || line.last == "\t" { line.removeLast() }
            } else {
                line += marker
            }
        }
        return head + line
    }

    private static func occurrences(of marker: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: marker, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    /// Splits a streaming answer at the last blank line outside a code fence.
    /// The part before it no longer changes, so it is parsed and laid out once;
    /// only the tail is re-parsed with every delta. The tail's fences are
    /// self-contained (the split never falls inside a fence).
    static func stableSplit(_ text: String) -> (stable: String, tail: String) {
        var openFence: Character?
        var tailStart: String.Index?
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd].drop(while: { $0 == " " || $0 == "\t" })
            if let first = line.first, first == "`" || first == "~", line.prefix(while: { $0 == first }).count >= 3 {
                if let fence = openFence {
                    if fence == first { openFence = nil }
                } else {
                    openFence = first
                }
            } else if openFence == nil, line.isEmpty, lineEnd < text.endIndex {
                tailStart = text.index(after: lineEnd)
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        guard let tailStart else { return ("", text) }
        var stable = text[..<tailStart]
        while stable.last == "\n" || stable.last == " " || stable.last == "\t" { stable = stable.dropLast() }
        return (String(stable), String(text[tailStart...]))
    }

    /// Whether the text ends inside a fenced code block.
    private static func isInsideOpenFence(_ text: String) -> Bool {
        var openFence: Character?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = line.first, first == "`" || first == "~",
                  line.prefix(while: { $0 == first }).count >= 3 else { continue }
            if let fence = openFence {
                if fence == first { openFence = nil }
            } else {
                openFence = first
            }
        }
        return openFence != nil
    }
}
