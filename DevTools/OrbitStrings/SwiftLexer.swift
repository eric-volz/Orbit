import Foundation

/// A string literal found in Swift source.
struct StringLiteral: Equatable {
    /// The literal's value with escapes resolved. Interpolations are kept as
    /// written (`\(name)`), which only matters for error messages.
    var value: String
    var hasInterpolation: Bool
    /// 1-based line of the opening quote.
    var line: Int
    /// The literal's position in the source as offsets into its Unicode
    /// scalars, from the opening delimiter (incl. any `#`) to after the closing one.
    var range: Range<Int> = 0..<0
}

/// The tokens the localization scanner cares about. Comments and whitespace
/// are dropped; numbers and operators become `.other`.
enum SwiftToken: Equatable {
    case identifier(String, line: Int)
    case string(StringLiteral)
    case punctuation(Character, line: Int)
    case other(line: Int)

    var line: Int {
        switch self {
        case .identifier(_, let line), .punctuation(_, let line), .other(let line): line
        case .string(let literal): literal.line
        }
    }

    func isPunctuation(_ character: Character) -> Bool {
        if case .punctuation(let value, _) = self { return value == character }
        return false
    }
}

/// A small Swift lexer: understands line/block comments (nested), string
/// literals (single-line, multi-line, raw with any number of `#`, escapes and
/// nested interpolations), identifiers (including backticked) and punctuation.
/// Regex literals are not recognized.
struct SwiftLexer {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    /// The code inside each string interpolation, lexed (`\(String(localized: "…"))`).
    private var interpolations: [[SwiftToken]] = []

    init(_ source: String) {
        scalars = Array(source.unicodeScalars)
    }

    static func tokenize(_ source: String) -> [SwiftToken] {
        var lexer = SwiftLexer(source)
        return lexer.tokens(untilClosingParenthesis: false)
    }

    /// The top-level code followed by the code inside every string
    /// interpolation, each as its own token list.
    static func tokenizeIncludingInterpolations(_ source: String) -> [[SwiftToken]] {
        var lexer = SwiftLexer(source)
        let topLevel = lexer.tokens(untilClosingParenthesis: false)
        return [topLevel] + lexer.interpolations
    }

    // MARK: Scanning

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < scalars.count ? scalars[position] : nil
    }

    private mutating func advance() -> Unicode.Scalar? {
        guard index < scalars.count else { return nil }
        let scalar = scalars[index]
        index += 1
        if scalar == "\n" { line += 1 }
        return scalar
    }

    /// Lexes code. Inside an interpolation (`untilClosingParenthesis`) it stops
    /// after the parenthesis that closes it.
    private mutating func tokens(untilClosingParenthesis: Bool) -> [SwiftToken] {
        var tokens: [SwiftToken] = []
        var depth = 0
        while let scalar = peek() {
            switch scalar {
            case " ", "\t", "\n", "\r":
                _ = advance()
            case "/" where peek(1) == "/":
                while let next = peek(), next != "\n" { _ = advance() }
            case "/" where peek(1) == "*":
                skipBlockComment()
            case "\"":
                tokens.append(.string(stringLiteral(hashes: 0, start: index)))
            case "#" where rawStringHashes() != nil:
                let start = index
                let hashes = rawStringHashes() ?? 0
                for _ in 0..<hashes { _ = advance() }
                tokens.append(.string(stringLiteral(hashes: hashes, start: start)))
            case "`":
                let startLine = line
                _ = advance()
                var name = ""
                while let next = peek(), next != "`", next != "\n" {
                    name.unicodeScalars.append(next)
                    _ = advance()
                }
                if peek() == "`" { _ = advance() }
                tokens.append(.identifier(name, line: startLine))
            case _ where Self.isIdentifierStart(scalar):
                let startLine = line
                var name = ""
                while let next = peek(), Self.isIdentifierPart(next) {
                    name.unicodeScalars.append(next)
                    _ = advance()
                }
                tokens.append(.identifier(name, line: startLine))
            case "(":
                depth += 1
                tokens.append(.punctuation("(", line: line))
                _ = advance()
            case ")":
                if untilClosingParenthesis && depth == 0 {
                    _ = advance()
                    return tokens
                }
                depth -= 1
                tokens.append(.punctuation(")", line: line))
                _ = advance()
            case ",", ":", ".", "[", "]", "{", "}":
                tokens.append(.punctuation(Character(scalar), line: line))
                _ = advance()
            default:
                tokens.append(.other(line: line))
                _ = advance()
            }
        }
        return tokens
    }

    private mutating func skipBlockComment() {
        var depth = 0
        while let scalar = peek() {
            if scalar == "/" && peek(1) == "*" {
                depth += 1
                _ = advance(); _ = advance()
            } else if scalar == "*" && peek(1) == "/" {
                depth -= 1
                _ = advance(); _ = advance()
                if depth == 0 { return }
            } else {
                _ = advance()
            }
        }
    }

    /// The number of `#` before a quote at the current position (raw string), or nil.
    private func rawStringHashes() -> Int? {
        var count = 0
        while peek(count) == "#" { count += 1 }
        return count > 0 && peek(count) == "\"" ? count : nil
    }

    /// Lexes a string literal starting at the opening quote (after any `#`);
    /// `start` is the offset of its first delimiter character.
    private mutating func stringLiteral(hashes: Int, start: Int) -> StringLiteral {
        let startLine = line
        let isMultiline = peek() == "\"" && peek(1) == "\"" && peek(2) == "\""
        for _ in 0..<(isMultiline ? 3 : 1) { _ = advance() }
        var value = ""
        var hasInterpolation = false

        func closingDelimiterFollows() -> Bool {
            if isMultiline {
                guard peek() == "\"", peek(1) == "\"", peek(2) == "\"" else { return false }
                return (0..<hashes).allSatisfy { peek(3 + $0) == "#" }
            }
            guard peek() == "\"" else { return false }
            return (0..<hashes).allSatisfy { peek(1 + $0) == "#" }
        }

        while let scalar = peek() {
            if closingDelimiterFollows() {
                for _ in 0..<((isMultiline ? 3 : 1) + hashes) { _ = advance() }
                break
            }
            if !isMultiline && scalar == "\n" {
                break // unterminated
            }
            if scalar == "\\" && (0..<hashes).allSatisfy({ peek(1 + $0) == "#" }) {
                // An escape (in raw strings: backslash followed by the same number of #).
                _ = advance()
                for _ in 0..<hashes { _ = advance() }
                guard let escaped = advance() else { break }
                switch escaped {
                case "n": value += "\n"
                case "t": value += "\t"
                case "r": value += "\r"
                case "0": value += "\0"
                case "\\": value += "\\"
                case "\"": value += "\""
                case "'": value += "'"
                case "u":
                    value.unicodeScalars.append(unicodeEscape())
                case "(":
                    hasInterpolation = true
                    let start = index
                    interpolations.append(tokens(untilClosingParenthesis: true))
                    value += "\\(" + String(String.UnicodeScalarView(scalars[start..<index]))
                case "\n" where isMultiline:
                    // Line continuation: the newline is not part of the value.
                    while let next = peek(), next == " " || next == "\t" { _ = advance() }
                default:
                    value.unicodeScalars.append(escaped)
                }
                continue
            }
            value.unicodeScalars.append(scalar)
            _ = advance()
        }
        if isMultiline {
            value = Self.normalizeMultiline(value)
        }
        return StringLiteral(value: value, hasInterpolation: hasInterpolation, line: startLine, range: start..<index)
    }

    /// Parses `{XXXX}` after `\u`.
    private mutating func unicodeEscape() -> Unicode.Scalar {
        guard peek() == "{" else { return "u" }
        _ = advance()
        var hex = ""
        while let next = peek(), next != "}" {
            hex.unicodeScalars.append(next)
            _ = advance()
        }
        _ = advance()
        return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}"
    }

    /// Applies Swift's multi-line rules: drop the first newline and the line of
    /// the closing delimiter, and strip that line's indentation from every line.
    static func normalizeMultiline(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.count >= 2 else { return content }
        lines.removeFirst()
        let closingIndentation = lines.removeLast()
        guard closingIndentation.allSatisfy({ $0 == " " || $0 == "\t" }) else {
            return lines.joined(separator: "\n")
        }
        return lines.map { line in
            line.hasPrefix(closingIndentation) ? String(line.dropFirst(closingIndentation.count)) : line
        }.joined(separator: "\n")
    }

    static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || scalar.properties.isAlphabetic
    }

    static func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || ("0"..."9").contains(scalar) || scalar.properties.generalCategory == .decimalNumber
    }
}
