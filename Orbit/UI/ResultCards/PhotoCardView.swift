import AppKit
import SwiftUI

/// Photos and videos as a grid of thumbnails (from `PhotoCardActions`, i.e.
/// PhotoKit, never downloaded from iCloud; tiles without one show what they
/// are). A click (or Return on the tile the keyboard selected) shows the
/// photo in Photos. Keyboard as on the other cards (`CardKeyboard`): Tab from
/// the input reaches the latest card, ←/→ select a tile, ↑/↓ a row (past the
/// first three rows the card unfolds), and VoiceOver hears the kind, date and
/// state of each tile. Thumbnails are requested when the card appears and
/// cancelled when it goes away (the chat drops cards far out of view).
struct PhotoCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let items: [PhotoItem]
    @Environment(PhotoCardActions.self) private var actions: PhotoCardActions?
    @State private var selection: FileCardSelection
    @State private var columns = PhotoGridLayout.defaultColumns
    @FocusState private var isFocused: Bool

    init(id: UUID = UUID(), items: [PhotoItem], selection: FileCardSelection? = nil) {
        self.id = id
        self.items = items
        _selection = State(initialValue: selection ?? FileCardSelection(
            count: items.count, collapsedLimit: PhotoGridLayout.collapsedLimit(columns: PhotoGridLayout.defaultColumns)))
    }

    var body: some View {
        ResultCardContainer(title: Phrases.photos(items.count), systemImage: ToolCategory.photos.systemImage) {
            VStack(alignment: .leading, spacing: 2) {
                grid
                CollapseToggle(selection: $selection)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .modifier(CardKeyboard(id: id, selection: $selection, isFocused: $isFocused,
                               announcement: { items.indices.contains($0) ? PhotoCardFormat.announcement(for: items[$0]) : "" },
                               activate: show(at:), columns: columns))
        .onChange(of: items.count) { _, count in selection.updateCount(count) }
        .onAppear { actions?.thumbnails.prepare(items.map(\.id), pixels: PhotoGridLayout.thumbnailPixels) }
        .onDisappear { actions?.thumbnails.release(items.map(\.id), pixels: PhotoGridLayout.thumbnailPixels) }
    }

    /// Rows of `columns` square tiles (the last row keeps the column width).
    private var grid: some View {
        let visible = selection.visibleCount
        let columns = columns
        let rows = (visible + columns - 1) / columns
        return VStack(spacing: PhotoGridLayout.spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: PhotoGridLayout.spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < visible {
                            PhotoTile(item: items[index], isSelected: selection.index == index, isCardFocused: isFocused,
                                      thumbnails: actions?.thumbnails,
                                      show: actions.map { actions in
                                          {
                                              selection.select(index)
                                              actions.show(items[index])
                                          }
                                      })
                                .id(FileCardCoordinator.rowID(card: id, index: index))
                        } else {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: Int.self) { geometry in
            PhotoGridLayout.columns(forWidth: geometry.size.width)
        } action: { count in
            guard count != self.columns else { return }
            self.columns = count
            selection.updateCollapsedLimit(PhotoGridLayout.collapsedLimit(columns: count))
        }
    }

    /// Return on a tile: the photo shows in Photos.
    private func show(at index: Int) {
        guard let actions, items.indices.contains(index) else { return }
        actions.show(items[index])
    }
}

/// One tile: the thumbnail (or what the item is), a heart for favorites, the
/// Live Photo badge and a video's length.
struct PhotoTile: View {
    let item: PhotoItem
    /// Selected by the keyboard (accent ring while the card has it, gray otherwise).
    var isSelected = false
    var isCardFocused = false
    /// Where the thumbnail comes from; nil: the placeholder only.
    var thumbnails: (any PhotoThumbnailProviding)?
    /// Shows the photo in Photos; nil = not clickable.
    var show: (() -> Void)?

    /// The thumbnail the task got, for the item it got it for.
    @State private var loaded: LoadedThumbnail?
    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    struct LoadedThumbnail {
        var id: String
        var thumbnail: PhotoThumbnail
    }

    /// The thumbnail as far as it is known (a cached one before the task ran).
    private var thumbnail: PhotoThumbnail? {
        if let loaded, loaded.id == item.id { return loaded.thumbnail }
        return thumbnails?.cachedThumbnail(for: item.id, pixels: PhotoGridLayout.thumbnailPixels)
    }

    var body: some View {
        Group {
            if let show {
                Button(action: show) {
                    tile
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: PhotoCardFormat.tooltip(for: item)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: PhotoCardFormat.announcement(for: item, thumbnail: thumbnail)))
                .accessibilityHint(Text("Shows the photo in Photos"))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            } else {
                tile
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: PhotoCardFormat.announcement(for: item, thumbnail: thumbnail)))
                    .accessibilityAddTraits(isSelected ? [.isImage, .isSelected] : .isImage)
            }
        }
        .task(id: item.id) {
            guard let thumbnails else { return }
            let id = item.id
            let result = await thumbnails.thumbnail(for: id, pixels: PhotoGridLayout.thumbnailPixels)
            // A tile that went away (or shows another item now) keeps what it has.
            guard !Task.isCancelled else { return }
            loaded = LoadedThumbnail(id: id, thumbnail: result)
        }
    }

    private var hasImage: Bool {
        if case .image? = thumbnail { return true }
        return false
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape
            .fill(Color.primary.opacity(0.07))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { picture }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .topLeading) {
                if item.mediaType == .livePhoto {
                    Image(systemName: "livephoto")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hasImage ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .shadow(color: .black.opacity(hasImage ? 0.55 : 0), radius: 1.5)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 1.5)
                        .padding(5)
                }
            }
            .clipShape(shape)
            .overlay {
                if isHovered, !isSelected {
                    shape.fill(Color.white.opacity(0.08))
                }
            }
            .overlay {
                let edge = PhotoGridLayout.edge(isSelected: isSelected, isFocused: isCardFocused,
                                                increasedContrast: contrast == .increased,
                                                differentiateWithoutColor: differentiateWithoutColor)
                shape.strokeBorder(isSelected ? (isCardFocused ? Color.accentColor : Color.secondary)
                                   : Color.primary.opacity(edge.opacity),
                                   lineWidth: edge.width)
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var picture: some View {
        switch thumbnail {
        case .image(let image)?:
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        case .inCloud?:
            Image(systemName: "icloud")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
        case .unavailable?, nil:
            Image(systemName: PhotoCardFormat.systemImage(item))
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
        }
    }

    /// A video's length (on a dark band over the picture); the date when
    /// there is no picture.
    @ViewBuilder
    private var caption: some View {
        let duration = item.mediaType == .video ? item.duration.map { MediaDuration.string(seconds: $0) } : nil
        if hasImage {
            if let duration {
                HStack {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8))
                    Spacer(minLength: 0)
                    Text(verbatim: duration)
                        .monospacedDigit()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            }
        } else {
            HStack(spacing: 4) {
                if let date = item.creationDate {
                    Text(verbatim: CardDateFormatter.string(for: date))
                }
                Spacer(minLength: 0)
                if let duration {
                    Text(verbatim: duration)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.bottom, 4)
        }
    }
}

/// The grid's metrics (pure).
enum PhotoGridLayout {
    static let spacing: CGFloat = 6
    /// Tiles are at least this wide; as many columns as fit.
    static let minimumTileWidth: CGFloat = 78
    /// The columns of a card in the panel (720 pt wide) before its width is measured.
    static let defaultColumns = 7
    /// Rows shown before "Show N More".
    static let collapsedRows = 3
    /// Pixels on the shorter side of a thumbnail: tiles are about 90 pt wide, at 2x.
    static let thumbnailPixels = 200

    /// Columns for a grid `width` points wide.
    static func columns(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return defaultColumns }
        return max(1, Int(((width + spacing) / (minimumTileWidth + spacing)).rounded(.down)))
    }

    /// Tiles shown while the card is collapsed: whole rows.
    static func collapsedLimit(columns: Int) -> Int {
        collapsedRows * max(1, columns)
    }

    /// A tile's edge: the selected tile has a thick ring (accent while the card has the
    /// keyboard, gray otherwise; with Differentiate Without Color the gray one is thinner,
    /// so the keyboard is not told by color alone); the others a hairline, a clear line with
    /// Increase Contrast. `opacity` is for unselected tiles.
    static func edge(isSelected: Bool, isFocused: Bool, increasedContrast: Bool,
                     differentiateWithoutColor: Bool) -> (width: CGFloat, opacity: Double) {
        if isSelected { return (differentiateWithoutColor && !isFocused ? 1.5 : 2.5, 1) }
        return increasedContrast ? (1, Theme.increasedContrastEdgeOpacity) : (0.5, 0.06)
    }
}

/// What a tile says beyond its picture, and what VoiceOver hears.
enum PhotoCardFormat {
    /// "Photo", "Live Photo", "Screenshot", "Video".
    static func kind(_ item: PhotoItem) -> String {
        switch item.mediaType {
        case .video: String(localized: "Video")
        case .livePhoto: String(localized: "Live Photo")
        case .image, .other: item.isScreenshot == true ? String(localized: "Screenshot") : String(localized: "Photo")
        }
    }

    static func systemImage(_ item: PhotoItem) -> String {
        switch item.mediaType {
        case .video: "video"
        case .livePhoto: "livephoto"
        case .image, .other: item.isScreenshot == true ? "camera.viewfinder" : "photo"
        }
    }

    /// When it was taken: "Mon, July 13 at 6:42 PM", with the year when it is
    /// not this year ("Sun, July 13, 2025 at 6:42 PM").
    static func date(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = AppLanguage.locale) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.wide).hour().minute()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// A video's length in words: "42 Sekunden", "1 Minute, 15 Sekunden".
    static func spokenDuration(_ seconds: Double, locale: Locale = AppLanguage.locale) -> String {
        Duration.seconds(max(0, seconds.rounded()))
            .formatted(Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }

    /// Kind (with a video's length), date, "Favorite" and "Only in iCloud".
    static func announcement(for item: PhotoItem, thumbnail: PhotoThumbnail? = nil, now: Date = Date(),
                             calendar: Calendar = .current, locale: Locale = AppLanguage.locale) -> String {
        var kind = kind(item)
        if item.mediaType == .video, let duration = item.duration {
            kind += ", " + spokenDuration(duration, locale: locale)
        }
        var parts = [kind]
        if let created = item.creationDate { parts.append(date(created, now: now, calendar: calendar, locale: locale)) }
        if item.isFavorite { parts.append(String(localized: "Favorite")) }
        if thumbnail == .inCloud { parts.append(String(localized: "Only in iCloud")) }
        return parts.joined(separator: ", ")
    }

    /// The tooltip: the date and what a click does.
    static func tooltip(for item: PhotoItem, now: Date = Date(), calendar: Calendar = .current,
                        locale: Locale = AppLanguage.locale) -> String {
        let action = String(localized: "Show in Photos")
        guard let created = item.creationDate else { return action }
        return String(format: String(localized: "%1$@, %2$@"), date(created, now: now, calendar: calendar, locale: locale), action)
    }
}

enum MediaDuration {
    /// "0:42", "12:05", "1:02:03", as the locale writes a duration (the
    /// interface's for cards; the model gets `Locale(identifier: "en_US_POSIX")`).
    static func string(seconds: Double, locale: Locale = AppLanguage.locale) -> String {
        let total = max(0, Int(seconds.rounded()))
        let pattern: Duration.TimeFormatStyle.Pattern = total >= 3_600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(total).formatted(.time(pattern: pattern).locale(locale))
    }
}
