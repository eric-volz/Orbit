import Foundation
import UniformTypeIdentifiers

/// `open_file`: opens a document or folder in its default app. Refuses
/// anything that could run code when opened (see `OpenFileSafety`); a Finder
/// alias opens its target, which is checked instead.
struct OpenFileTool: Tool {
    let context: FileToolContext

    let name = "open_file"
    var displayName: String { String(localized: "Open file") }
    let description = """
        Opens a file in its default app (a PDF in Preview, a document in Pages or Word, a folder in Finder), like \
        a double-click. Use it when the user asks to open or show a file they want to look at, with a path from \
        search_files, recent_files or the Finder selection. Apps, programs, scripts, installers and link files are \
        never opened (they could run code); use reveal_in_finder for them.
        """
    var inputSchema: JSONSchema {
        .object(properties: [
            "path": .string(description: FileToolContext.pathDescription(of: "file or folder")),
        ], required: ["path"])
    }
    let riskLevel: ToolRiskLevel = .draft
    let category: ToolCategory = .files

    func statusText(for arguments: ToolArguments) -> String {
        String(format: String(localized: "Opening “%@”…"), FileToolContext.fileName(in: arguments))
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        var path = try context.absolutePath(try arguments.string("path"), parameter: "path")
        if let denied = try context.checkAccess(&path, purpose: .open) {
            return denied
        }
        let target: String
        switch OpenFileSafety.verdict(forOpening: path, policy: context.policy) {
        case .open(let checked):
            target = checked
        case .refused(let refusal):
            return ToolResult.failure(refusal.modelMessage, summary: String(localized: "Not opened for security reasons"))
        case .denied(let denial):
            return context.denied(denial)
        }
        do {
            try await context.workspace.open(URL(fileURLWithPath: target))
        } catch {
            throw ToolError.failed("macOS could not open \(context.display(path)); there may be no app for this file type. Offer reveal_in_finder instead.")
        }
        let name = FilePath.lastComponent(path)
        return ToolResult(text: "Opened \(context.display(path)) in its default app.",
                          summary: String(format: String(localized: "Opened “%@”"), name))
    }
}

/// Decides whether opening a file could run code. open_file refuses apps and
/// bundles (plug-ins, preference panes, screen savers, …), executables,
/// scripts (shell, Python, AppleScript, `.command`, `.tool`), Terminal
/// settings and sessions (`.terminal`, `.term`), Automator workflows and
/// actions, Shortcuts, installer packages, configuration profiles, Java
/// archives, link files (`.webloc`, `.inetloc`, `.fileloc`, `.url`: they may
/// point to a program) and Unix executables with the x bit but no document
/// type. A Finder alias opens its target, so `verdict(forOpening:policy:)`
/// checks the target.
enum OpenFileSafety {
    enum Refusal: Sendable, Hashable {
        case application
        case executable
        case script
        case installer
        case link
        case configuration

        var modelMessage: String {
            let what = switch self {
            case .application: "an app or bundle"
            case .executable: "a program"
            case .script: "a script or automation"
            case .installer: "an installer package"
            case .link: "a link file that can point to a program"
            case .configuration: "a configuration profile"
            }
            return "Refused: this file is \(what); opening it could run code or change the system, so Orbit does not open such files. Use reveal_in_finder to show it in Finder, where the user can open it themselves."
        }
    }

    static let refusedExtensions: [String: Refusal] = {
        var table: [String: Refusal] = [:]
        for name in ["app", "appex", "prefpane", "saver", "qlgenerator", "mdimporter", "kext", "plugin", "bundle",
                     "framework", "xpc", "osax", "service", "wdgt", "component", "systemextension"] {
            table[name] = .application
        }
        for name in ["command", "tool", "sh", "bash", "zsh", "csh", "ksh", "tcsh", "fish", "py", "pyw", "pl", "rb",
                     "php", "js", "jsx", "mjs", "applescript", "scpt", "scptd", "terminal", "term", "workflow", "action",
                     "shortcut", "wflow", "caction", "alfredworkflow"] {
            table[name] = .script
        }
        for name in ["pkg", "mpkg"] { table[name] = .installer }
        for name in ["webloc", "inetloc", "fileloc", "url", "desktop", "afploc", "ftploc", "mailloc", "newsloc"] {
            table[name] = .link
        }
        for name in ["mobileconfig", "configprofile"] { table[name] = .configuration }
        for name in ["jar", "exe", "msi", "bat", "cmd", "com", "dylib", "so", "o"] { table[name] = .executable }
        return table
    }()

    /// Checked in order; a type also matches when it conforms to one of them.
    static let refusedTypeIdentifiers: [(identifier: String, refusal: Refusal)] = [
        ("com.apple.installer-package-archive", .installer),
        ("com.apple.installer-package", .installer),
        ("com.apple.web-internet-location", .link),
        ("com.apple.file-internet-location", .link),
        ("com.apple.generic-internet-location", .link),
        ("com.apple.internet-location", .link),
        ("com.microsoft.internet-shortcut", .link),
        ("com.apple.mobileconfig", .configuration),
        ("com.apple.terminal.settings", .script),
        // Legacy Terminal sessions (.term) can hold a command that runs when Terminal opens them.
        ("com.apple.terminal.session", .script),
        ("com.apple.automator-workflow", .script),
        ("com.apple.automator-action", .script),
        ("com.apple.shortcut", .script),
        ("com.apple.shortcuts.workflow-file", .script),
    ]

    /// Looks at the item at `path` (type, and the x bit of plain files).
    static func refusal(forPath path: String) -> Refusal? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isRegularFileKey])
        let isRegularFile = values?.isRegularFile == true
        let hasExecuteBit = isRegularFile && FileManager.default.isExecutableFile(atPath: path)
        return refusal(contentType: values?.contentType, pathExtension: url.pathExtension,
                       isRegularFileWithExecuteBit: hasExecuteBit)
    }

    /// What opening an item does.
    enum Verdict: Sendable, Hashable {
        /// Open this path: the item (symlinks resolved) or an alias's target.
        case open(String)
        case refused(Refusal)
        /// An alias's target is not allowed.
        case denied(FileAccessPolicy.Denial)
    }

    /// Whether the item at `path` may be opened, and what to open. The item as
    /// given and with symlinks resolved must be safe. A Finder alias is opened
    /// by macOS as its target, so the target decides: found without UI and
    /// without mounting volumes, allowed by `policy` for opening and safe,
    /// and the target is what is opened, so the file that was checked is the
    /// file that opens. An alias whose target cannot be found (or is an alias
    /// again), or any alias without a policy, is refused as a link file.
    static func verdict(forOpening path: String, policy: FileAccessPolicy?) -> Verdict {
        let canonical = FilePath.canonical(path)
        if let refusal = refusal(forPath: path) ?? refusal(forPath: canonical) {
            return .refused(refusal)
        }
        guard isFinderAlias(atPath: canonical) else { return .open(canonical) }
        guard let policy, let target = aliasTarget(ofPath: canonical) else { return .refused(.link) }
        if let denial = policy.check(target, purpose: .open) { return .denied(denial) }
        let resolvedTarget = FilePath.canonical(target)
        guard !isFinderAlias(atPath: resolvedTarget) else { return .refused(.link) }
        if let refusal = refusal(forPath: target) ?? refusal(forPath: resolvedTarget) {
            return .refused(refusal)
        }
        return .open(resolvedTarget)
    }

    /// A Finder alias: its type is com.apple.alias-file (whatever its name
    /// says), or its alias flag is set. Symlinks are no aliases here: they
    /// share com.apple.resolvable and `isAliasFile`, but `FilePath.canonical`
    /// resolves them.
    static func isFinderAlias(atPath path: String) -> Bool {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isAliasFileKey, .isSymbolicLinkKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return false }
        if values.contentType?.conforms(to: .aliasFile) == true { return true }
        return values.isAliasFile == true && values.isSymbolicLink != true
    }

    /// The target of the Finder alias at `path`; nil when it cannot be found
    /// without asking the user or mounting a volume.
    static func aliasTarget(ofPath path: String) -> String? {
        guard let target = try? URL(resolvingAliasFileAt: URL(fileURLWithPath: path), options: [.withoutUI, .withoutMounting]),
              target.isFileURL else { return nil }
        let targetPath = target.path(percentEncoded: false)
        return targetPath.hasPrefix("/") ? FilePath.normalize(targetPath) : nil
    }

    /// Pure rules.
    static func refusal(contentType: UTType?, pathExtension: String, isRegularFileWithExecuteBit: Bool) -> Refusal? {
        if let refusal = refusedExtensions[pathExtension.lowercased()] { return refusal }
        if let type = contentType {
            for (identifier, refusal) in refusedTypeIdentifiers {
                if type.identifier == identifier { return refusal }
                // Only declared types: an unknown identifier must not match everything.
                if let declared = UTType(identifier), !declared.isDynamic, type.conforms(to: declared) { return refusal }
            }
            if type.conforms(to: .application) || type.conforms(to: .applicationBundle) || type.conforms(to: .bundle) {
                return .application
            }
            if type.conforms(to: .script) || type.conforms(to: .shellScript) { return .script }
            if type.conforms(to: .executable) || type.conforms(to: .unixExecutable) { return .executable }
        }
        if isRegularFileWithExecuteBit {
            // A Unix executable without a document type ("backup", "run-me").
            guard let type = contentType, !type.isDynamic, type != .data, type != .item,
                  !type.conforms(to: .unixExecutable) else {
                return .executable
            }
        }
        return nil
    }
}
