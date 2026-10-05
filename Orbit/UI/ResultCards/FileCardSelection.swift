import Foundation

/// The selected row of a file card (or tile of a photo grid) and whether
/// the rows after the first `collapsedLimit` are shown. Arrow keys stop at the
/// first and last row (no wrap-around, like Finder); selecting a hidden row
/// expands the card, and collapsing it moves a hidden selection to the last
/// row still shown. In a grid, ↑/↓ move by a row of tiles
/// (`moveVertically(by:columns:)`). Pure, so it is unit-tested without views.
struct FileCardSelection: Hashable, Sendable {
    /// Rows shown while a card with rows is collapsed.
    static let collapsedLimit = 5

    private(set) var count: Int
    /// The selected row; nil until the user selects one.
    private(set) var index: Int?
    private(set) var isExpanded: Bool
    /// Rows (or tiles) shown while the card is collapsed.
    private(set) var collapsedLimit: Int

    init(count: Int, index: Int? = nil, isExpanded: Bool = false, collapsedLimit: Int = Self.collapsedLimit) {
        self.count = max(0, count)
        self.isExpanded = isExpanded
        self.collapsedLimit = max(1, collapsedLimit)
        if let index {
            select(index)
        }
    }

    /// Whether the card has rows to hide ("Show N More").
    var isCollapsible: Bool {
        count > collapsedLimit
    }

    /// Rows currently shown.
    var visibleCount: Int {
        isExpanded ? count : min(count, collapsedLimit)
    }

    /// Rows behind "Show N More".
    var hiddenCount: Int {
        count - visibleCount
    }

    /// Selects the row at `index` (clamped); a hidden row expands the card.
    mutating func select(_ index: Int) {
        guard count > 0 else {
            self.index = nil
            return
        }
        let clamped = min(max(index, 0), count - 1)
        if clamped >= visibleCount {
            isExpanded = true
        }
        self.index = clamped
    }

    /// ↓: the next row, or the first one when none is selected yet.
    mutating func moveDown() {
        select(index.map { $0 + 1 } ?? 0)
    }

    /// ↑: the previous row, or the first one when none is selected yet.
    mutating func moveUp() {
        select(index.map { $0 - 1 } ?? 0)
    }

    /// ↑ (`rows` -1) or ↓ (1) in a grid of `columns` tiles per row: the tile
    /// above or below, or the first one when none is selected yet. On the
    /// first row ↑ stays, on the last row ↓ stays, and a shorter last row is
    /// reached at its last tile (like Finder's icon view).
    mutating func moveVertically(by rows: Int, columns: Int) {
        guard let index else {
            select(0)
            return
        }
        let columns = max(1, columns)
        let target = index + rows * columns
        guard target >= 0, count > 0 else { return }
        guard target < count else {
            if index / columns < (count - 1) / columns { select(count - 1) }
            return
        }
        select(target)
    }

    /// The card got the keyboard: selects the first row unless one is selected.
    mutating func selectFirstIfNeeded() {
        if index == nil {
            select(0)
        }
    }

    /// "Show N More" / "Show Less".
    mutating func toggleExpanded() {
        guard isCollapsible else { return }
        isExpanded.toggle()
        if let index, index >= visibleCount {
            self.index = visibleCount - 1
        }
    }

    /// Adopts another number of rows, keeping the selection where possible.
    mutating func updateCount(_ count: Int) {
        self.count = max(0, count)
        if let index {
            select(index)
        }
    }

    /// Adopts another collapsed size (a grid got another number of columns);
    /// a selection that it would hide expands the card.
    mutating func updateCollapsedLimit(_ limit: Int) {
        collapsedLimit = max(1, limit)
        if let index {
            select(index)
        }
    }
}
