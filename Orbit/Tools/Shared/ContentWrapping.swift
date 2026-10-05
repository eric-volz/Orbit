import Foundation

/// Untrusted content for the model (a file's text, a note, a mail) wrapped
/// in its own element (`<note_content>` … `</note_content>`), so the model
/// can tell it apart from instructions. Occurrences of the element's tag
/// inside the content are neutralized, so the content cannot close it.
enum ContentWrapping {
    /// Makes `<tag` and `</tag` inside untrusted content harmless, also when
    /// disguised with spaces, invisible characters, full-width or small
    /// brackets, or another case: the bracket before the tag name becomes ‹.
    /// Everything else (code, HTML, XML) stays as it is.
    static func neutralizing(_ text: String, tag: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let openers: Set<Unicode.Scalar> = ["<", "\u{FF1C}", "\u{FE64}", "\u{2329}", "\u{3008}"]
        let slashes: Set<Unicode.Scalar> = ["/", "\u{FF0F}", "\u{2215}", "\u{2044}"]
        let tagScalars = Array(tag.lowercased().unicodeScalars)
        guard !tagScalars.isEmpty else { return text }
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)

        func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.isWhitespace || scalar.properties.generalCategory == .format
        }

        for (index, scalar) in scalars.enumerated() {
            guard openers.contains(scalar) else {
                result.append(scalar)
                continue
            }
            var position = index + 1
            while position < scalars.count, isIgnorable(scalars[position]) { position += 1 }
            if position < scalars.count, slashes.contains(scalars[position]) { position += 1 }
            var matched = 0
            while position < scalars.count, matched < tagScalars.count {
                let candidate = scalars[position]
                if isIgnorable(candidate) {
                    position += 1
                    continue
                }
                guard String(candidate).lowercased() == String(tagScalars[matched]) else { break }
                matched += 1
                position += 1
            }
            result.append(matched == tagScalars.count ? "‹" : scalar)
        }
        return String(result)
    }

    /// `<tag>` + the neutralized content + `</tag>`, each on its own line.
    static func wrapped(_ text: String, tag: String) -> String {
        "<\(tag)>\n\(neutralizing(text, tag: tag))\n</\(tag)>"
    }
}
