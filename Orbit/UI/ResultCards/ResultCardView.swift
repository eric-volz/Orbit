import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the structured result of a tool call as a card in the chat.
struct ResultCardView: View, Equatable {
    let card: ResultCard
    /// The chat item showing the card.
    let id: UUID

    var body: some View {
        switch card {
        case .files(let items): FileCardView(id: id, items: items)
        case .mails(let items): MailCardView(id: id, items: items)
        case .mailDraft(let draft): MailDraftCardView(id: id, draft: draft)
        case .notes(let items): NoteCardView(id: id, items: items)
        case .events(let items): EventCardView(id: id, items: items)
        case .reminders(let items): ReminderCardView(id: id, items: items)
        case .contacts(let items): ContactCardView(items: items)
        case .photos(let items): PhotoCardView(id: id, items: items)
        case .info(let item): InfoCardView(item: item)
        }
    }
}

// MARK: - Building blocks

/// A card with a small header ("3 Dateien") and rows.
struct ResultCardContainer<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }
}

/// Shows the first `limit` items and a button for the rest.
struct CollapsibleRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var limit = 5
    @ViewBuilder let row: (Item) -> Row
    @State private var isExpanded = false

    var body: some View {
        ForEach(isExpanded ? items : Array(items.prefix(limit))) { item in
            row(item)
        }
        if items.count > limit {
            Button {
                isExpanded.toggle()
            } label: {
                Text(verbatim: isExpanded
                     ? String(localized: "Show Less")
                     : String(format: String(localized: "Show %lld More"), items.count - limit))
                    .font(.system(size: 12))
            }
            .buttonStyle(.link)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }
}

/// A simple confirmation of something that happened ("Dunkelmodus aktiviert").
struct InfoCardView: View {
    let item: InfoItem

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: Self.symbolName(item.systemImage))
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = item.detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }

    /// Falls back to a generic symbol when a tool names one that does not exist.
    static func symbolName(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "info.circle" : name
    }
}

// MARK: - Formatting

/// Short, friendly dates for cards in the interface's language (and the
/// user's region): "2:32 PM" today, "Yesterday", "Mar 3", "Mar 3, 2025";
/// "14:32", "Gestern", "3. März", "3. März 2025" in German.
enum CardDateFormatter {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                       locale: Locale = AppLanguage.locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return yesterdayName(locale: locale, calendar: calendar)
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style)
        }
        return date.formatted(style.year())
    }

    /// "Yesterday", "Gestern": the locale's own word, capitalized as a
    /// card's date field starts.
    static func yesterdayName(locale: Locale, calendar: Calendar = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(from: DateComponents(day: -1))
    }

    /// Date and time, e.g. for due dates: "Di., 29. Sept., 14:30".
    static func dateTime(_ date: Date, includesTime: Bool, calendar: Calendar = .current,
                         locale: Locale = AppLanguage.locale) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        if includesTime { style = style.hour().minute() }
        return date.formatted(style)
    }
}

/// Paths for display.
enum FilePathFormatter {
    /// "~/Documents/Rechnungen" for "/Users/me/Documents/Rechnungen/a.pdf".
    static func parentFolder(of path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        abbreviate((path as NSString).deletingLastPathComponent, homeDirectory: homeDirectory)
    }

    /// Replaces the home directory with "~".
    static func abbreviate(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - File icons

/// A file's icon: the generic icon for its type right away (no disk access),
/// then the file's own icon (apps, custom icons) loaded off the main thread.
struct FileIconView: View {
    let path: String
    var contentType: String?
    var isDirectory = false
    var size: CGFloat = 28

    @State private var icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? FileIcons.typeIcon(path: path, contentType: contentType, isDirectory: isDirectory))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: path) {
                icon = await FileIcons.icon(forPath: path, pointSize: size)
            }
            .accessibilityHidden(true)
    }
}

@MainActor
enum FileIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    /// The generic icon for the file's type (by UTI or extension).
    static func typeIcon(path: String, contentType: String?, isDirectory: Bool) -> NSImage {
        let type: UTType
        if isDirectory {
            type = .folder
        } else if let contentType, let declared = UTType(contentType) {
            type = declared
        } else if let byExtension = UTType(filenameExtension: (path as NSString).pathExtension) {
            type = byExtension
        } else {
            type = .data
        }
        return NSWorkspace.shared.icon(for: type)
    }

    /// The file's own icon at `pointSize` (rendered for Retina), or nil if the
    /// file does not exist.
    static func icon(forPath path: String, pointSize: CGFloat) async -> NSImage? {
        let key = "\(Int(pointSize)):\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let pixels = Int(pointSize * 2)
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let image = NSWorkspace.shared.icon(forFile: path)
            var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
        cache.setObject(image, forKey: key)
        return image
    }
}
