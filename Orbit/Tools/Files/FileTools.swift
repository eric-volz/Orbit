import Foundation

/// The file tools: search_files, read_file, open_file, reveal_in_finder and
/// recent_files, in this order in Settings too.
enum FileTools {
    static func all(context: FileToolContext) -> [any Tool] {
        [
            SearchFilesTool(context: context),
            ReadFileTool(context: context),
            OpenFileTool(context: context),
            RevealInFinderTool(context: context),
            RecentFilesTool(context: context),
        ]
    }
}

/// What the file tools share: system access (injected, so tests use fakes)
/// and the rules for paths.
struct FileToolContext: Sendable {
    var spotlight: any SpotlightQuerying
    var workspace: any FileWorkspace
    var scope: FileSearchScope
    var policy: FileAccessPolicy
    var now: @Sendable () -> Date
    var timeZone: TimeZone
    /// How long a Spotlight search may gather before a tool answers with what it has.
    var spotlightTimeout: Duration
    /// Folder names for the rows of file cards and instant search.
    var folderNames: FolderNames

    init(spotlight: any SpotlightQuerying, workspace: any FileWorkspace, scope: FileSearchScope,
         policy: FileAccessPolicy, now: @escaping @Sendable () -> Date = { Date() },
         timeZone: TimeZone = .autoupdatingCurrent, spotlightTimeout: Duration = .seconds(10),
         folderNames: FolderNames? = nil) {
        self.spotlight = spotlight
        self.workspace = workspace
        self.scope = scope
        self.policy = policy
        self.now = now
        self.timeZone = timeZone
        self.spotlightTimeout = spotlightTimeout
        self.folderNames = folderNames ?? .live(homeDirectory: scope.homeDirectory)
    }

    var homeDirectory: String { scope.homeDirectory }
    var visibility: FileVisibility { FileVisibility(homeDirectory: scope.homeDirectory) }

    // MARK: Paths

    /// An absolute, normalized path from a path argument ("~" expanded, file
    /// URLs and quotes accepted).
    func absolutePath(_ argument: String, parameter: String) throws -> String {
        let path = FilePath.expand(argument, home: homeDirectory)
        guard path.hasPrefix("/") else {
            throw ToolError.invalidArgument("'\(parameter)' must be an absolute path or start with ~/ (got '\(FileToolFormat.inline(argument))').")
        }
        return path
    }

    /// A path for the model: "~"-abbreviated, single-line, neutralized.
    func display(_ path: String) -> String {
        FileToolFormat.inline(FilePath.abbreviate(path, home: homeDirectory), maxCharacters: 1_000)
    }

    /// The `path` parameter of read_file, open_file and reveal_in_finder.
    static func pathDescription(of item: String) -> String {
        """
        Absolute path of the \(item) (or ~/…), exactly as search_files or recent_files listed it or as the user \
        gave it. If you only know a name or part of the path, call search_files first; do not guess paths.
        """
    }

    /// Where the folders are that Finder shows under German names.
    static let folderNamesNote = """
        Folder names on disk are English even where Finder shows German names: ~/Desktop (Schreibtisch), \
        ~/Documents (Dokumente), ~/Downloads, ~/Pictures (Bilder), ~/Movies (Filme), ~/Music (Musik); iCloud Drive \
        is ~/Library/Mobile Documents/com~apple~CloudDocs.
        """

    /// The result for a path the policy denies.
    func denied(_ denial: FileAccessPolicy.Denial) -> ToolResult {
        ToolResult.failure(denial.modelMessage, summary: String(localized: "Access not allowed"))
    }

    /// Checks an existing item for `purpose`: the policy first (so denied paths
    /// do not reveal whether they exist), then existence. A path copied from a
    /// result row may not exist as written (see `itemShown(as:purpose:)`); then
    /// `path` becomes the item the row showed, which is checked in full again.
    /// Matched to an item the policy denies, the path is not found: the same
    /// answer as for a path matched to nothing, so a protected path disguised
    /// with an invisible character ("~/.ssh" with a zero-width space) cannot
    /// tell whether a guessed item in it exists.
    /// Returns the denial result, or nil when the item at `path` may be used.
    func checkAccess(_ path: inout String, purpose: FileAccessPolicy.Purpose) throws -> ToolResult? {
        if let denial = policy.check(path, purpose: purpose) {
            return denied(denial)
        }
        guard !FileManager.default.fileExists(atPath: path) else { return nil }
        guard let shown = itemShown(as: path, purpose: purpose), policy.check(shown, purpose: purpose) == nil else {
            throw ToolError.notFound("There is no file or folder at \(display(path)). Use search_files to find it.")
        }
        path = shown
        return nil
    }

    /// The existing item a result row showed as `path` (absolute, normalized),
    /// which does not exist as written. Rows show names neutralized
    /// (`FileToolFormat.inline`: invisible format characters such as the
    /// joiner in "👨‍👩‍👧" removed, < and > shown as ‹ ›), so each missing
    /// component is replaced by the one entry of its folder that a row shows
    /// the same way. nil when a component matches no entry or several. Only
    /// the folders of missing components are listed, and only those the
    /// policy allows for `purpose`; callers check the result with the policy
    /// again (symlinks resolved, debug scope).
    func itemShown(as path: String, purpose: FileAccessPolicy.Purpose) -> String? {
        let manager = FileManager.default
        var current = "/"
        var matched = false
        for component in path.split(separator: "/").map(String.init) {
            let exact = FilePath.normalize(current + "/" + component)
            if manager.fileExists(atPath: exact) {
                current = exact
                continue
            }
            let wanted = FileToolFormat.shownName(component)
            guard policy.check(current, purpose: purpose) == nil,
                  let entries = try? manager.contentsOfDirectory(atPath: current) else { return nil }
            let candidates = entries.filter { FileToolFormat.shownName($0) == wanted }
            guard candidates.count == 1, let entry = candidates.first else { return nil }
            current = FilePath.normalize(current + "/" + entry)
            matched = true
        }
        return matched && manager.fileExists(atPath: current) ? current : nil
    }

    // MARK: Search results

    /// Whether a Spotlight item may be listed: visible in Finder and allowed by
    /// the policy's path rules. Touches the disk only for `*.key` files the
    /// rules allow otherwise (their metadata, and the first bytes of small
    /// local ones, never downloading a file; an undecided one is left out).
    func isListable(_ item: SpotlightItem) -> Bool {
        let path = FilePath.normalize(item.path)
        // The rules first, without touching the disk; a `*.key` file may still be a Keynote document.
        guard path.hasPrefix("/"), visibility.isVisible(path), scope.allows(path),
              policy.allowsListing(path, isKeynoteDocument: true) else { return false }
        guard path.lowercased().hasSuffix(".key") else { return true }
        let keynote = FileAccessPolicy.isKeynoteDocument(atPath: path, mayDownload: false) ?? false
        return policy.allowsListing(path, isKeynoteDocument: keynote)
    }

    /// The `candidates` that pass the full policy check (symlinks resolved)
    /// and still exist, because Spotlight's index lags behind deletions. Touches the
    /// disk once per item; candidates are bounded by the tools' read limits.
    func verified(_ candidates: [SpotlightItem]) -> [SpotlightItem] {
        candidates.filter { item in
            policy.check(item.path, purpose: .list) == nil && FileManager.default.fileExists(atPath: item.path)
        }
    }

    /// A folder argument for searches: absolute, existing, a real folder (not
    /// a package), visible and allowed, or a folder that contains the home
    /// folder ("~", "/Users", "/"), which `SearchFilesTool` searches as the
    /// default folders. A path copied from a result row is matched back like
    /// in `checkAccess` (matched to a folder the policy denies, it is not found).
    func searchFolder(_ argument: String) throws -> String {
        var path = try absolutePath(argument, parameter: "folder")
        if let denial = policy.check(path, purpose: .list) {
            throw ToolError.invalidArgument("'folder' cannot be searched. \(denial.modelMessage)")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard let shown = itemShown(as: path, purpose: .list), policy.check(shown, purpose: .list) == nil,
                  FileManager.default.fileExists(atPath: shown, isDirectory: &isDirectory) else {
                throw ToolError.notFound("There is no folder at \(display(path)). \(Self.folderNamesNote)")
            }
            path = shown
        }
        let canonical = FilePath.canonical(path)
        if FilePath.isInside(homeDirectory, canonical) { return canonical }
        guard isDirectory.boolValue, !FileVisibility.isPackageName(Substring(FilePath.lastComponent(canonical))) else {
            throw ToolError.invalidArgument("'folder' must be a folder; \(display(path)) is a file or package.")
        }
        guard visibility.isVisible(canonical) else {
            throw ToolError.invalidArgument("'folder' must be a folder the user sees in Finder; Orbit does not search hidden folders or ~/Library (except iCloud Drive and cloud storage).")
        }
        return canonical
    }

    // MARK: Summaries

    /// "No files found", "Found 1 file", "Found 12 files".
    static func foundSummary(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No files found")
        case 1: String(localized: "Found 1 file")
        default: String(format: String(localized: "Found %lld files"), count)
        }
    }

    /// The file name for status lines ("Lese „Rechnung.pdf“…").
    static func fileName(in arguments: ToolArguments) -> String {
        let name = FilePath.lastComponent(arguments.optionalString("path") ?? "")
        return name.isEmpty ? "…" : String(name.prefix(80))
    }
}
