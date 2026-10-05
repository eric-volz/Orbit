import AppKit
import SwiftUI

/// Renders Markdown (model answers) as native SwiftUI views: selectable text,
/// clickable links, monospaced code blocks with a subtle background.
struct MarkdownView: View, Equatable {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownParser.parse(text), listDepth: 0, spacing: 10)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                MarkdownLinkPolicy.allows(url) ? .systemAction : .discarded
            })
    }
}

/// Which links in model output may be opened. Model output can contain text
/// from mails, notes or web pages, so only web and mail links are followed,
/// never file://, Shortcuts, System Settings or other app URL schemes.
enum MarkdownLinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}

/// Inline Markdown (emphasis, code spans, links) → AttributedString.
@MainActor
enum MarkdownInline {
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `fontSize` is the size of the surrounding text; code spans use a
    /// slightly smaller monospaced font so they do not look heavier than it.
    static func attributedString(from markdown: String, fontSize: CGFloat = Theme.bodySize) -> AttributedString {
        let source = escapingSingleTildes(markdown)
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(markdown)
        // Links to anything but the web or mail stay plain text, wherever the
        // text is shown (answers, progress notes, table cells, headings).
        for run in result.runs {
            if let url = run.link, !MarkdownLinkPolicy.allows(url) {
                result[run.range].link = nil
            }
        }
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].swiftUI.backgroundColor = Theme.codeFill
            result[run.range].swiftUI.font = .system(size: (fontSize * 0.9).rounded(), design: .monospaced)
        }
        linkBareURLs(in: &result)
        return result
    }

    /// GFM reads a pair of single tildes as strikethrough, which garbles paths
    /// ("~/Library/Mobile Documents/com~apple~CloudDocs") and ranges ("5~10").
    /// Here only "~~" strikes through: single tildes outside code spans are
    /// escaped.
    static func escapingSingleTildes(_ markdown: String) -> String {
        guard markdown.contains("~") else { return markdown }
        let characters = Array(markdown)
        let codeSpans = MarkdownParser.codeSpanRanges(in: characters)
        var result = ""
        result.reserveCapacity(characters.count + 8)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                // An existing escape stays as it is.
                result.append(character)
                result.append(characters[index + 1])
                index += 2
            } else if character == "~" {
                var end = index
                while end < characters.count, characters[end] == "~" { end += 1 }
                let isSingle = end - index == 1
                if isSingle, !codeSpans.contains(where: { $0.contains(index) }) {
                    result += "\\~"
                } else {
                    result += String(repeating: "~", count: end - index)
                }
                index = end
            } else {
                result.append(character)
                index += 1
            }
        }
        return result
    }

    /// Turns plain URLs and mail addresses into links (outside code spans and
    /// existing links).
    private static func linkBareURLs(in text: inout AttributedString) {
        guard let linkDetector else { return }
        let plain = String(text.characters)
        guard plain.contains(".") || plain.contains(":") else { return }
        let matches = linkDetector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let url = match.url, MarkdownLinkPolicy.allows(url),
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            let target = lower..<upper
            let isTaken = text[target].runs.contains { run in
                run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
            }
            if !isTaken {
                text[target].link = url
            }
        }
    }
}

// MARK: - Blocks

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let listDepth: Int
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, listDepth: listDepth)
                    .equatable()
            }
        }
    }
}

/// One block. Equatable so unchanged blocks are not re-rendered while the
/// answer streams in.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let listDepth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            MarkdownTextView(markdown: text, size: Theme.bodySize)
        case .heading(let level, let text):
            MarkdownTextView(markdown: text, size: Self.headingSize(level: level), weight: level == 1 ? .bold : .semibold)
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        case .list(let list):
            MarkdownListView(list: list, depth: listDepth)
        case .codeBlock(let language, let code, _):
            CodeBlockView(language: language, code: code)
        case .blockQuote(let blocks):
            MarkdownBlocksView(blocks: blocks, listDepth: listDepth, spacing: 6)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 3)
                }
        case .thematicBreak:
            Divider()
                .padding(.vertical, 2)
        case .table(let table):
            MarkdownTableView(table: table)
        }
    }

    static func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: 19
        case 2: 16.5
        case 3: 15
        default: Theme.bodySize
        }
    }
}

struct MarkdownTextView: View {
    let markdown: String
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        Text(MarkdownInline.attributedString(from: markdown, fontSize: size))
            .font(.system(size: size, weight: weight))
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lists

struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item, index: index)
                        .frame(minWidth: markerWidth, alignment: .trailing)
                    MarkdownBlocksView(blocks: item.blocks, listDepth: depth + 1, spacing: 6)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, index: Int) -> some View {
        if let isChecked = item.isChecked {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.system(size: Theme.bodySize - 1))
                .foregroundStyle(isChecked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .accessibilityLabel(isChecked ? Text("Completed") : Text("Not completed"))
        } else if list.isOrdered {
            Text(verbatim: "\(list.start + index).")
                .font(Theme.bodyFont.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: Self.bullets[depth % Self.bullets.count])
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
        }
    }

    private static let bullets = ["•", "◦", "▪︎"]

    private var markerWidth: CGFloat {
        guard list.isOrdered else { return 10 }
        let largest = list.start + max(list.items.count - 1, 0)
        return CGFloat(String(largest).count) * 8 + 5
    }
}

// MARK: - Code

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let language {
                    Text(verbatim: language)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(didCopy ? Text("Copied") : Text("Copy Code"))
                .accessibilityLabel(Text("Copy Code"))
            }
            Text(verbatim: code)
                .font(Theme.codeFont)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.codeFill))
        .contrastEdge(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

// MARK: - Tables

struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column)
                        .fontWeight(.semibold)
                        .gridColumnAlignment(horizontalAlignment(column))
                }
            }
            .padding(.vertical, 6)
            Divider()
            ForEach(table.rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(table.rows[rowIndex].indices, id: \.self) { column in
                        cell(table.rows[rowIndex][column], column: column)
                    }
                }
                .padding(.vertical, 5)
                if rowIndex < table.rows.count - 1 {
                    Divider().opacity(0.6)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(Theme.cardStrokeOpacity(increasedContrast: contrast == .increased))))
    }

    private func cell(_ markdown: String, column: Int) -> some View {
        Text(MarkdownInline.attributedString(from: markdown))
            .font(Theme.bodyFont)
            .multilineTextAlignment(textAlignment(column))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ column: Int) -> MarkdownTable.Alignment? {
        column < table.alignments.count ? table.alignments[column] : nil
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .center: .center
        case .trailing: .trailing
        case .leading, nil: .leading
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .center: .center
        case .trailing: .trailing
        case .leading, nil: .leading
        }
    }
}
