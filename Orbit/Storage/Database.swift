import Foundation
import GRDB

/// Orbit's SQLite database (GRDB): the chat history.
///
/// On disk it is a `DatabasePool` in WAL mode. Every connection runs with
/// `PRAGMA secure_delete = ON`, so SQLite overwrites deleted content with
/// zeros instead of leaving it in free pages, so cleared chats do not linger in
/// the file. The schema is created and upgraded by `migrator`.
final class AppDatabase: Sendable {
    /// The GRDB connection: a pool on disk, a queue in memory.
    let writer: any DatabaseWriter
    /// The database file; nil for in-memory databases.
    let fileURL: URL?

    private init(writer: any DatabaseWriter, fileURL: URL?) throws {
        self.writer = writer
        self.fileURL = fileURL
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the database at `url`, creating its directory.
    ///
    /// A file that is not a readable SQLite database is moved aside to
    /// `<name>.damaged` (replacing an older one) and a new, empty database is
    /// created, so a damaged file never disables chat history for good.
    static func open(at url: URL = AppPaths.databaseURL) throws -> AppDatabase {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            // Chats are private: keep the folder readable by the user only.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        do {
            return try AppDatabase(writer: DatabasePool(path: url.path, configuration: makeConfiguration()), fileURL: url)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            Log.storage.error("Database unreadable (\(error.resultCode.rawValue, privacy: .public)); moving it aside")
            try moveAside(url)
            return try AppDatabase(writer: DatabasePool(path: url.path, configuration: makeConfiguration()), fileURL: url)
        }
    }

    /// An empty, private in-memory database (for tests and previews).
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: makeConfiguration()), fileURL: nil)
    }

    static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "Orbit"
        configuration.foreignKeysEnabled = true
        // Another Orbit process (e.g. a debug build) may hold the write lock briefly.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return configuration
    }

    /// Schema history. Never edit a registered migration; add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { table in
                table.primaryKey("id", .text)
                table.column("title", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("payload", .blob).notNull()
            }
            try db.create(index: "conversation_on_updatedAt", on: "conversation", columns: ["updatedAt"])
        }
        return migrator
    }

    // MARK: Files

    /// The database file and its WAL/shared-memory companions.
    static func databaseFiles(for url: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// Where `open(at:)` puts an unreadable database file.
    static func damagedFiles(for url: URL) -> [URL] {
        databaseFiles(for: url).map { URL(fileURLWithPath: $0.path + ".damaged") }
    }

    private static func moveAside(_ url: URL) throws {
        let fileManager = FileManager.default
        for (source, destination) in zip(databaseFiles(for: url), damagedFiles(for: url)) {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    /// Deletes a database moved aside by `open(at:)` (part of "clear history").
    func removeDamagedCopies() throws {
        guard let fileURL else { return }
        for file in Self.damagedFiles(for: fileURL) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
