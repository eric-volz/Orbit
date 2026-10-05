import Foundation
import GRDB

/// Stores conversations in SQLite: one row per chat, the whole `Conversation`
/// as a JSON payload (dates as ISO 8601 with milliseconds). Keeps the most
/// recent `maximumCount` chats; older ones are deleted when a chat is saved.
///
/// The database is opened on first use and all work (including JSON encoding
/// and decoding) runs on GRDB's dispatch queues, never on the main thread.
final class ConversationStore: ConversationStoring {
    static let defaultMaximumCount = 100

    enum StoreError: Error, Equatable {
        /// A stored payload could not be decoded (e.g. written by an
        /// incompatible version). Saving a new chat makes it obsolete.
        case undecodablePayload
    }

    let maximumCount: Int
    private let source: DatabaseSource

    /// A store on an open database (tests use `AppDatabase.inMemory()`).
    init(database: AppDatabase, maximumCount: Int = ConversationStore.defaultMaximumCount) {
        self.source = DatabaseSource(database: database)
        self.maximumCount = max(1, maximumCount)
    }

    /// A store that opens the database at `url` lazily, on first use.
    init(url: URL = AppPaths.databaseURL, maximumCount: Int = ConversationStore.defaultMaximumCount) {
        self.source = DatabaseSource { try AppDatabase.open(at: url) }
        self.maximumCount = max(1, maximumCount)
    }

    // MARK: ConversationStoring

    /// Inserts or replaces the conversation, then prunes the oldest chats.
    func save(_ conversation: Conversation) async throws {
        let database = try await source.database()
        let limit = maximumCount
        let (bytes, pruned) = try await database.writer.write { db in
            let payload = try Self.makeEncoder().encode(conversation)
            try db.execute(sql: """
                INSERT INTO conversation (id, title, createdAt, updatedAt, payload)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    createdAt = excluded.createdAt,
                    updatedAt = excluded.updatedAt,
                    payload = excluded.payload
                """, arguments: [
                    conversation.id.uuidString,
                    conversation.title,
                    ISO8601Milliseconds.string(from: conversation.createdAt),
                    ISO8601Milliseconds.string(from: conversation.updatedAt),
                    payload,
                ])
            try db.execute(sql: """
                DELETE FROM conversation
                WHERE id NOT IN (SELECT id FROM conversation ORDER BY updatedAt DESC, rowid DESC LIMIT ?)
                """, arguments: [limit])
            return (payload.count, db.changesCount)
        }
        Log.storage.debug("Saved conversation (\(bytes, privacy: .public) bytes, pruned \(pruned, privacy: .public))")
    }

    /// The conversation with the latest `updatedAt`, or nil when there is none.
    func mostRecent() async throws -> Conversation? {
        let database = try await source.database()
        return try await database.writer.read { db in
            guard let payload = try Data.fetchOne(db, sql: """
                SELECT payload FROM conversation ORDER BY updatedAt DESC, rowid DESC LIMIT 1
                """) else { return nil }
            do {
                return try Self.makeDecoder().decode(Conversation.self, from: payload)
            } catch {
                Log.storage.error("Stored conversation cannot be decoded: \(String(describing: type(of: error)), privacy: .public)")
                throw StoreError.undecodablePayload
            }
        }
    }

    /// Deletes every conversation. With `secure_delete`, `VACUUM` and a WAL
    /// checkpoint the old content is overwritten in the database files too.
    func deleteAll() async throws {
        let database = try await source.database()
        let deleted = try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM conversation")
            return db.changesCount
        }
        try await database.writer.vacuum()
        try await database.writer.barrierWriteWithoutTransaction { db in
            do {
                _ = try db.checkpoint(.truncate)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
                // Another process (e.g. a second Orbit build) is reading. The chats
                // are deleted either way; the WAL is reset by a later checkpoint.
                Log.storage.warning("WAL checkpoint after deleting chats was busy")
            }
        }
        try database.removeDamagedCopies()
        Log.storage.info("Deleted all conversations (\(deleted, privacy: .public))")
    }

    // MARK: Queries

    /// The number of stored conversations.
    func count() async throws -> Int {
        let database = try await source.database()
        return try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
        }
    }

    // MARK: Coding

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Milliseconds.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Milliseconds.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, got \(text)")
            }
            return date
        }
        return decoder
    }
}

/// UTC timestamps like `2026-09-28T19:03:12.123Z`. The fixed width keeps them
/// sortable as text (the `updatedAt` column is ordered as a string).
enum ISO8601Milliseconds {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    private static let withoutFraction = Date.ISO8601FormatStyle(timeZone: .gmt)

    static func string(from date: Date) -> String {
        date.formatted(withFraction)
    }

    /// Parses timestamps with or without fractional seconds.
    static func date(from string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? withoutFraction.parse(string))
    }
}

/// Opens the database on first use, on this actor, never on the main thread.
/// A failed open is retried on the next call.
private actor DatabaseSource {
    private var cached: AppDatabase?
    private let open: (@Sendable () throws -> AppDatabase)?

    init(database: AppDatabase) {
        self.cached = database
        self.open = nil
    }

    init(open: @escaping @Sendable () throws -> AppDatabase) {
        self.cached = nil
        self.open = open
    }

    func database() throws -> AppDatabase {
        if let cached { return cached }
        guard let open else { preconditionFailure("DatabaseSource without a database or an opener") }
        let opened = try open()
        cached = opened
        Log.storage.info("Opened the chat database")
        return opened
    }
}
