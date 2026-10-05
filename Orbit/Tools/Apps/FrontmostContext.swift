import Foundation
import os

/// The app in front of Orbit when the context is read.
struct FrontmostApp: Sendable, Hashable {
    /// The name Finder and the Dock show.
    var name: String
    var bundleID: String?
    var processID: pid_t
}

/// What Orbit can see of the frontmost app right now: its name, the focused
/// window's title and what is selected there: the selected text, or in Finder
/// the selected items. Each part only where macOS already allows it (reading
/// never asks for a permission), never from Orbit itself, a password field or
/// a password manager. `gaps` says what is missing and why.
struct FrontmostContext: Sendable, Hashable {
    /// Why a part is missing.
    enum Gap: String, Sendable, Hashable, CaseIterable, Comparable {
        /// No other app is in front of Orbit.
        case noApp
        /// The frontmost app keeps passwords: nothing is read from it.
        case passwordManager
        /// Accessibility is not allowed: no window title, no selected text.
        case accessibilityNotGranted
        /// The focused field is a password field (or secure keyboard entry is on).
        case secureField
        /// The app did not answer through Accessibility in time.
        case appDidNotAnswer
        /// Orbit may not control Finder: no Finder selection.
        case finderNotPermitted
        /// Finder's selection could not be read.
        case finderSelectionFailed
        /// Selected items Orbit never shares (keys, other secrets, ~/Library, …) were left out.
        case itemsWithheld

        static func < (lhs: Gap, rhs: Gap) -> Bool {
            (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    var app: FrontmostApp?
    var windowTitle: String?
    /// The selected text, at most `FrontmostContextLimits.selectedTextCharacters`.
    var selectedText: String?
    /// How long the selection is (about, in characters) when only its start was read.
    var selectedTextLength: Int?
    /// The selected Finder items Orbit may share, as paths ("~/…"; folders end with "/").
    var finderPaths: [String] = []
    /// How many items are selected in Finder; nil when not read.
    var finderSelectionCount: Int?
    /// How many of the selected Finder items were left out because Orbit
    /// never shares them (`Gap.itemsWithheld`), part of `finderSelectionCount`.
    var finderWithheldCount = 0
    var gaps: Set<Gap> = []

    var isFinder: Bool { FrontmostContextRules.isFinder(app?.bundleID) }

    /// Nothing selected and nothing to say about the app.
    var hasSelection: Bool { selectedText != nil || !finderPaths.isEmpty }
}

/// How much the capture reads.
struct FrontmostContextOptions: Sendable, Hashable {
    /// Also the focused window's title (`get_frontmost_context`); the context
    /// chips need only the selection.
    var includesWindowTitle: Bool

    static let chips = FrontmostContextOptions(includesWindowTitle: false)
    static let tool = FrontmostContextOptions(includesWindowTitle: true)
}

enum FrontmostContextLimits {
    /// Selected text beyond this is not read (D5: 4,000 characters).
    static let selectedTextCharacters = TurnContext.maxSelectedTextCharacters
    /// Finder items turned into paths.
    static let finderItems = 20
    static let windowTitleCharacters = 300
}

/// Reads the frontmost app and what is selected there: the context chips when
/// the panel opens, and `get_frontmost_context`. Live: `FrontmostContextCapture`
/// on the Mac's parts; restricted debug sessions read nothing; the DEBUG
/// fake-data mode reads an invented scene; tests use a mock.
protocol FrontmostContextCapturing: Sendable {
    /// Never asks for a permission; parts it cannot read are named in `gaps`.
    func capture(_ options: FrontmostContextOptions) async -> FrontmostContext
}

/// Reads nothing (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`).
struct UnavailableFrontmostContext: FrontmostContextCapturing {
    func capture(_ options: FrontmostContextOptions) async -> FrontmostContext {
        FrontmostContext(gaps: [.noApp])
    }
}

// MARK: - Parts

/// The app in front (live: NSWorkspace, read on the main actor).
protocol FrontmostAppProviding: Sendable {
    func frontmostApp() async -> FrontmostApp?
}

/// Another app's UI as Accessibility shows it. Live: the AX API on a
/// background thread with a short messaging timeout, only once Orbit is
/// trusted; the DEBUG fake-data mode and tests build invented elements.
protocol AccessibilityReading: Sendable {
    /// Secure keyboard entry is on somewhere (a password field has the keyboard).
    func isSecureInputEnabled() -> Bool
    /// Runs `body` with the application element of `processID` off the main
    /// thread and returns what it returned; nil when there is no element.
    func read<Value: Sendable>(_ processID: pid_t,
                               _ body: @escaping @Sendable (any AccessibilityElement) -> Value) async -> Value?
}

/// One UI element of another app (live: an AXUIElement). Used on one thread
/// within one read, never kept.
protocol AccessibilityElement {
    func string(_ attribute: String) -> String?
    func element(_ attribute: String) -> (any AccessibilityElement)?
    /// A range attribute (AXSelectedTextRange): location and length in UTF-16 units.
    func range(_ attribute: String) -> NSRange?
    /// The text in `range` (the parameterized attribute AXStringForRange).
    func string(in range: NSRange) -> String?
}

/// The Accessibility names the capture uses (as macOS defines them).
enum AXName {
    static let focusedElement = "AXFocusedUIElement"
    static let focusedWindow = "AXFocusedWindow"
    static let title = "AXTitle"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let selectedText = "AXSelectedText"
    static let selectedTextRange = "AXSelectedTextRange"
    /// Role or subrole of password fields.
    static let secureTextField = "AXSecureTextField"
}

// MARK: - Rules (pure)

/// Which apps the capture treats specially.
enum FrontmostContextRules {
    static let finderBundleID = "com.apple.finder"

    /// Apps that keep passwords: their selection and window titles are never
    /// read (a revealed password is plain text there). Matched ignoring case;
    /// an entry ending in "." matches every identifier that starts with it,
    /// any other entry the identifier itself and those that continue it after
    /// a ".". The identifiers are the vendors' own (from their packages
    /// (Homebrew's cask data names each app's preferences and saved state) or
    /// their published sources); where a vendor makes nothing but password
    /// apps, or its identifier is not published, its whole domain is listed.
    static let passwordManagers = [
        // Apple: Passwörter, Schlüsselbundverwaltung.
        "com.apple.keychainaccess", "com.apple.passwords",
        // 1Password 8 and 7.
        "com.1password.", "com.agilebits.",
        "com.bitwarden.desktop",
        // KeePassXC (older versions: org.keepassx.keepassxc) and KeePassX.
        "org.keepassxc.", "org.keepassx.",
        // LastPass (com.lastpass.LastPass, com.lastpass.lastpassmacdesktop).
        "com.lastpass.",
        "com.dashlane.",
        // Enpass (in.sinew.Enpass-Desktop, from the App Store in.sinew.Enpass-Desktop.App).
        "in.sinew.",
        // NordPass, Proton Pass (me.proton.pass.electron), Keeper (com.keepersecurity.passwordmanager).
        "com.nordsec.nordpass", "me.proton.pass", "com.keepersecurity.",
        // RoboForm (com.SiberSystems.RoboForm, com.sibersystems.RoboFormMac).
        "com.sibersystems.",
        "com.hicknhacksoftware.macpass",
        // Strongbox (com.markmcguill.strongbox.mac), KeePassium (com.keepassium.ios, .ios.pro, .intune).
        "com.markmcguill.strongbox", "com.keepassium.",
        // Secrets by Outer Corner: its identifier is not published.
        "com.outercorner.",
        // Elpass (app.elpass.macos), Bramble, SafeInCloud (com.safeincloud.Safe-In-Cloud.OSX),
        // JumpCloud Password Manager (com.jumpcloud.pwm.desktop.live), KeeWeb, Buttercup, Swifty, QtPass,
        // SecureSafe (com.dswiss.securesafe.sync).
        "app.elpass.", "app.bramble.desktop", "com.safeincloud.", "com.jumpcloud.pwm.", "net.antelle.keeweb",
        "pw.buttercup.desktop", "com.electron.swifty", "org.qtpass", "com.dswiss.securesafe",
    ]

    static func isFinder(_ bundleID: String?) -> Bool {
        bundleID?.caseInsensitiveCompare(finderBundleID) == .orderedSame
    }

    static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let identifier = bundleID?.lowercased() else { return false }
        return passwordManagers.contains { entry in
            entry.hasSuffix(".") ? identifier.hasPrefix(entry) : identifier == entry || identifier.hasPrefix(entry + ".")
        }
    }
}

/// What the capture reads through Accessibility: the focused window's title
/// and the text selected in the focused element, never the text of a
/// password field (role or subrole AXSecureTextField) or while secure keyboard
/// entry is on: those are recognized before any text is asked for. A long
/// selection is read only up to the limit (AXStringForRange), not as a whole.
/// Pure over `AccessibilityElement`, so the rules are tested with invented elements.
enum FocusedContentReader {
    struct Content: Sendable, Hashable {
        var windowTitle: String?
        var selectedText: String?
        /// The selection's length (about, in characters) when only its start was read.
        var selectionLength: Int?
        /// A password field has the keyboard: its text was not read.
        var isSecure = false
    }

    static func read(_ app: any AccessibilityElement, includesWindowTitle: Bool, includesSelection: Bool,
                     secureInput: Bool, maxCharacters: Int) -> Content {
        var content = Content()
        if includesWindowTitle, let title = app.element(AXName.focusedWindow)?.string(AXName.title) {
            let line = NoteText.singleLine(title)
            content.windowTitle = line.isEmpty ? nil : Truncation.prefix(line, maxCharacters: FrontmostContextLimits.windowTitleCharacters)
        }
        guard includesSelection else { return content }
        guard !secureInput else {
            content.isSecure = true
            return content
        }
        guard let focused = app.element(AXName.focusedElement) else { return content }
        if focused.string(AXName.role) == AXName.secureTextField || focused.string(AXName.subrole) == AXName.secureTextField {
            content.isSecure = true
            return content
        }
        var text: String?
        var length: Int?
        // Twice the limit in UTF-16 units leaves room for characters made of several.
        let window = max(1, maxCharacters) * 2
        if let range = focused.range(AXName.selectedTextRange) {
            guard range.length > 0 else { return content }
            if range.length > window, let start = focused.string(in: NSRange(location: range.location, length: window)) {
                text = start
                length = range.length
            } else {
                text = focused.string(AXName.selectedText)
            }
        } else {
            text = focused.string(AXName.selectedText)
        }
        guard let raw = text.map(NoteText.cleaned), raw.contains(where: { !$0.isWhitespace }) else { return content }
        let (kept, wasCut) = Truncation.cut(raw, maxCharacters: maxCharacters)
        content.selectedText = kept
        if wasCut || length != nil {
            content.selectionLength = max(length ?? 0, raw.count)
        }
        return content
    }
}

// MARK: - Capture

/// Reads the frontmost app (`FrontmostAppProviding`), its window title and
/// selected text (Accessibility, only once Orbit is trusted: `AXIsProcessTrusted`
/// asks nothing) and in Finder the selected items (`finder-selection`, only
/// once Orbit may control Finder, read without asking). Blocking work runs on
/// a background queue, never on the main thread. Never reads Orbit itself,
/// password fields or password managers; Finder items Orbit never shares
/// (`FileAccessPolicy`) are left out, the others become "~/…" paths. Logs
/// what kind of thing it read and how long it took, never names, titles,
/// text or paths.
struct FrontmostContextCapture: FrontmostContextCapturing {
    let apps: any FrontmostAppProviding
    let accessibility: any AccessibilityReading
    let finder: FinderService
    /// Reads Accessibility and Automation: Finder without asking.
    let permissions: any PermissionAccessing
    let policy: FileAccessPolicy
    let homeDirectory: String
    let ownProcessID: pid_t

    init(apps: any FrontmostAppProviding, accessibility: any AccessibilityReading, finder: FinderService,
         permissions: any PermissionAccessing, policy: FileAccessPolicy, homeDirectory: String,
         ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.apps = apps
        self.accessibility = accessibility
        self.finder = finder
        self.permissions = permissions
        self.policy = policy
        self.homeDirectory = homeDirectory
        self.ownProcessID = ownProcessID
    }

    func capture(_ options: FrontmostContextOptions) async -> FrontmostContext {
        let start = ContinuousClock.now
        var context = FrontmostContext()
        guard let app = await apps.frontmostApp(), app.processID != ownProcessID else {
            context.gaps.insert(.noApp)
            return context
        }
        context.app = app
        if FrontmostContextRules.isPasswordManager(app.bundleID) {
            context.gaps.insert(.passwordManager)
            Self.log(context, since: start)
            return context
        }
        let isFinder = FrontmostContextRules.isFinder(app.bundleID)
        // Finder's selection comes from Finder itself; other apps' from Accessibility.
        let wantsText = !isFinder
        if options.includesWindowTitle || wantsText {
            await readAccessibility(of: app, includesWindowTitle: options.includesWindowTitle, includesSelection: wantsText,
                                    into: &context)
        }
        if isFinder, !Task.isCancelled {
            await readFinderSelection(into: &context)
        }
        Self.log(context, since: start)
        return context
    }

    private func readAccessibility(of app: FrontmostApp, includesWindowTitle: Bool, includesSelection: Bool,
                                   into context: inout FrontmostContext) async {
        let permissions = permissions
        let accessibility = accessibility
        let (isTrusted, secureInput) = await Background.run {
            (permissions.status(of: .accessibility) == .granted, accessibility.isSecureInputEnabled())
        }
        guard isTrusted else {
            context.gaps.insert(.accessibilityNotGranted)
            return
        }
        let limit = FrontmostContextLimits.selectedTextCharacters
        let content = await accessibility.read(app.processID) { element in
            FocusedContentReader.read(element, includesWindowTitle: includesWindowTitle, includesSelection: includesSelection,
                                      secureInput: secureInput, maxCharacters: limit)
        }
        guard let content else {
            context.gaps.insert(.appDidNotAnswer)
            return
        }
        context.windowTitle = content.windowTitle
        context.selectedText = content.selectedText
        context.selectedTextLength = content.selectionLength
        if content.isSecure { context.gaps.insert(.secureField) }
    }

    private func readFinderSelection(into context: inout FrontmostContext) async {
        let permissions = permissions
        guard await Background.run({ permissions.status(of: .automationFinder) }) == .granted else {
            // Running the script now would make macOS ask, never while the panel opens.
            context.gaps.insert(.finderNotPermitted)
            return
        }
        let selection: FinderService.Selection
        do {
            selection = try await finder.selection(maxItems: FrontmostContextLimits.finderItems)
        } catch {
            if !(error is CancellationError) { context.gaps.insert(.finderSelectionFailed) }
            return
        }
        let policy = policy
        let home = homeDirectory
        let shared = await Background.run {
            selection.paths.compactMap { path -> String? in
                let normalized = FilePath.normalize(path)
                guard policy.check(normalized, purpose: .list) == nil else { return nil }
                let shown = FilePath.abbreviate(normalized, home: home)
                return path.hasSuffix("/") && normalized != "/" ? shown + "/" : shown
            }
        }
        context.finderSelectionCount = selection.total
        context.finderPaths = shared
        context.finderWithheldCount = selection.paths.count - shared.count
        if context.finderWithheldCount > 0 { context.gaps.insert(.itemsWithheld) }
    }

    private static func log(_ context: FrontmostContext, since start: ContinuousClock.Instant) {
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        let parts = [context.windowTitle == nil ? nil : "title", context.selectedText == nil ? nil : "text",
                     context.finderPaths.isEmpty ? nil : "\(context.finderPaths.count) items"].compactMap { $0 }
        let gaps = context.gaps.sorted().map(\.rawValue).joined(separator: ",")
        Log.tools.info("Frontmost context: \(parts.isEmpty ? "nothing" : parts.joined(separator: ", "), privacy: .public) (gaps: \(gaps.isEmpty ? "none" : gaps, privacy: .public)) in \(milliseconds) ms")
    }
}

/// Blocking work (Accessibility, permission checks that ask the system,
/// stat calls) on a background queue, never on the main thread and never
/// holding a thread of Swift's cooperative pool.
enum Background {
    static func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - Chips

extension FrontmostContext {
    /// The context chips for what is selected: the Finder items, or the
    /// selected text, never the app alone (it goes to the model only when it
    /// calls `get_frontmost_context`). Finder items Orbit never shares are
    /// not counted among the selected ones; the chip and the model hear only
    /// how many were left out.
    func attachments() -> [ContextAttachment] {
        if !finderPaths.isEmpty {
            let withheld = max(finderWithheldCount, 0)
            let total = max((finderSelectionCount ?? finderPaths.count + withheld) - withheld, finderPaths.count)
            return [ContextAttachment(kind: .finderSelection(paths: finderPaths),
                                      label: ContextChipLabel.finderSelection(firstPath: finderPaths[0], total: total,
                                                                              withheld: withheld),
                                      selectionTotal: total > finderPaths.count ? total : nil,
                                      withheldCount: withheld > 0 ? withheld : nil)]
        }
        if let selectedText {
            return [ContextAttachment(kind: .selectedText(text: selectedText, appName: app?.name),
                                      label: ContextChipLabel.selectedText(selectedText, appName: app?.name),
                                      selectionTotal: selectedTextLength)]
        }
        return []
    }
}

/// The labels of context chips (German, localized).
enum ContextChipLabel {
    /// Characters of selected text a chip shows.
    static let excerptCharacters = 40

    /// "With selection: Angebot.pdf", "With selection: Angebot.pdf and 2 more";
    /// items Orbit never shares only by their number: "With selection:
    /// Notizen.md · 1 protected file left out".
    static func finderSelection(firstPath: String, total: Int, withheld: Int = 0) -> String {
        let name = FilePath.lastComponent(firstPath)
        let shown = name.isEmpty ? firstPath : name
        let label = total > 1 ? String(format: String(localized: "With selection: %1$@ and %2$lld more"), shown, total - 1)
            : String(format: String(localized: "With selection: %@"), shown)
        guard withheld > 0 else { return label }
        let note = withheld == 1 ? String(localized: "1 protected file left out")
            : String(format: String(localized: "%lld protected files left out"), withheld)
        return label + " · " + note
    }

    /// "With selection: “Die Lieferung erfolgt bis Freitag, 9. Oktobe…” (TextEdit)".
    static func selectedText(_ text: String, appName: String?) -> String {
        let excerpt = excerpt(text)
        if let appName = appName.map(NoteText.singleLine), !appName.isEmpty {
            return String(format: String(localized: "With selection: “%1$@” (%2$@)"), excerpt, appName)
        }
        return String(format: String(localized: "With selection: “%@”"), excerpt)
    }

    /// The start of the text on one line, whitespace collapsed, cut at a word
    /// where possible, with "…" when cut.
    static func excerpt(_ text: String) -> String {
        let collapsed = NoteText.cleaned(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let (kept, wasCut) = Truncation.cut(collapsed, maxCharacters: excerptCharacters)
        return wasCut ? kept + "…" : kept
    }
}
