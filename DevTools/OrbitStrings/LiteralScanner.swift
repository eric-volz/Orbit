import Foundation

/// A localizable string literal found in a Swift source file.
struct LocalizableLiteral: Equatable {
    var key: String
    var comment: String?
    /// `String(localized:defaultValue:)`: the source-language text for `key`.
    var defaultValue: String?
    var hasInterpolation: Bool
    var file: String
    var line: Int
    /// The call the literal was passed to, e.g. `Text`, `.help`, `String(localized:)`.
    var call: String
    /// Where the key's literal is in the source (see `StringLiteral.range`).
    var range: Range<Int>? = nil
}

/// Finds the string literals SwiftUI and Foundation localize: the first
/// argument of `Text("…")`, `Button("…")`, `.help("…")` and friends, and
/// `String(localized: "…")`. `Text(verbatim:)` and non-literal arguments are
/// ignored, as are literals inside comments.
enum LiteralScanner {
    /// SwiftUI/AppKit initializers whose first unlabeled argument is localized.
    static let initializers: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "TextField", "SecureField", "Section", "Menu",
        "LabeledContent", "LocalizedStringKey", "LocalizedStringResource", "Link", "GroupBox", "DisclosureGroup",
        "Stepper", "ProgressView", "ContentUnavailableView", "ControlGroup", "Tab", "CommandMenu", "Window",
        "WindowGroup", "MenuBarExtra", "NavigationLink", "ShareLink", "DatePicker", "MultiDatePicker",
        "ColorPicker", "TableColumn", "Recorder", "NSLocalizedString",
    ]

    /// View modifiers whose first unlabeled argument is localized.
    static let modifiers: Set<String> = [
        "help", "navigationTitle", "navigationSubtitle", "accessibilityLabel", "accessibilityHint",
        "accessibilityValue", "accessibilityCustomContent", "confirmationDialog", "alert", "badge",
    ]

    /// Modifiers whose localized argument is labeled.
    static let labeledModifiers: [String: String] = [
        "searchable": "prompt",
        "accessibilityAction": "named",
    ]

    /// Module qualifiers allowed before an initializer (`SwiftUI.Text("…")`).
    static let qualifiers: Set<String> = ["SwiftUI", "KeyboardShortcuts"]

    static func scan(source: String, file: String) -> [LocalizableLiteral] {
        SwiftLexer.tokenizeIncludingInterpolations(source).flatMap { scan(tokens: $0, file: file) }
    }

    /// Scans one token list (top-level code or the code of one interpolation).
    private static func scan(tokens: [SwiftToken], file: String) -> [LocalizableLiteral] {
        var results: [LocalizableLiteral] = []
        for index in tokens.indices {
            guard case .identifier(let name, _) = tokens[index],
                  index + 1 < tokens.count, tokens[index + 1].isPunctuation("(") else { continue }
            let isMember = index > 0 && tokens[index - 1].isPunctuation(".")
            let arguments = Self.arguments(in: tokens, openingParenthesis: index + 1)

            let literal: StringLiteral?
            let call: String
            if name == "String", !isMember {
                // String(localized: "…", defaultValue: "…", table: "…", comment: "…")
                guard let first = arguments.first, first.label == "localized", let value = first.literal else { continue }
                literal = value
                call = "String(localized:)"
            } else if initializers.contains(name) {
                if isMember {
                    guard index >= 2, case .identifier(let qualifier, _) = tokens[index - 2], qualifiers.contains(qualifier) else {
                        continue
                    }
                }
                guard let first = arguments.first, first.label == nil else { continue }
                literal = first.literal
                call = name
            } else if isMember, modifiers.contains(name) {
                guard let first = arguments.first, first.label == nil else { continue }
                literal = first.literal
                call = "." + name
            } else if isMember, let label = labeledModifiers[name] {
                literal = arguments.first(where: { $0.label == label })?.literal
                call = ".\(name)(\(label):)"
            } else {
                continue
            }
            guard let literal, !literal.value.isEmpty else { continue }
            if let table = arguments.first(where: { $0.label == "tableName" || $0.label == "table" })?.literal?.value,
               table != "Localizable" {
                continue
            }
            results.append(LocalizableLiteral(
                key: literal.value,
                comment: arguments.first(where: { $0.label == "comment" })?.literal?.value,
                defaultValue: arguments.first(where: { $0.label == "defaultValue" })?.literal?.value,
                hasInterpolation: literal.hasInterpolation,
                file: file,
                line: literal.line,
                call: call,
                range: literal.range
            ))
        }
        return results
    }

    /// One top-level argument of a call.
    struct Argument {
        var label: String?
        var tokens: ArraySlice<SwiftToken>

        /// The argument's value when it is exactly one string literal.
        var literal: StringLiteral? {
            guard tokens.count == 1, case .string(let literal) = tokens.first else { return nil }
            return literal
        }
    }

    /// Splits the argument list that starts at `openingParenthesis`.
    static func arguments(in tokens: [SwiftToken], openingParenthesis: Int) -> [Argument] {
        var arguments: [Argument] = []
        var depth = 0
        var start = openingParenthesis + 1
        var index = openingParenthesis
        func appendArgument(until end: Int) {
            guard start < end else { return }
            var slice = tokens[start..<end]
            var label: String?
            if slice.count >= 2, case .identifier(let name, _) = slice[slice.startIndex],
               slice[slice.startIndex + 1].isPunctuation(":") {
                label = name
                slice = slice.dropFirst(2)
            }
            arguments.append(Argument(label: label, tokens: slice))
        }
        while index < tokens.count {
            switch tokens[index] {
            case .punctuation("(", _), .punctuation("[", _), .punctuation("{", _):
                depth += 1
            case .punctuation(")", _), .punctuation("]", _), .punctuation("}", _):
                depth -= 1
                if depth == 0 {
                    appendArgument(until: index)
                    return arguments
                }
            case .punctuation(",", _) where depth == 1:
                appendArgument(until: index)
                start = index + 1
            default:
                break
            }
            index += 1
        }
        return arguments
    }

    /// Scans every `.swift` file below `directory` (skipping hidden folders and `.build`).
    static func scan(directory: URL, relativeTo base: URL) throws -> [LocalizableLiteral] {
        let files = try swiftFiles(in: directory)
        var results: [LocalizableLiteral] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            results += scan(source: source, file: relativePath(of: file, to: base))
        }
        return results
    }

    static func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".build" {
                enumerator.skipDescendants()
            } else if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func relativePath(of file: URL, to base: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }
        return filePath
    }
}
