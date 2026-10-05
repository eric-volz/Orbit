import Foundation

/// Model-facing text of the file tools (English, not localized). Names and
/// paths from the disk are untrusted: every value is made single-line and
/// neutralized (`TurnContext.inline`), and file contents are wrapped so they
/// cannot close their element.
enum FileToolFormat {
    /// The element read_file wraps contents in.
    static let contentTag = "file_content"

    /// "2026-08-15 12:00" in `timeZone`.
    static func date(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// "512 bytes", "17 KB", "3.4 MB" (decimal units, like Finder).
    static func size(_ bytes: Int64) -> String {
        if bytes < 1_000 { return bytes == 1 ? "1 byte" : "\(max(0, bytes)) bytes" }
        let units: [(String, Double)] = [("KB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12)]
        var (unit, divisor) = units[0]
        for candidate in units where Double(bytes) >= candidate.1 {
            (unit, divisor) = candidate
        }
        let value = Double(bytes) / divisor
        var number = value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        if number.hasSuffix(".0") { number.removeLast(2) }
        return "\(number) \(unit)"
    }

    /// A single-line, neutralized value (names, paths, query text).
    static func inline(_ value: String, maxCharacters: Int = TurnContext.maxInlineCharacters) -> String {
        TurnContext.inline(value, maxCharacters: maxCharacters)
    }

    /// One name (a path component) as a row shows it: single-line and
    /// neutralized like `inline`, without surrounding whitespace, so a path
    /// copied from a row can be matched back to the item
    /// (`FileToolContext.itemShown(as:purpose:)`).
    static func shownName(_ name: String) -> String {
        TurnContext.neutralizeMarkup(name.split(whereSeparator: \.isNewline).joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
    }

    /// One numbered list row: "1. name | ~/path | kind | modified … | size".
    static func row(_ number: Int, item: SpotlightItem, home: String, timeZone: TimeZone,
                    includeLastUsed: Bool = false) -> String {
        var parts = [
            inline(item.fileSystemName),
            inline(FilePath.abbreviate(item.path, home: home), maxCharacters: 1_000),
            FileKind.label(contentType: item.contentType, contentTypeTree: item.contentTypeTree),
        ]
        if includeLastUsed, let lastUsed = item.lastUsed {
            parts.append("last used \(date(lastUsed, timeZone: timeZone))")
        }
        if let modified = item.modified {
            parts.append("modified \(date(modified, timeZone: timeZone))")
        }
        if let bytes = item.size, !item.isFolder {
            parts.append(size(bytes))
        }
        return "\(number). " + parts.joined(separator: " | ")
    }

    /// The card row for a Spotlight item, with its folder as Finder names it
    /// (reads the disk: tools run off the main actor).
    static func fileItem(_ item: SpotlightItem, folderNames: FolderNames) -> FileItem {
        FileItem(path: item.path, name: item.displayName.isEmpty ? item.fileSystemName : item.displayName,
                 kindDescription: item.kindDescription, contentType: item.contentType, modified: item.modified,
                 size: item.isFolder ? nil : item.size, isDirectory: item.isFolder,
                 folderNames: folderNames.names(ofFolderContaining: item.path))
    }

    // MARK: Wrapped contents

    /// Makes `<file_content` and `</file_content` inside untrusted content
    /// harmless (see `ContentWrapping.neutralizing(_:tag:)`).
    static func neutralizingContentTags(_ text: String) -> String {
        ContentWrapping.neutralizing(text, tag: contentTag)
    }

    /// Contents as data: `<file_content>` … `</file_content>`.
    static func wrappedContent(_ text: String) -> String {
        ContentWrapping.wrapped(text, tag: contentTag)
    }
}
