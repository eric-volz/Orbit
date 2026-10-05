#if DEBUG
import Foundation
import os

/// DEBUG only: invented personal data for automated end-to-end runs.
///
/// `ORBIT_DEBUG_FAKE_PERSONAL_DATA=<absolute folder>` (read once at launch)
/// makes `AppServices.live()` use, instead of the user's data:
/// - `FakeAppleScriptRunner`: answers Orbit's Notes scripts from `notes.json`
///   and its Mail scripts from `mails.json` (see `FakeMailData`) in that folder
///   with exactly the JSON the scripts print (the same Codable types); Notes
///   and Mail are never contacted;
/// - `FakeContactBook` and `FakeContactSearch`: the contacts in
///   `contacts.json`, for `search_contacts`, the user's name ("isMe") and
///   instant search.
/// - `FakeCalendarStore`: the events and reminders in `events.json` and
///   `reminders.json` (see `FakeCalendarData`), with dates relative to the
///   launch day; EventKit is never touched.
/// - `FakePhotoLibrary` and `FakePhotoThumbnails`: the photos in
///   `photos.json` (see `FakePhotoData`) with dates relative to the launch day
///   and invented placeholder thumbnails; PhotoKit is never touched.
/// - `FakeShortcuts`, `FakeAppLauncher`, `FakeAudioVolume` and the context
///   capture on an invented frontmost app (see `FakeSystemData`:
///   `shortcuts.json`, `frontmost.json`, `system.json`); no shortcut runs, no
///   app or link opens, no setting changes, no other app is read.
/// - `FakePermissionAccess`: Contacts as `contacts.json` says, Automation:
///   Notes and Mail as `notes.json` and `mails.json` say, Calendars and
///   Reminders as `events.json` and `reminders.json` say (`"access"`), Photos
///   and Automation: Photos as `photos.json` says (`"access"`,
///   `"automation"`), Accessibility and Automation: Finder as `frontmost.json`
///   says, Automation: System Events as `system.json` says, everything else
///   granted; asking and opening System Settings are only recorded.
/// Notes created or opened, mail drafts, reply windows, what Orbit would put
/// on the clipboard (`FakePasteboard`), created events and reminders, what
/// cards would show in Calendar, Reminders or Photos and the "open Photos"
/// fallback are recorded instead (a created note, event or reminder can be
/// found afterwards); `orbitctl state` reports them under "fakePersonalData". Mail search runs as without Spotlight. A
/// value that is not a folder, or a broken file, gives empty data and an error
/// in the state, never the real data.
///
/// `notes.json` (every key optional):
/// `{"defaultFolder": "Notizen", "folders": ["Notizen", "Rezepte"], "trashFolder": "Zuletzt gelöscht",
///   "automation": "granted" | "denied", "notes": [{"id": "x-coredata://…/ICNote/p1", "name": "…",
///   "folder": "Notizen", "created": "-30d", "modified": "2026-09-28T18:30:00+02:00", "locked": false,
///   "text": "Title\nFirst line"}]}`: a note has `text` (its first line is the title) or an HTML `body`.
///
/// `contacts.json`: `{"access": "authorized" | "notDetermined" | "denied", "contacts": [{"id": "…",
///   "name": "Lisa Beispiel", "organization": "…", "emails": [{"label": "Arbeit", "value": "…"}],
///   "phones": [{"label": "Mobil", "value": "…"}], "isMe": false}]}`; with "notDetermined", asking for
///   access succeeds (like a user who clicks Allow).
///
/// Dates: ISO 8601, or relative to the launch: "now", "-2d", "-3h", "-15m".
final class FakePersonalData: Sendable {
    static let variable = "ORBIT_DEBUG_FAKE_PERSONAL_DATA"
    static let notesFile = "notes.json"
    static let contactsFile = "contacts.json"
    /// Script runs kept for `orbitctl state`.
    static let maxRecordedRuns = 200

    struct Note: Sendable, Hashable {
        var id: String
        var name: String
        var folder: String
        var created: Date
        var modified: Date
        var isLocked: Bool
        /// HTML, like Notes' `body`.
        var body: String
    }

    private struct State: Sendable {
        var notes: [Note]
        var createdNoteIDs: [String] = []
        var openedNotes: [JSONValue] = []
        var scriptRuns: [String] = []
        var contactsAccess: ContactsAccess
        var accessRequests = 0
        var permissionRequests: [String] = []
        var openedSystemSettings: [String] = []
    }

    let directory: String
    let folders: [String]
    let defaultFolder: String
    let trashFolder: String?
    let automationDenied: Bool
    let contacts: [ContactRecord]
    let meIdentifier: String?
    /// The invented mail (`mails.json`).
    let mail: FakeMailData
    /// The invented events and reminders (`events.json`, `reminders.json`).
    let calendar: FakeCalendarData
    /// The invented photos (`photos.json`).
    let photos: FakePhotoData
    /// The invented shortcuts, frontmost app and system settings
    /// (`shortcuts.json`, `frontmost.json`, `system.json`).
    let system: FakeSystemData
    /// Problems with the folder or its files (also in the state).
    let errors: [String]
    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> Date

    /// The data named by ORBIT_DEBUG_FAKE_PERSONAL_DATA, or nil when it is not set.
    static func fromEnvironment(_ environment: [String: String], now: @escaping @Sendable () -> Date = { Date() }) -> FakePersonalData? {
        guard let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let data = FakePersonalData(directory: value, now: now)
        Log.app.notice("Fake personal data: \(data.state.withLock { $0.notes.count }) notes, \(data.contacts.count) contacts, \(data.calendar.eventCount) events, \(data.calendar.reminderCount) reminders, \(data.photos.visibleCount) photos, \(data.system.shortcuts.count) shortcuts, \(data.system.scenes.count) frontmost scenes, \(data.errors.count) errors")
        return data
    }

    init(directory: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        let launch = now()
        var errors: [String] = []
        var isDirectory: ObjCBool = false
        let folderExists = directory.hasPrefix("/") && FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
            && isDirectory.boolValue
        if !folderExists {
            errors.append("\(Self.variable) is not an absolute path to a folder; there is no fake data.")
        }
        let folderURL = URL(fileURLWithPath: directory, isDirectory: true)

        let notesFile: NotesFile = folderExists ? Self.decode(NotesFile.self, folderURL.appendingPathComponent(Self.notesFile), errors: &errors) ?? NotesFile() : NotesFile()
        var notes: [Note] = []
        for (index, entry) in (notesFile.notes ?? []).enumerated() {
            notes.append(Self.note(from: entry, number: index + 1, defaultFolder: notesFile.defaultFolder ?? "Notizen",
                                   now: launch, errors: &errors))
        }
        let defaultFolder = notesFile.defaultFolder ?? notesFile.folders?.first ?? "Notizen"
        var folders = notesFile.folders ?? []
        for name in [defaultFolder] + notes.map(\.folder) + [notesFile.trashFolder].compactMap({ $0 }) where !folders.contains(name) {
            folders.append(name)
        }
        self.folders = folders
        self.defaultFolder = defaultFolder
        trashFolder = notesFile.trashFolder
        automationDenied = notesFile.automation?.lowercased() == "denied"

        let contactsFile: ContactsFile = folderExists ? Self.decode(ContactsFile.self, folderURL.appendingPathComponent(Self.contactsFile), errors: &errors) ?? ContactsFile() : ContactsFile()
        var contacts: [ContactRecord] = []
        var me: String?
        for (index, entry) in (contactsFile.contacts ?? []).enumerated() {
            let identifier = entry.id ?? "orbit-fake-contact-\(index + 1)"
            let organization = entry.organization.flatMap { $0.isEmpty || $0 == entry.name ? nil : $0 }
            contacts.append(ContactRecord(identifier: identifier, name: entry.name, organization: organization,
                                          emails: entry.emails ?? [], phones: entry.phones ?? []))
            if entry.isMe == true, me == nil { me = identifier }
        }
        self.contacts = contacts
        meIdentifier = me
        mail = FakeMailData(folder: folderExists ? folderURL : nil, now: launch, errors: &errors)
        calendar = FakeCalendarData(folder: folderExists ? folderURL : nil, now: launch, errors: &errors)
        photos = FakePhotoData(folder: folderExists ? folderURL : nil, now: launch, errors: &errors)
        system = FakeSystemData(folder: folderExists ? folderURL : nil, errors: &errors)
        let access: ContactsAccess = switch contactsFile.access?.lowercased() {
        case "denied": .denied
        case "notdetermined": .notDetermined
        default: .authorized
        }
        self.errors = errors
        state = OSAllocatedUnfairLock(initialState: State(notes: notes, contactsAccess: access))
    }

    // MARK: Scripts

    /// Answers one of Orbit's scripts like the real script would.
    func runScript(_ name: String, arguments: [String]) throws -> String {
        state.withLock { state in
            state.scriptRuns.append(name)
            if state.scriptRuns.count > Self.maxRecordedRuns { state.scriptRuns.removeFirst() }
        }
        if let answer = try mail.runScript(name, arguments: arguments) {
            return answer
        }
        if let answer = try photos.runScript(name, arguments: arguments) {
            return answer
        }
        if let answer = try system.runScript(name, arguments: arguments) {
            return answer
        }
        switch name {
        case NotesService.searchScript.name: return try searchNotes(arguments)
        case NotesService.readScript.name: return try readNote(arguments)
        case NotesService.createScript.name: return try createNote(arguments)
        case NotesService.openScript.name: return try openNote(arguments)
        default: throw AppleScriptError.scriptMissing(name)
        }
    }

    private func searchNotes(_ arguments: [String]) throws -> String {
        try checkNotes(arguments, count: 5)
        let terms = Self.lines(arguments[0])
        let folder = arguments[1]
        let limit = Int(arguments[2]) ?? 20
        let startLength = Int(arguments[3]) ?? 400
        var excluded = Set(Self.lines(arguments[4]))
        if let trashFolder { excluded.insert(trashFolder) }
        var candidates = state.withLock { $0.notes }
        if !folder.isEmpty {
            let matching = Set(folders.filter { $0.caseInsensitiveCompare(folder) == .orderedSame })
            guard !matching.isEmpty else { return try Self.encode(ScriptFailure(error: "folderNotFound", folders: folders)) }
            candidates = candidates.filter { matching.contains($0.folder) }
        }
        candidates = candidates.filter { note in
            !excluded.contains(note.folder) && terms.allSatisfy { term in
                note.name.range(of: term, options: .caseInsensitive) != nil
                    || (!note.isLocked && Self.plaintext(note).range(of: term, options: .caseInsensitive) != nil)
            }
        }
        candidates.sort { $0.modified > $1.modified }
        let rows = candidates.prefix(max(0, limit)).map { note in
            NoteSummary(id: note.id, name: note.name, folder: note.folder, modified: note.modified, isLocked: note.isLocked,
                        start: note.isLocked ? "" : String(Self.plaintext(note).prefix(max(0, startLength))))
        }
        // Like the script: nothing in all folders, only their names (the trash left out, as Orbit does).
        let folderNames = candidates.isEmpty && folder.isEmpty ? folders.filter { !excluded.contains($0) } : nil
        return try Self.encode(NotesSearchResult(notes: Array(rows), total: candidates.count, folders: folderNames))
    }

    private func readNote(_ arguments: [String]) throws -> String {
        try checkNotes(arguments, count: 2)
        guard let note = note(withID: arguments[0]) else { return try Self.encode(ScriptFailure(error: "notFound")) }
        let body = note.isLocked ? "" : Self.withoutEmbeddedData(note.body)
        return try Self.encode(NoteContent(id: note.id, name: note.name, folder: note.folder, created: note.created,
                                           modified: note.modified, isLocked: note.isLocked,
                                           body: String(body.prefix(max(0, Int(arguments[1]) ?? 0))), bodyLength: body.count))
    }

    private func createNote(_ arguments: [String]) throws -> String {
        try checkNotes(arguments, count: 3)
        let html = arguments[0]
        let excluded = Set(Self.lines(arguments[2]) + [trashFolder].compactMap { $0 })
        let target: String
        if arguments[1].isEmpty {
            target = defaultFolder
        } else if let match = folders.first(where: { $0.caseInsensitiveCompare(arguments[1]) == .orderedSame && !excluded.contains($0) }) {
            target = match
        } else {
            return try Self.encode(ScriptFailure(error: "folderNotFound", folders: folders.filter { !excluded.contains($0) }))
        }
        let created = now()
        let name = NoteText.plainText(fromHTML: html).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let note = state.withLock { state -> Note in
            let note = Note(id: "x-coredata://ORBIT-FAKE/ICNote/c\(state.createdNoteIDs.count + 1)", name: name,
                            folder: target, created: created, modified: created, isLocked: false, body: html)
            state.notes.append(note)
            state.createdNoteIDs.append(note.id)
            return note
        }
        return try Self.encode(CreatedNote(id: note.id, name: note.name, folder: note.folder))
    }

    private func openNote(_ arguments: [String]) throws -> String {
        try checkNotes(arguments, count: 1)
        guard let note = note(withID: arguments[0]) else { return try Self.encode(ScriptFailure(error: "notFound")) }
        state.withLock { $0.openedNotes.append(["id": .string(note.id), "name": .string(note.name)]) }
        return try Self.encode(OpenedNote(opened: true, name: note.name))
    }

    private func checkNotes(_ arguments: [String], count: Int) throws {
        if automationDenied { throw AppleScriptError.notAuthorized(.notes) }
        guard arguments.count >= count else {
            throw AppleScriptError.failed(number: 1000, message: "The script expects \(count) arguments")
        }
    }

    private func note(withID id: String) -> Note? {
        state.withLock { $0.notes.first { $0.id == id } }
    }

    // MARK: Contacts

    var contactsAccess: ContactsAccess {
        state.withLock { $0.contactsAccess }
    }

    /// Asking for access: the fake user agrees.
    func requestContactsAccess() -> ContactsAccess {
        state.withLock { state in
            state.accessRequests += 1
            if state.contactsAccess == .notDetermined { state.contactsAccess = .authorized }
            return state.contactsAccess
        }
    }

    // MARK: Permissions

    /// The fake permissions: Contacts as `contacts.json` says, Automation: Notes
    /// and Mail as `notes.json` and `mails.json` say, Calendars and Reminders
    /// as `events.json` and `reminders.json` say, Photos and Automation: Photos
    /// as `photos.json` says, everything else granted.
    func permissionStatus(_ permission: PermissionKind) -> PermissionStatus {
        switch permission {
        case .contacts: LivePermissionAccess.status(contactsAccess)
        case .automationNotes: automationDenied ? .denied : .granted
        case .automationMail: mail.automationDenied ? .denied : .granted
        case .calendars: LivePermissionAccess.status(calendar.access(to: .events))
        case .reminders: LivePermissionAccess.status(calendar.access(to: .reminders))
        case .photos: LivePermissionAccess.status(photos.access())
        case .automationPhotos: photos.automationDenied ? .denied : .granted
        case .accessibility: system.accessibility
        case .automationFinder: system.finderAutomation
        case .automationSystemEvents: system.systemEventsAutomation
        default: .granted
        }
    }

    /// "Allow…": recorded; for Contacts, Calendars, Reminders and Photos the
    /// fake user agrees while undecided (like a click on Allow).
    func requestPermission(_ permission: PermissionKind) -> PermissionStatus {
        state.withLock { $0.permissionRequests.append(permission.rawValue) }
        switch permission {
        case .contacts: _ = requestContactsAccess()
        case .calendars: _ = calendar.requestAccess(to: .events)
        case .reminders: _ = calendar.requestAccess(to: .reminders)
        case .photos: _ = photos.requestAccess()
        case .automationFinder: _ = system.requestFinderAutomation()
        default: break
        }
        return permissionStatus(permission)
    }

    /// "System Settings…": recorded, never opened.
    func recordOpenedSystemSettings(_ permission: PermissionKind) {
        state.withLock { $0.openedSystemSettings.append(permission.rawValue) }
    }

    // MARK: State

    /// What `orbitctl state` shows: counts, errors and what Orbit did.
    func stateSummary() -> JSONValue {
        let snapshot = state.withLock { $0 }
        let created = snapshot.createdNoteIDs.compactMap { id in snapshot.notes.first { $0.id == id } }
        let summary: JSONValue = [
            "directory": .string(directory),
            "errors": .array(errors.map(JSONValue.string)),
            "notes": .number(Double(snapshot.notes.count)),
            "contacts": .number(Double(contacts.count)),
            "notesAutomation": .string(automationDenied ? "denied" : "granted"),
            "contactsAccess": .string(Self.name(of: snapshot.contactsAccess)),
            "contactsAccessRequests": .number(Double(snapshot.accessRequests)),
            "createdNotes": .array(created.map { note in
                ["id": .string(note.id), "name": .string(note.name), "folder": .string(note.folder),
                 "text": .string(NoteText.plainText(fromHTML: note.body))]
            }),
            "openedNotes": .array(snapshot.openedNotes),
            "scriptRuns": .array(snapshot.scriptRuns.map(JSONValue.string)),
            "permissionRequests": .array(snapshot.permissionRequests.map(JSONValue.string)),
            "openedSystemSettings": .array(snapshot.openedSystemSettings.map(JSONValue.string)),
        ]
        guard case .object(var object) = summary else { return summary }
        object.merge(mail.stateSummary()) { current, _ in current }
        object.merge(calendar.stateSummary()) { current, _ in current }
        object.merge(photos.stateSummary()) { current, _ in current }
        object.merge(system.stateSummary()) { current, _ in current }
        return .object(object)
    }

    private static func name(of access: ContactsAccess) -> String {
        switch access {
        case .authorized: "authorized"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .unavailable: "unavailable"
        }
    }

    // MARK: Files

    private struct NotesFile: Decodable {
        struct Entry: Decodable {
            var id: String?
            var name: String?
            var folder: String?
            var created: String?
            var modified: String?
            var locked: Bool?
            var text: String?
            var body: String?
        }

        var defaultFolder: String?
        var folders: [String]?
        var trashFolder: String?
        var automation: String?
        var notes: [Entry]?
    }

    private struct ContactsFile: Decodable {
        struct Entry: Decodable {
            var id: String?
            var name: String
            var organization: String?
            var emails: [ContactRecord.Value]?
            var phones: [ContactRecord.Value]?
            var isMe: Bool?
        }

        var access: String?
        var contacts: [Entry]?
    }

    /// The answers the scripts give instead of a result.
    private struct ScriptFailure: Encodable {
        var error: String
        var folders: [String]?
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ url: URL, errors: inout [String]) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            errors.append("\(url.lastPathComponent) could not be read: \(error)")
            return nil
        }
    }

    private static func note(from entry: NotesFile.Entry, number: Int, defaultFolder: String, now: Date,
                             errors: inout [String]) -> Note {
        let body: String
        if let html = entry.body {
            body = html
        } else {
            let lines = (entry.text ?? entry.name ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            body = NoteText.html(title: lines.first.map(String.init) ?? "", body: lines.dropFirst().joined(separator: "\n"))
        }
        let name = entry.name ?? NoteText.plainText(fromHTML: body).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Note(id: entry.id ?? "x-coredata://ORBIT-FAKE/ICNote/p\(number)", name: name,
                    folder: entry.folder ?? defaultFolder,
                    created: date(entry.created, now: now, errors: &errors),
                    modified: date(entry.modified ?? entry.created, now: now, errors: &errors),
                    isLocked: entry.locked ?? false, body: body)
    }

    /// ISO 8601, "now", or an offset from now: "-2d", "-3h", "-15m" (also with "+").
    static func date(_ text: String?, now: Date, errors: inout [String]) -> Date {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "now" else { return now }
        if let unit = text.last, let factor = ["d": 86_400.0, "h": 3_600.0, "m": 60.0][String(unit)],
           let amount = Double(text.dropLast()) {
            return now.addingTimeInterval(amount * factor)
        }
        if let parsed = FlexibleDate.parse(text, timeZone: .current) { return parsed.date }
        errors.append("'\(text)' is not a date (ISO 8601, \"now\" or an offset such as \"-2d\").")
        return now
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    static func plaintext(_ note: Note) -> String {
        NoteText.plainText(fromHTML: note.body)
    }

    /// Like notes-read: the body without the data of embedded images and files
    /// (data: URLs in src, srcset, data and href attributes), measured and cut after that.
    static func withoutEmbeddedData(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?i)\b(src|srcset|data|href)\s*=\s*("data:[^"]*"|'data:[^']*'|data:[^\s"'>]*)"#,
                                  with: "$1=\"\"", options: .regularExpression)
    }

    static func encode(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

/// Orbit's scripts answered from `FakePersonalData` (DEBUG fake-data mode).
struct FakeAppleScriptRunner: AppleScriptRunning {
    let data: FakePersonalData

    func run(_ script: AppleScript, arguments: [String]) async throws -> String {
        try LiveAppleScriptRunner.validate(arguments)
        try Task.checkCancellation()
        return try data.runScript(script.name, arguments: arguments)
    }
}

/// Mail cards' message links in the DEBUG fake-data mode: recorded, never opened.
struct FakeMessageLinkOpener: MessageLinkOpening {
    let data: FakePersonalData

    func open(_ url: URL) async throws {
        data.mail.recordOpenedMessage(url)
    }
}

/// The clipboard in the DEBUG fake-data mode: the text is recorded
/// (`clipboard`, and as a reply's `text`), the user's clipboard is never touched.
struct FakePasteboard: PasteboardWriting {
    let data: FakePersonalData

    func write(_ text: String) async -> Bool {
        data.mail.recordClipboard(text)
        return true
    }
}

/// macOS's permissions in the DEBUG fake-data mode: from the fake data; nothing
/// is asked for and System Settings never opens (both are recorded).
struct FakePermissionAccess: PermissionAccessing {
    let data: FakePersonalData

    func status(of permission: PermissionKind) -> PermissionStatus {
        data.permissionStatus(permission)
    }

    func request(_ permission: PermissionKind) async -> PermissionStatus {
        data.requestPermission(permission)
    }

    func openSystemSettings(for permission: PermissionKind) async {
        data.recordOpenedSystemSettings(permission)
    }
}

/// The invented contacts as the contact book (DEBUG fake-data mode).
struct FakeContactBook: ContactBook {
    let data: FakePersonalData

    func access() -> ContactsAccess { data.contactsAccess }

    func requestAccess() async -> ContactsAccess { data.requestContactsAccess() }

    func search(_ query: String, limit: Int) async throws -> [ContactRecord] {
        guard access() == .authorized else { return [] }
        let kind = ContactMatching.Kind(query)
        return ContactMatching.rank(data.contacts.filter { ContactMatching.matches($0, kind) }, for: kind, limit: limit)
    }

    func me() async throws -> ContactRecord? {
        guard access() == .authorized, let id = data.meIdentifier else { return nil }
        return data.contacts.first { $0.identifier == id }
    }
}

/// The invented contacts in instant search (DEBUG fake-data mode), like the
/// live search: by name, only with access.
struct FakeContactSearch: ContactSearching {
    let data: FakePersonalData

    func search(_ text: String, limit: Int) async throws -> [ContactHit] {
        guard data.contactsAccess == .authorized else { return [] }
        let query = FuzzyMatcher.Query(text)
        let hits = data.contacts.filter { FuzzyMatcher.match(query, in: FuzzyMatcher.Name($0.name)) != nil }.map { contact in
            ContactHit(identifier: contact.identifier, name: contact.name,
                       detail: contact.emails.first?.value ?? contact.organization)
        }
        return ContactRanking.rank(hits, query: query, limit: limit)
    }
}
#endif
