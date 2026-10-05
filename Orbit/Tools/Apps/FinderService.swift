import Foundation

/// Orbit's Finder script (`Resources/AppleScripts/finder-selection.applescript`):
/// the items selected in Finder, for the context of a request. Live through
/// `LiveAppleScriptRunner`, but only once Orbit may control Finder (the
/// capture checks that without asking; the script itself would make macOS
/// ask). Tests pass a mock runner, the DEBUG fake-data mode one that answers
/// from invented paths.
struct FinderService: Sendable {
    /// Finder always runs and is only asked once Orbit may control it, so a
    /// run takes hundredths of a second; the limit is generous anyway.
    static let selectionScript = AppleScript(name: "finder-selection", app: .finder, timeout: .seconds(20))
    static let scripts = [selectionScript]

    /// What Finder has selected: how many items, and the paths of the first ones.
    struct Selection: Sendable, Hashable {
        /// The number of selected items (also those without a path).
        var total: Int
        /// POSIX paths of the first items (folders end with "/").
        var paths: [String]
    }

    let runner: any AppleScriptRunning

    /// The selection, with at most `maxItems` paths. Throws `AppleScriptError`.
    func selection(maxItems: Int) async throws -> Selection {
        let output = try await runner.run(Self.selectionScript, arguments: [String(max(1, maxItems))])
        guard let selection = Self.parse(output) else {
            Log.tools.error("AppleScript \(Self.selectionScript.name, privacy: .public) printed output Orbit does not understand")
            throw AppleScriptError.invalidOutput
        }
        return selection
    }

    /// The script's answer: the number of selected items, then a path per
    /// item, separated by NUL characters (which no path contains). nil when
    /// it is not that.
    static func parse(_ output: String) -> Selection? {
        let fields = output.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, let total = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)),
              total >= 0 else { return nil }
        let paths = fields.dropFirst().filter { $0.hasPrefix("/") }
        return Selection(total: max(total, paths.count), paths: Array(paths))
    }
}
