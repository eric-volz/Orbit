import SwiftUI

/// Search mode: "Orbit fragen: „…“" on top (highlighted by default), then the
/// instant results grouped by category with ⌘1 to ⌘9 hints.
struct SearchView: View {
    let query: String
    let groups: [SearchResultGroup]
    let selection: SearchSelection
    let maxHeight: CGFloat
    let onAsk: () -> Void
    let onOpen: (Int) -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    AskRow(query: query, isHighlighted: selection.isAskRowHighlighted, action: onAsk)
                        .id(SearchRowID.ask)
                    ForEach(SearchSection.sections(for: groups)) { section in
                        Text(verbatim: section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows) { row in
                            SearchResultRow(
                                result: row.result,
                                shortcutNumber: SearchSelection.shortcutNumber(forResultAt: row.index),
                                isHighlighted: selection.highlightedResultIndex == row.index
                            ) {
                                onOpen(row.index)
                            }
                            .id(SearchRowID.result(row.result.id))
                        }
                    }
                }
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(height: max(0, min(contentHeight, maxHeight)))
            .scrollDisabled(contentHeight <= maxHeight)
            .onChange(of: selection) { _, selection in
                if case .result(let id) = selection.row {
                    proxy.scrollTo(SearchRowID.result(id))
                } else {
                    proxy.scrollTo(SearchRowID.ask)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Search results"))
    }
}

private enum SearchRowID: Hashable {
    case ask
    case result(String)
}

/// Groups with each result's index in display order (for highlight and ⌘1 to ⌘9).
struct SearchSection: Identifiable, Equatable {
    struct Row: Identifiable, Equatable {
        var index: Int
        var result: SearchResult
        var id: String { result.id }
    }

    var id: String
    var title: String
    var rows: [Row]

    static func sections(for groups: [SearchResultGroup]) -> [SearchSection] {
        var index = 0
        var sections: [SearchSection] = []
        for group in groups where !group.results.isEmpty {
            let rows = group.results.map { result in
                defer { index += 1 }
                return Row(index: index, result: result)
            }
            sections.append(SearchSection(id: group.id, title: group.title, rows: rows))
        }
        return sections
    }
}

/// "Ask Orbit: “…”" sends the input to the agent.
struct AskRow: View {
    let query: String
    let isHighlighted: Bool
    let action: () -> Void

    /// "Orbit fragen: „Telekom Rechnung“".
    nonisolated static func title(for query: String) -> String {
        String(format: String(localized: "Ask Orbit: “%@”"), query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .accessibilityHidden(true)
                Text(verbatim: Self.title(for: query))
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                KeyCapLabel(text: isHighlighted ? "↩" : "⌘↩")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isSelected: isHighlighted)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityHint(Text("Sends your input to Orbit"))
    }
}

/// One instant result: icon, title, subtitle and its ⌘ number.
struct SearchResultRow: View {
    let result: SearchResult
    let shortcutNumber: Int?
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: result.title)
                        .font(.system(size: 13.5))
                        .lineLimit(1)
                    if let subtitle = result.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let shortcutNumber {
                    KeyCapLabel(text: "⌘\(shortcutNumber)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isSelected: isHighlighted)
        .accessibilityLabel(Text(verbatim: result.title))
        .accessibilityValue(Text(verbatim: Self.accessibilityValue(for: result, shortcutNumber: shortcutNumber)))
        .accessibilityHint(Text("Open"))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// What VoiceOver reads after the title: the subtitle and the ⌘ number
    /// ("Programm, Befehl-1"); the key caps themselves are hidden from it.
    nonisolated static func accessibilityValue(for result: SearchResult, shortcutNumber: Int?) -> String {
        [result.spokenSubtitle ?? result.subtitle, shortcutNumber.map(SearchAnnouncement.shortcut)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var icon: some View {
        switch result.kind {
        case .app(let url):
            FileIconView(path: url.path, size: 26)
        case .file(let url):
            FileIconView(path: url.path, isDirectory: url.hasDirectoryPath, size: 26)
        case .contact:
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// What VoiceOver announces in search mode, where the keyboard stays in the
/// input: the row ↑/↓ moved to, and how many results a search found.
enum SearchAnnouncement {
    /// "Befehl-3" (⌘3).
    static func shortcut(_ number: Int) -> String {
        String(format: String(localized: "Command-%lld"), number)
    }

    /// The highlighted row: "Orbit fragen: „ma“" or "Mail, Programm, Befehl-1".
    static func text(for selection: SearchSelection, query: String, results: [SearchResult]) -> String {
        guard let index = selection.highlightedResultIndex, results.indices.contains(index) else {
            return AskRow.title(for: query)
        }
        let result = results[index]
        let value = SearchResultRow.accessibilityValue(for: result,
                                                       shortcutNumber: SearchSelection.shortcutNumber(forResultAt: index))
        return value.isEmpty ? result.title : result.title + ", " + value
    }

    /// Once a search settled: "No results", "1 result", "7 Ergebnisse".
    static func resultCount(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No results")
        case 1: String(localized: "1 result")
        default: String(format: String(localized: "%lld results"), count)
        }
    }
}

/// "Chat fortsetzen: „…“" under the empty input when the chat is parked (see
/// `ChatParking`): a click, or ↑ in the input, shows the chat again.
struct ContinueChatRow: View {
    /// The conversation's title (its first message).
    let title: String?
    let action: () -> Void

    /// "Chat fortsetzen: „Finde die Telekom-Rechnung“".
    nonisolated static func text(title: String?) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? String(localized: "Continue chat")
            : String(format: String(localized: "Continue chat: “%@”"), title)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text(verbatim: Self.text(title: title))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                KeyCapLabel(text: "↑")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight()
        .padding(8)
        .accessibilityLabel(Text(verbatim: Self.text(title: title)))
        .accessibilityHint(Text("Shows the last chat again."))
    }
}
