import Foundation

/// Search words from user or model text, as search_notes and search_mail take
/// them: separated by whitespace, a "quoted phrase" (also „…“ or “…”) stays one
/// term, "*" alone means no words, each term once (ignoring case). Control
/// characters are removed; a phrase that spans lines becomes one line.
enum SearchTerms {
    static func split(_ query: String) -> [String] {
        let cleaned = NoteText.cleaned(query)
        var terms: [String] = []
        var current = ""
        var inQuotes = false
        func flush() {
            let term = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty, term != "*" { terms.append(term) }
            current = ""
        }
        for character in cleaned {
            if "\"„“”".contains(character) {
                flush()
                inQuotes.toggle()
            } else if character.isWhitespace, !inQuotes {
                flush()
            } else {
                // A phrase stays on one line (scripts take one term per line).
                current.append(character.isNewline ? " " : character)
            }
        }
        flush()
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }
}
