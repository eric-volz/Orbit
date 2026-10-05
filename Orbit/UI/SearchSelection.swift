import Foundation

/// Keyboard highlight in search mode.
///
/// Position 0 is the "Orbit fragen" row, which is highlighted by default;
/// positions 1…n are the instant results in display order. Arrow keys wrap
/// around. When the result list changes, the highlight stays on the same
/// result (matched by id) or is clamped to the nearest valid position.
struct SearchSelection: Hashable, Sendable {
    enum Row: Hashable, Sendable {
        case ask
        case result(id: String)
    }

    /// What Return (or ⌘Return) does.
    enum Action: Hashable, Sendable {
        case askAgent
        case openResult(index: Int)
    }

    /// ⌘1 … ⌘9.
    static let shortcutCount = 9

    private(set) var resultIDs: [String]
    private(set) var row: Row = .ask

    init(resultIDs: [String] = []) {
        self.resultIDs = resultIDs
    }

    /// 0 for the ask row, otherwise the result index + 1.
    var position: Int {
        guard case .result(let id) = row, let index = resultIDs.firstIndex(of: id) else { return 0 }
        return index + 1
    }

    /// Index into the results, or nil while the ask row is highlighted.
    var highlightedResultIndex: Int? {
        position == 0 ? nil : position - 1
    }

    var isAskRowHighlighted: Bool {
        position == 0
    }

    mutating func moveDown() {
        move(by: 1)
    }

    mutating func moveUp() {
        move(by: -1)
    }

    /// Highlights the ask row again (new query).
    mutating func reset() {
        row = .ask
    }

    /// Highlights the result at `index` (clamped to the valid range).
    mutating func highlightResult(at index: Int) {
        setPosition(index + 1)
    }

    /// Adopts a new result list for the current query. Keeps the highlighted
    /// result if it is still present, otherwise clamps the old position.
    mutating func updateResults(_ ids: [String]) {
        let oldPosition = position
        resultIDs = ids
        switch row {
        case .ask:
            return
        case .result(let id):
            if ids.contains(id) { return }
            setPosition(oldPosition)
        }
    }

    /// What Return does: open the highlighted result, or ask the agent. ⌘Return
    /// always asks the agent.
    func returnAction(commandPressed: Bool) -> Action {
        if !commandPressed, let index = highlightedResultIndex {
            return .openResult(index: index)
        }
        return .askAgent
    }

    /// The result index opened by ⌘`number` (1-based), or nil when there is
    /// no such result.
    static func resultIndex(forShortcut number: Int, resultCount: Int) -> Int? {
        guard (1...shortcutCount).contains(number), number <= resultCount else { return nil }
        return number - 1
    }

    /// The ⌘ number shown next to the result at `index`, or nil beyond ⌘9.
    static func shortcutNumber(forResultAt index: Int) -> Int? {
        (0..<shortcutCount).contains(index) ? index + 1 : nil
    }

    private mutating func move(by delta: Int) {
        let rowCount = resultIDs.count + 1
        let next = ((position + delta) % rowCount + rowCount) % rowCount
        setPosition(next)
    }

    private mutating func setPosition(_ position: Int) {
        let clamped = min(max(position, 0), resultIDs.count)
        row = clamped == 0 ? .ask : .result(id: resultIDs[clamped - 1])
    }
}
