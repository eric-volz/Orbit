import AppKit
import Foundation
import os
@testable import Orbit

/// A Spotlight stand-in: records every query and answers from a closure
/// (default: nothing found). Never touches the real index.
final class MockSpotlight: SpotlightQuerying, Sendable {
    typealias Responder = @Sendable (SpotlightQuery) throws -> SpotlightResults

    private let state: OSAllocatedUnfairLock<(queries: [SpotlightQuery], responder: Responder)>

    init(_ responder: @escaping Responder = { _ in .none }) {
        state = OSAllocatedUnfairLock(initialState: ([], responder))
    }

    /// Queries in the order they arrived.
    var queries: [SpotlightQuery] { state.withLock { $0.queries } }

    func respond(_ responder: @escaping Responder) {
        state.withLock { $0.responder = responder }
    }

    func search(_ query: SpotlightQuery, timeout: Duration) async throws -> SpotlightResults {
        let responder = state.withLock { state in
            state.queries.append(query)
            return state.responder
        }
        try Task.checkCancellation()
        return try responder(query)
    }

    func snapshots(of query: SpotlightQuery, timeout: Duration) -> AsyncThrowingStream<SpotlightResults, any Error> {
        AsyncThrowingStream { continuation in
            do {
                continuation.yield(try self.searchSynchronously(query))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func searchSynchronously(_ query: SpotlightQuery) throws -> SpotlightResults {
        let responder = state.withLock { state in
            state.queries.append(query)
            return state.responder
        }
        return try responder(query)
    }
}

/// Records what would have been opened or revealed. Every item exists unless
/// a test says it was moved or deleted (`remove(_:)`).
final class MockWorkspace: FileWorkspace, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (opened: [URL](), revealed: [URL](), failOpen: false,
                                                             missing: Set<String>()))

    var opened: [URL] { state.withLock { $0.opened } }
    var revealed: [URL] { state.withLock { $0.revealed } }

    func failOpening() {
        state.withLock { $0.failOpen = true }
    }

    /// The item at `url` no longer exists (moved or deleted since it was listed).
    func remove(_ url: URL) {
        state.withLock { _ = $0.missing.insert(url.standardizedFileURL.path) }
    }

    func itemExists(at url: URL) async -> Bool {
        state.withLock { !$0.missing.contains(url.standardizedFileURL.path) }
    }

    func open(_ url: URL) async throws {
        struct NoApp: Error {}
        let fail = state.withLock { state in
            if !state.failOpen { state.opened.append(url) }
            return state.failOpen
        }
        if fail { throw NoApp() }
    }

    func reveal(_ url: URL) async {
        state.withLock { $0.revealed.append(url) }
    }
}

/// Records what VoiceOver would have announced; nothing is ever posted.
@MainActor
final class RecordingAnnouncer: Announcing {
    private(set) var announcements: [String] = []
    private(set) var priorities: [NSAccessibilityPriorityLevel] = []

    nonisolated init() {}

    func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        announcements.append(text)
        priorities.append(priority)
    }
}

extension AppServices {
    /// Services for tests and snapshot environments: a Spotlight that finds
    /// nothing, a workspace that opens nothing, a file scope restricted to a
    /// folder that does not exist, a fixed app list (empty by default), no
    /// contacts, an opener that records calls, in-memory launch counts, a
    /// Quick Look panel without a window, announcements that are only
    /// recorded, an AppleScript runner that runs nothing (it answers
    /// `.disabled` unless a test says otherwise), a contact book without
    /// contacts, no Spotlight for mail, a clipboard that only records,
    /// permissions that are all granted and never asked for, calendars and
    /// reminders in memory (none by default), a Calendar/Reminders opener
    /// that only records, a photo library in memory (no photos by default),
    /// thumbnails that are tiny invented pictures, a Photos opener that only
    /// records, an app and link opener that only records, shortcuts and an
    /// output device in memory and a frontmost context the test sets (none by
    /// default); nothing on the Mac is reachable.
    static func fake(spotlight: MockSpotlight = MockSpotlight(), workspace: MockWorkspace = MockWorkspace(),
                     apps: FakeAppIndex = FakeAppIndex(), contacts: MockContactSearch = MockContactSearch(),
                     searchOpener: MockSearchOpener = MockSearchOpener(),
                     launchCounts: InMemoryLaunchCounts = InMemoryLaunchCounts(),
                     quickLookPanel: FakeQuickLookPanel = FakeQuickLookPanel(),
                     announcer: RecordingAnnouncer = RecordingAnnouncer(),
                     appleScripts: MockAppleScriptRunner = MockAppleScriptRunner(),
                     contactBook: MockContactBook = MockContactBook(),
                     mailSpotlight: MockMailSpotlight = MockMailSpotlight(available: false),
                     pasteboard: RecordingPasteboard = RecordingPasteboard(),
                     permissionAccess: MockPermissionAccess = MockPermissionAccess(),
                     calendarStore: MockCalendarStore = MockCalendarStore(),
                     calendarApps: RecordingCalendarAppOpener = RecordingCalendarAppOpener(),
                     photoLibrary: MockPhotoLibrary = MockPhotoLibrary(),
                     photoThumbnails: MockPhotoThumbnails = MockPhotoThumbnails(),
                     photosApp: RecordingPhotosAppOpener = RecordingPhotosAppOpener(),
                     appLauncher: RecordingAppLauncher = RecordingAppLauncher(),
                     shortcuts: MockShortcuts = MockShortcuts(),
                     audioVolume: MockAudioVolume = MockAudioVolume(),
                     frontmostContext: MockFrontmostContext = MockFrontmostContext()) -> AppServices {
        let home = "/Users/orbit-test"
        let scope = FileSearchScope(homeDirectory: home, restriction: FileSearchScope.invalidRestriction,
                                    listHomeFolders: { [] })
        let policy = FileAccessPolicy(homeDirectory: home, orbitDataDirectory: home + "/Library/Application Support/Orbit",
                                      restriction: FileSearchScope.invalidRestriction)
        return AppServices(spotlight: spotlight, workspace: workspace, fileScope: scope, fileAccess: policy,
                           appIndex: apps, contacts: contacts, searchOpener: searchOpener, launchCounts: launchCounts,
                           quickLookPanel: quickLookPanel, announcer: announcer, appleScripts: appleScripts,
                           contactBook: contactBook, mailSpotlight: mailSpotlight, pasteboard: pasteboard,
                           permissionAccess: permissionAccess, calendarStore: calendarStore, calendarApps: calendarApps,
                           photoLibrary: photoLibrary, photoThumbnails: photoThumbnails, photosApp: photosApp,
                           appLauncher: appLauncher, shortcuts: shortcuts, audioVolume: audioVolume,
                           frontmostContext: frontmostContext)
    }
}

/// Files for tests, in a fresh temporary folder that `remove()` deletes.
struct TemporaryFolder {
    let url: URL

    init(_ name: String = "orbit-files") throws {
        let base = URL(fileURLWithPath: FilePath.canonical(NSTemporaryDirectory()), isDirectory: true)
        url = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path }

    @discardableResult
    func write(_ relativePath: String, _ contents: String, encoding: String.Encoding = .utf8) throws -> URL {
        guard let data = contents.data(using: encoding) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return try write(relativePath, data: data)
    }

    @discardableResult
    func write(_ relativePath: String, data: Data) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func makeFolder(_ relativePath: String) throws -> URL {
        let folder = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
