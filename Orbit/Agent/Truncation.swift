import Foundation

/// Size limits for content sent to the model, and helpers that shorten text and
/// lists while telling the model (in English) what was left out.
///
/// Tools truncate their own results with the specific limits; the agent loop
/// applies `capToolResult` to every result as a last safety net.
enum Truncation {
    /// Global cap for a single tool result: room for the largest file excerpt
    /// (`maxFileContentCharacters`) plus its header and notes.
    static let maxToolResultCharacters = 45_000
    /// File contents (`read_file`), by default.
    static let fileContentCharacters = 20_000
    /// File contents (`read_file`) when the model asks for more.
    static let maxFileContentCharacters = 40_000
    /// A mail body (`read_mail`).
    static let mailBodyCharacters = 4_000
    /// The text of a note (`read_note`).
    static let noteContentCharacters = 20_000
    /// Hits returned by search and list tools.
    static let maxListItems = 20
    /// Unicode scalars a limit in characters allows per character. A character
    /// (grapheme cluster) can be made of any number of scalars (a letter with
    /// thousands of combining marks is one character), so the characters alone
    /// would not bound the size of what the model gets. Ten covers every emoji
    /// sequence (a kiss with two skin tones has ten).
    static let maxScalarsPerCharacter = 10
    /// Combining marks kept in a row. Real text has a few at most (Vietnamese,
    /// Hebrew points, Devanagari, Tibetan stacks); "Zalgo" text piles up
    /// thousands on one letter.
    static let maxCombiningMarksInARow = 8

    /// Shortens `text` to at most `maxCharacters` characters (grapheme clusters)
    /// (and `maxScalarsPerCharacter` times as many Unicode scalars) and appends
    /// a note such as `[Truncated: showing the first 20000 of 58123 characters.]`.
    /// Runs of combining marks are shortened (`collapsingCombiningMarks`).
    ///
    /// The cut prefers a line break, then whitespace, within the last ~10% before
    /// the limit, so words and lines stay intact where possible.
    static func truncate(_ text: String, maxCharacters: Int) -> (text: String, wasTruncated: Bool) {
        let (kept, wasTruncated) = cut(text, maxCharacters: maxCharacters)
        guard wasTruncated else { return (kept, false) }
        let note = "[Truncated: showing the first \(kept.count) of \(text.count) characters.]"
        return (kept.isEmpty ? note : "\(kept)\n\n\(note)", true)
    }

    /// The part of `text` that `truncate` keeps, without the note, for callers
    /// that place the note themselves (e.g. after a closing tag).
    static func cut(_ text: String, maxCharacters: Int) -> (text: String, wasTruncated: Bool) {
        let limit = max(0, maxCharacters)
        guard let end = cutPoint(in: text, maxCharacters: limit) else {
            return (collapsingCombiningMarks(text), false)
        }

        // `end.index` is a valid character, so the window may include it: a line
        // break right at the limit is the best possible cut.
        let windowStart = text.index(end.index, offsetBy: -(end.characters / 10))
        let window = text[windowStart...end.index]
        let cut = window.lastIndex(where: \.isNewline)
            ?? window.lastIndex(where: \.isWhitespace)
            ?? end.index

        var kept = text[..<cut]
        while let last = kept.last, last.isWhitespace {
            kept = kept.dropLast()
        }
        return (collapsingCombiningMarks(String(kept)), true)
    }

    /// At most `maxCharacters` characters of `text` (and `maxScalarsPerCharacter`
    /// times as many Unicode scalars), cut hard, with runs of combining marks
    /// shortened.
    static func prefix(_ text: String, maxCharacters: Int) -> String {
        guard let end = cutPoint(in: text, maxCharacters: max(0, maxCharacters)) else {
            return collapsingCombiningMarks(text)
        }
        return collapsingCombiningMarks(String(text[..<end.index]))
    }

    /// Where `text` is cut to `maxCharacters` characters and `maxCharacters ×
    /// maxScalarsPerCharacter` Unicode scalars, counted as they are kept, i.e.
    /// at most `maxCombiningMarksInARow` marks in a row: the start of the first
    /// character left out and the number of characters before it; nil when
    /// nothing is left out. Looks at no more of the text than it keeps, so a
    /// long text costs no more than a short one.
    static func cutPoint(in text: String, maxCharacters: Int) -> (index: String.Index, characters: Int)? {
        let (product, overflow) = maxCharacters.multipliedReportingOverflow(by: maxScalarsPerCharacter)
        let maxScalars = overflow ? Int.max : product
        var index = text.startIndex
        var characters = 0
        var scalars = 0
        var marksInARow = 0
        while index < text.endIndex {
            guard characters < maxCharacters else { return (index, characters) }
            let next = text.index(after: index)
            for scalar in text.unicodeScalars[index..<next] {
                if isCombiningMark(scalar) {
                    marksInARow += 1
                    if marksInARow > maxCombiningMarksInARow { continue }
                } else {
                    marksInARow = 0
                }
                scalars += 1
            }
            guard scalars <= maxScalars else { return (index, characters) }
            characters += 1
            index = next
        }
        return nil
    }

    /// `text` with every run of more than `maxCombiningMarksInARow` combining
    /// marks shortened to that many; text without such a run comes back as it is.
    static func collapsingCombiningMarks(_ text: String) -> String {
        var marksInARow = 0
        var isTooLong = false
        for scalar in text.unicodeScalars {
            marksInARow = isCombiningMark(scalar) ? marksInARow + 1 : 0
            if marksInARow > maxCombiningMarksInARow {
                isTooLong = true
                break
            }
        }
        guard isTooLong else { return text }
        var result = String.UnicodeScalarView()
        marksInARow = 0
        for scalar in text.unicodeScalars {
            marksInARow = isCombiningMark(scalar) ? marksInARow + 1 : 0
            if marksInARow <= maxCombiningMarksInARow { result.append(scalar) }
        }
        return String(result)
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// Keeps the first `maxCount` items and reports how many were dropped.
    static func limit<Element>(_ items: [Element], max maxCount: Int) -> (items: [Element], omittedCount: Int) {
        let count = Swift.max(0, maxCount)
        guard items.count > count else { return (items, 0) }
        return (Array(items.prefix(count)), items.count - count)
    }

    /// Note for the model after a shortened list, e.g.
    /// `[Showing 20 of 57 results. Narrow the search (time range, sender, folder) to see others.]`.
    static func listNote(shown: Int, total: Int,
                         hint: String = "Narrow the search (time range, sender, folder) to see others.") -> String {
        "[Showing \(shown) of \(total) results. \(hint)]"
    }

    /// Applies the global cap (`maxToolResultCharacters`) to a tool result.
    static func capToolResult(_ text: String) -> String {
        truncate(text, maxCharacters: maxToolResultCharacters).text
    }
}
