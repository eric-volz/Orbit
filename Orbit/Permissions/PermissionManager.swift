import AppKit
import Foundation
import Observation
import os

/// How Orbit reads and requests macOS permissions. Live: `LivePermissionAccess`;
/// tests, DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE and the DEBUG
/// fake-data mode use stand-ins that never touch the system.
protocol PermissionAccessing: Sendable {
    /// The current status. Never asks the user. May block briefly (the Apple
    /// Events check talks to the system), so call it off the main thread.
    func status(of permission: PermissionKind) -> PermissionStatus
    /// Asks macOS for the permission: its prompt appears if the user has not
    /// decided yet. Only after the user clicked a button for it. Returns the
    /// status afterwards.
    func request(_ permission: PermissionKind) async -> PermissionStatus
    /// Opens the permission's page in System Settings.
    func openSystemSettings(for permission: PermissionKind) async
}

/// Permissions without the system: fixed statuses (by default all granted);
/// asking changes nothing and System Settings never opens. The default of
/// `AppServices` (tests) and of DEBUG sessions restricted with
/// ORBIT_DEBUG_FILE_SCOPE, whose personal-data tools are off anyway.
struct FixedPermissionAccess: PermissionAccessing {
    var statuses: [PermissionKind: PermissionStatus]
    /// The status of every permission not in `statuses`.
    var otherwise: PermissionStatus

    init(_ statuses: [PermissionKind: PermissionStatus] = [:], otherwise: PermissionStatus = .granted) {
        self.statuses = statuses
        self.otherwise = otherwise
    }

    func status(of permission: PermissionKind) -> PermissionStatus {
        statuses[permission] ?? otherwise
    }

    func request(_ permission: PermissionKind) async -> PermissionStatus {
        status(of: permission)
    }

    func openSystemSettings(for permission: PermissionKind) async {}
}

extension PermissionKind {
    /// The order in Settings and the onboarding: what Orbit does today first.
    static let displayOrder: [PermissionKind] = [
        .automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
        .automationPhotos, .automationFinder, .automationSystemEvents, .accessibility, .fullDiskAccess,
    ]

    /// Only in Settings → Permissions, never an onboarding step: Full Disk
    /// Access is optional, and macOS asks for Automation: System Events and
    /// Automation: Photos on first use anyway.
    static let settingsOnly: Set<PermissionKind> = [.fullDiskAccess, .automationSystemEvents, .automationPhotos]

    /// Apple Events to another app.
    var isAutomation: Bool { automationTargetBundleID != nil }

    /// Whether asking macOS can still change `status` (its prompt, or for
    /// Accessibility its dialog, appears). Otherwise only System Settings helps.
    /// An Apple Events permission reads `.unknown` while its app does not run;
    /// asking starts the app first, so macOS can answer (and ask if needed).
    func canRequest(from status: PermissionStatus) -> Bool {
        switch self {
        case .fullDiskAccess:
            false
        case .accessibility:
            status != .granted && status != .restricted
        default:
            isAutomation ? status == .notDetermined || status == .unknown : status == .notDetermined
        }
    }
}

/// The permission states Orbit works with, kept current without ever asking
/// the user (`PermissionStatusProviding` for the agent loop and the tool
/// registry), plus asking macOS and opening System Settings for the settings
/// tab and the onboarding.
///
/// Reading runs off the main thread (`PermissionAccessing.status(of:)` may
/// block) and lands in a lock, so `status(of:)` is a cheap synchronous lookup.
/// A permission not read yet is `.unknown`, which keeps its tools available
/// (macOS asks on first use). Orbit reads again at `start()`, when the panel
/// opens or Orbit becomes active (e.g. back from System Settings) unless it
/// read moments ago, when an automation target such as Mail starts or quits
/// (macOS only answers for running apps), after a tool that needs a permission
/// ran (`permissionsMayHaveChanged`), and whenever Settings or the onboarding
/// show the permissions.
@MainActor
@Observable
final class PermissionManager: PermissionStatusProviding {
    /// How long a reading counts as current for `refreshIfStale()`.
    static let staleInterval: TimeInterval = 3

    /// The permissions Orbit uses, in display order (see `permissions(for:features:)`):
    /// those of the tools and their cards, plus `featurePermissions`.
    var permissions: [PermissionKind] {
        PermissionKind.displayOrder.filter { basePermissions.contains($0) || featurePermissions.contains($0) }
    }
    /// The permissions of the tools and their cards (fixed).
    let basePermissions: [PermissionKind]
    /// Permissions of features the user can switch off, listed (and read) only
    /// while their feature is on: Accessibility and Automation: Finder for the
    /// context of a request (`contextPermissions`) while "Auswahl beim Öffnen
    /// übernehmen" or `get_frontmost_context` is on. Set by `AppEnvironment`.
    var featurePermissions: Set<PermissionKind> = [] {
        didSet {
            let added = featurePermissions.subtracting(oldValue)
            guard !added.isEmpty else { return }
            let kinds = PermissionKind.displayOrder.filter(added.contains)
            Task { await refresh(kinds) }
        }
    }
    /// The permissions some tool needs; tools are switched off without them.
    let toolPermissions: [PermissionKind]
    /// The last reading of each permission; missing until it was read.
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// Permissions whose request is running (macOS's prompt may be open).
    private(set) var requesting: Set<PermissionKind> = []

    let access: any PermissionAccessing
    /// The statuses for `status(of:)`, readable from any thread.
    private nonisolated let current = OSAllocatedUnfairLock<[PermissionKind: PermissionStatus]>(initialState: [:])
    @ObservationIgnored private var readCounter = 0
    /// The newest reading (by counter) per permission: older results that
    /// arrive later are dropped.
    @ObservationIgnored private var newestReading: [PermissionKind: Int] = [:]
    @ObservationIgnored private var lastRoutineRead: Date?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    init(access: any PermissionAccessing, permissions: [PermissionKind], toolPermissions: [PermissionKind]? = nil) {
        self.access = access
        self.basePermissions = permissions
        self.toolPermissions = toolPermissions ?? permissions.filter { $0 != .fullDiskAccess }
    }

    /// The manager for these tools: their permissions plus the optional ones.
    convenience init(access: any PermissionAccessing, tools: [ToolInfo]) {
        let required = Set(tools.flatMap(\.requiredPermissions))
        self.init(access: access, permissions: Self.permissions(for: tools),
                  toolPermissions: PermissionKind.displayOrder.filter(required.contains))
    }

    /// The permissions the tools need, in display order, plus those of their
    /// cards and options: Full Disk Access when the mail tools exist (optional:
    /// with it, Spotlight may show Mail's messages to Orbit, which makes mail
    /// search faster), and Automation: Photos when the photo tools exist (a
    /// photo card shows its photo in Photos; search_photos does not need it,
    /// so it never switches the tool off), and `features`, the permissions of
    /// features that are on (`contextPermissions`).
    nonisolated static func permissions(for tools: [ToolInfo], features: Set<PermissionKind> = []) -> [PermissionKind] {
        var used = Set(tools.flatMap(\.requiredPermissions)).union(features)
        if used.contains(.automationMail) { used.insert(.fullDiskAccess) }
        if used.contains(.photos) { used.insert(.automationPhotos) }
        return PermissionKind.displayOrder.filter(used.contains)
    }

    /// What the context of a request reads, that is the selected text and window
    /// titles (Accessibility) and the Finder selection (Automation: Finder),
    /// while the context chips ("Use the selection when opening") or
    /// `get_frontmost_context` are on. Neither switches a tool off: without
    /// them, that part of the context is left out.
    nonisolated static func contextPermissions(capturesSelection: Bool, contextToolEnabled: Bool) -> Set<PermissionKind> {
        capturesSelection || contextToolEnabled ? [.automationFinder, .accessibility] : []
    }

    /// The permissions the onboarding asks for one by one (the
    /// `settingsOnly` ones only appear in Settings).
    var onboardingPermissions: [PermissionKind] {
        permissions.filter { !PermissionKind.settingsOnly.contains($0) }
    }

    // MARK: PermissionStatusProviding

    nonisolated func status(of permission: PermissionKind) -> PermissionStatus {
        current.withLock { $0[permission] } ?? .unknown
    }

    nonisolated func permissionsMayHaveChanged(_ permissions: [PermissionKind]) {
        guard !permissions.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.refresh(permissions)
        }
    }

    // MARK: Reading

    /// Reads all permissions now and again on the occasions listed above.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    self?.appDidLaunchOrQuit(bundleIdentifier: bundleID)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfStale()
            }
        })
        lastRoutineRead = now()
        Task { await refresh() }
    }

    /// Stops the observers of `start()`.
    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    /// Reads the permissions again (all by default), off the main thread.
    func refresh(_ kinds: [PermissionKind]? = nil) async {
        var seen = Set<PermissionKind>()
        let kinds = (kinds ?? permissions).filter { seen.insert($0).inserted }
        guard !kinds.isEmpty else { return }
        let reading = startReading(kinds)
        let start = ContinuousClock.now
        let results = await Self.read(kinds, from: access)
        apply(results, reading: reading)
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        Log.permissions.debug("Read \(kinds.count) permissions in \(milliseconds) ms")
    }

    /// The panel opens or Orbit becomes active: reads the permissions the
    /// tools need again, and those of the features that are on (back from
    /// System Settings, where the user may have allowed Accessibility),
    /// unless that happened moments ago. Full Disk Access is not probed.
    func refreshIfStale() {
        let now = now()
        if let lastRoutineRead, now.timeIntervalSince(lastRoutineRead) < Self.staleInterval { return }
        lastRoutineRead = now
        let kinds = routinePermissions
        Task { await refresh(kinds) }
    }

    /// What `refreshIfStale()` reads: the tools' permissions and the features', in display order.
    var routinePermissions: [PermissionKind] {
        PermissionKind.displayOrder.filter { kind in
            kind != .fullDiskAccess && (toolPermissions.contains(kind) || featurePermissions.contains(kind))
        }
    }

    /// An app started or quit: Apple Events permissions for it can be read
    /// only while it runs.
    func appDidLaunchOrQuit(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        let kinds = permissions.filter { kind in
            kind.automationTargetBundleID.map { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame } ?? false
        }
        guard !kinds.isEmpty else { return }
        Task { await refresh(kinds) }
    }

    nonisolated private static func read(_ kinds: [PermissionKind],
                                         from access: any PermissionAccessing) async -> [PermissionKind: PermissionStatus] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var results: [PermissionKind: PermissionStatus] = [:]
                for kind in kinds {
                    results[kind] = access.status(of: kind)
                }
                continuation.resume(returning: results)
            }
        }
    }

    // MARK: Asking

    /// Asks macOS for `permission`, only after the user clicked "Allow…".
    func request(_ permission: PermissionKind) async {
        guard !requesting.contains(permission) else { return }
        requesting.insert(permission)
        Log.permissions.info("Requesting \(permission.rawValue, privacy: .public)")
        let status = await access.request(permission)
        requesting.remove(permission)
        // The answer is newer than any reading that started while macOS asked.
        apply([permission: status], reading: startReading([permission]))
    }

    func openSystemSettings(for permission: PermissionKind) async {
        Log.permissions.info("Opening System Settings for \(permission.rawValue, privacy: .public)")
        await access.openSystemSettings(for: permission)
    }

    // MARK: Results

    private func startReading(_ kinds: [PermissionKind]) -> Int {
        readCounter += 1
        for kind in kinds {
            newestReading[kind] = readCounter
        }
        return readCounter
    }

    private func apply(_ results: [PermissionKind: PermissionStatus], reading: Int) {
        var updated = statuses
        for (kind, status) in results where newestReading[kind] == reading {
            let merged = Self.merged(previous: statuses[kind], reading: status, for: kind)
            if statuses[kind] != merged {
                Log.permissions.info("\(kind.rawValue, privacy: .public): \(merged.rawValue, privacy: .public)")
            }
            updated[kind] = merged
        }
        guard updated != statuses else { return }
        statuses = updated
        let snapshot = updated
        current.withLock { $0 = snapshot }
    }

    /// An Apple Events permission reads `.unknown` while its app does not run,
    /// which says nothing new: "granted" and "not asked yet" stay (only Orbit's
    /// own prompt changes the latter; a revocation in System Settings shows up
    /// as a refusal on the next use, which reads again). "Denied" does not
    /// stay: the user may allow Orbit in System Settings meanwhile, and a
    /// stale "denied" would keep the tools off.
    nonisolated static func merged(previous: PermissionStatus?, reading: PermissionStatus,
                                   for kind: PermissionKind) -> PermissionStatus {
        guard kind.isAutomation, reading == .unknown, let previous else { return reading }
        switch previous {
        case .granted, .notDetermined: return previous
        case .denied, .restricted, .unknown, .writeOnly: return reading
        }
    }
}
