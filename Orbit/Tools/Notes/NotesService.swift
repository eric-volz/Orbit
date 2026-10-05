import Foundation

/// Orbit's Notes scripts (`Resources/AppleScripts/notes-*.applescript`) with
/// typed arguments and results. Live through `LiveAppleScriptRunner`; tests
/// pass a mock runner, the DEBUG fake-data mode one that answers from
/// invented notes. The JSON types are Codable, so the fake answers exactly
/// like the scripts do.
struct NotesService: Sendable {
    static let searchScript = AppleScript(name: "notes-search", app: .notes, timeout: .seconds(60))
    static let readScript = AppleScript(name: "notes-read", app: .notes, timeout: .seconds(45))
    static let createScript = AppleScript(name: "notes-create", app: .notes, timeout: .seconds(45))
    static let openScript = AppleScript(name: "notes-open", app: .notes, timeout: .seconds(30))
    static let scripts = [searchScript, readScript, createScript, openScript]
    /// Seconds into a search after which `notes-search` looks for further terms
    /// in the notes' names only, so it ends well before its 60-second limit.
    static let searchTextBudgetSeconds = 35

    let runner: any AppleScriptRunning
    /// The names of Notes' "Recently Deleted" folder that may appear (its
    /// notes are never listed, and nothing is created in it).
    var trashFolderNames: [String]

    init(runner: any AppleScriptRunning, trashFolderNames: [String] = NotesTrash.folderNames()) {
        self.runner = runner
        self.trashFolderNames = trashFolderNames
    }

    /// Notes whose name or text contains every term (all notes without terms),
    /// in folders named `folder` (all without), newest first, at most `limit`;
    /// each with up to `startCharacters` characters of its text.
    func search(terms: [String], folder: String?, limit: Int, startCharacters: Int) async throws -> NotesSearchResult {
        let arguments = [terms.joined(separator: "\n"), folder ?? "", String(limit), String(startCharacters),
                         trashFolderNames.joined(separator: "\n"), String(Self.searchTextBudgetSeconds)]
        let output = try await runner.run(Self.searchScript, arguments: arguments)
        try Self.checkFailure(output, script: Self.searchScript, folder: folder, trash: trashFolderNames)
        var result = try Self.decode(NotesSearchResult.self, from: output, script: Self.searchScript)
        result.folders = result.folders.map { NotesFailure.uniqued($0.filter { !trashFolderNames.contains($0) }) }
        return result
    }

    /// The note with this id, its HTML body cut after `maxBodyCharacters`.
    func read(id: String, maxBodyCharacters: Int) async throws -> NoteContent {
        let output = try await runner.run(Self.readScript, arguments: [id, String(maxBodyCharacters)])
        try Self.checkFailure(output, script: Self.readScript, folder: nil, trash: trashFolderNames)
        return try Self.decode(NoteContent.self, from: output, script: Self.readScript)
    }

    /// Creates a note from `html` (see `NoteText.html(title:body:)`) in the
    /// first folder named `folder`, or in the default folder.
    func create(html: String, folder: String?) async throws -> CreatedNote {
        let arguments = [html, folder ?? "", trashFolderNames.joined(separator: "\n")]
        let output = try await runner.run(Self.createScript, arguments: arguments)
        try Self.checkFailure(output, script: Self.createScript, folder: folder, trash: trashFolderNames)
        return try Self.decode(CreatedNote.self, from: output, script: Self.createScript)
    }

    /// Shows the note in Notes and brings Notes to the front; returns its name.
    @discardableResult
    func open(id: String) async throws -> String {
        let output = try await runner.run(Self.openScript, arguments: [id])
        try Self.checkFailure(output, script: Self.openScript, folder: nil, trash: trashFolderNames)
        let opened = try Self.decode(OpenedNote.self, from: output, script: Self.openScript)
        guard opened.opened else { throw AppleScriptError.invalidOutput }
        return opened.name
    }

    // MARK: Decoding

    /// The `{"error": …}` answers of the scripts.
    private struct ScriptFailure: Decodable {
        var error: String?
        var folders: [String]?
    }

    private static func checkFailure(_ output: String, script: AppleScript, folder: String?, trash: [String]) throws {
        guard let failure = try? JSONDecoder().decode(ScriptFailure.self, from: Data(output.utf8)),
              let error = failure.error else { return }
        switch error {
        case "notFound":
            throw NotesFailure.noteNotFound
        case "folderNotFound":
            let existing = (failure.folders ?? []).filter { !trash.contains($0) }
            throw NotesFailure.folderNotFound(folder ?? "", existing: NotesFailure.uniqued(existing))
        default:
            throw AppleScriptError.invalidOutput
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from output: String, script: AppleScript) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(output.utf8))
        } catch {
            Log.tools.error("AppleScript \(script.name, privacy: .public) printed output that is not the expected JSON")
            throw AppleScriptError.invalidOutput
        }
    }
}

/// What a Notes script reports instead of a result.
enum NotesFailure: Error, Sendable, Hashable {
    /// No note has this id (anymore).
    case noteNotFound
    /// No folder has the requested name; `existing` are the folders there are.
    case folderNotFound(String, existing: [String])

    static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// Whether a text is a note id as Notes gives them (x-coredata://…/ICNote/p…).
enum NoteID {
    static func isValid(_ id: String) -> Bool {
        id.hasPrefix("x-coredata://") && id.count <= 300
            && !id.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0 == "\"" }
    }
}

// MARK: - Results (the scripts' JSON)

/// `notes-search`: the matching notes, newest first.
struct NotesSearchResult: Sendable, Hashable, Codable {
    var notes: [NoteSummary]
    /// All matching notes, also those beyond the limit.
    var total: Int
    /// False when Notes could not search the notes' text and only their names were searched.
    var textSearched: Bool
    /// Terms looked for in the notes' names only, because searching the text
    /// for them would have taken too long.
    var titleOnlyTerms: [String]
    /// The names of all folders, when nothing matched in all of them (people
    /// name a note by its folder: "my recipe note"); nil otherwise.
    var folders: [String]?

    init(notes: [NoteSummary], total: Int, textSearched: Bool = true, titleOnlyTerms: [String] = [], folders: [String]? = nil) {
        self.notes = notes
        self.total = total
        self.textSearched = textSearched
        self.titleOnlyTerms = titleOnlyTerms
        self.folders = folders
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes = try container.decode([NoteSummary].self, forKey: .notes)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? notes.count
        textSearched = try container.decodeIfPresent(Bool.self, forKey: .textSearched) ?? true
        titleOnlyTerms = try container.decodeIfPresent([String].self, forKey: .titleOnlyTerms) ?? []
        folders = try container.decodeIfPresent([String].self, forKey: .folders)
    }
}

/// A note in search results.
struct NoteSummary: Sendable, Hashable, Codable {
    var id: String
    var name: String
    var folder: String
    var modified: Date?
    var isLocked: Bool
    /// The beginning of the note's text, starting with its title (empty for locked notes).
    var start: String

    enum CodingKeys: String, CodingKey {
        case id, name, folder, modified, isLocked = "locked", start
    }

    init(id: String, name: String, folder: String, modified: Date?, isLocked: Bool, start: String) {
        self.id = id
        self.name = name
        self.folder = folder
        self.modified = modified
        self.isLocked = isLocked
        self.start = start
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        modified = try container.decodeIfPresent(Double.self, forKey: .modified).map(Date.init(timeIntervalSince1970:))
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        start = try container.decodeIfPresent(String.self, forKey: .start) ?? ""
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(folder, forKey: .folder)
        try container.encodeIfPresent(modified?.timeIntervalSince1970, forKey: .modified)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(start, forKey: .start)
    }
}

/// `notes-read`: one note with its HTML body.
struct NoteContent: Sendable, Hashable, Codable {
    var id: String
    var name: String
    var folder: String
    var created: Date?
    var modified: Date?
    var isLocked: Bool
    /// The HTML body, possibly cut (empty for locked notes).
    var body: String
    /// Characters of the whole body.
    var bodyLength: Int

    enum CodingKeys: String, CodingKey {
        case id, name, folder, created, modified, isLocked = "locked", body, bodyLength
    }

    init(id: String, name: String, folder: String, created: Date?, modified: Date?, isLocked: Bool, body: String,
         bodyLength: Int) {
        self.id = id
        self.name = name
        self.folder = folder
        self.created = created
        self.modified = modified
        self.isLocked = isLocked
        self.body = body
        self.bodyLength = bodyLength
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        created = try container.decodeIfPresent(Double.self, forKey: .created).map(Date.init(timeIntervalSince1970:))
        modified = try container.decodeIfPresent(Double.self, forKey: .modified).map(Date.init(timeIntervalSince1970:))
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        bodyLength = try container.decodeIfPresent(Int.self, forKey: .bodyLength) ?? body.count
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(folder, forKey: .folder)
        try container.encodeIfPresent(created?.timeIntervalSince1970, forKey: .created)
        try container.encodeIfPresent(modified?.timeIntervalSince1970, forKey: .modified)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(body, forKey: .body)
        try container.encode(bodyLength, forKey: .bodyLength)
    }
}

/// `notes-create`: the new note.
struct CreatedNote: Sendable, Hashable, Codable {
    var id: String
    var name: String
    var folder: String
}

/// `notes-open`.
struct OpenedNote: Sendable, Hashable, Codable {
    var opened: Bool
    var name: String
}

// MARK: - The trash folder

/// Notes keeps deleted notes in a top-level folder "Recently Deleted", named
/// in Notes' language. Its names, by language, as Notes ships them
/// (NotesShared.framework, macOS 26/27).
enum NotesTrash {
    static let namesByLanguage: [String: String] = [
        "ar": "المحذوفة مؤخرًا", "ca": "Eliminades fa poc", "cs": "Nedávno smazané", "da": "Slettet for nylig",
        "de": "Zuletzt gelöscht", "el": "Πρόσφατες διαγραφές", "en": "Recently Deleted", "es": "Recién eliminado",
        "es_419": "Eliminadas", "fi": "Äskettäin poistetut", "fr": "Suppr. récentes", "he": "נמחקו לאחרונה",
        "hi": "हालिया डिलीट किए गए", "hr": "Nedavno obrisano", "hu": "Nemrég törölt", "id": "Baru Dihapus",
        "it": "Eliminate", "ja": "最近削除した項目", "ko": "최근 삭제된 항목", "ms": "Terbaru Dipadam",
        "nl": "Recent verwijderd", "no": "Nylig slettet", "nb": "Nylig slettet", "pl": "Ostatnio usunięte",
        "pt": "Apagadas", "ro": "Șterse recent", "ru": "Недавно удаленные", "sk": "Nedávno vymazané",
        "sl": "Nedavno izbrisano", "sv": "Senast raderade", "th": "ที่ลบล่าสุด", "tr": "Son Silinenler",
        "uk": "Недавно видалені", "vi": "Đã xóa gần đây", "zh_CN": "最近删除", "zh_HK": "最近刪除",
        "zh_TW": "最近刪除",
    ]

    /// The English name and the names in the user's languages (as macOS
    /// lists them for all apps; Orbit's own language setting may differ from
    /// Notes'), so a folder that merely shares another language's name stays
    /// searchable.
    static func folderNames(preferredLanguages: [String] = globalPreferredLanguages()) -> [String] {
        var names = ["Recently Deleted"]
        for identifier in preferredLanguages {
            guard let name = name(forLanguage: identifier), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    static func name(forLanguage identifier: String) -> String? {
        let locale = Locale(identifier: identifier)
        guard let language = locale.language.languageCode?.identifier else { return nil }
        let region = locale.language.region?.identifier
        var keys: [String] = []
        switch language {
        case "zh":
            if region == "HK" || region == "MO" { keys.append("zh_HK") }
            keys.append(locale.language.script?.identifier == "Hant" || region == "TW" ? "zh_TW" : "zh_CN")
        case "es":
            if let region, region != "ES" { keys.append("es_419") }
            keys.append("es")
        default:
            keys.append(language)
        }
        return keys.lazy.compactMap { namesByLanguage[$0] }.first
    }

    /// The languages the user chose for all apps (not Orbit's own override).
    static func globalPreferredLanguages() -> [String] {
        let value = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? [String]) ?? Locale.preferredLanguages
    }
}
