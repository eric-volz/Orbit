import Foundation
import GRDB
import Testing
@testable import Orbit

@Suite("ConversationStore")
struct ConversationStoreTests {
    // MARK: Round trips

    @Test func roundTripsEveryItemAndBlockKind() async throws {
        let store = try ConversationStore(database: .inMemory())
        let conversation = StorageFixtures.everyKind()
        try await store.save(conversation)
        let restored = try #require(try await store.mostRecent())
        #expect(restored == conversation)
        #expect(restored.messages.count == conversation.messages.count)
        #expect(restored.items.count == conversation.items.count)
    }

    @Test func thinkingBlocksSurviveByteForByte() async throws {
        let store = try ConversationStore(database: .inMemory())
        // Decomposed "é", precomposed "é", quotes, backslashes, control characters, emoji.
        let text = "Denke nach: e\u{301} vs \u{E9}, \"zitiert\", \\pfad\\, \t\n\u{0}\u{1F680}"
        let signature = "EqQBCkgIARABGAIiQL/+sig==/with/slashes"
        let conversation = Conversation(messages: [
            .user("Frage"),
            Message(role: .assistant, content: [.thinking(text: text, signature: signature), .redactedThinking(data: "abc/+=="), .text("Antwort")]),
        ])
        try await store.save(conversation)
        let restored = try #require(try await store.mostRecent())
        guard case .thinking(let restoredText, let restoredSignature) = restored.messages[1].content[0] else {
            Issue.record("thinking block missing")
            return
        }
        #expect(Array(restoredText.utf8) == Array(text.utf8))
        #expect(Array(restoredSignature?.utf8 ?? "".utf8) == Array(signature.utf8))
        #expect(restored.messages[1].content[1] == .redactedThinking(data: "abc/+=="))
    }

    @Test func storesDatesAsISO8601WithMilliseconds() async throws {
        let database = try AppDatabase.inMemory()
        let store = ConversationStore(database: database)
        let conversation = Conversation(createdAt: StorageFixtures.date(0.125), updatedAt: StorageFixtures.date(60.5), messages: [.user("x")])
        try await store.save(conversation)

        let (createdAt, updatedAt, storedPayload) = try await database.writer.read { db -> (String?, String?, Data?) in
            let row = try Row.fetchOne(db, sql: "SELECT createdAt, updatedAt, payload FROM conversation")
            return (row?["createdAt"], row?["updatedAt"], row?["payload"])
        }
        #expect(createdAt == "2026-09-21T14:13:20.125Z")
        #expect(updatedAt == "2026-09-21T14:14:20.500Z")
        let payload = try #require(storedPayload)
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["createdAt"] as? String == "2026-09-21T14:13:20.125Z")
        #expect(json["updatedAt"] as? String == "2026-09-21T14:14:20.500Z")
    }

    @Test func keepsDatesToTheMillisecond() async throws {
        let store = try ConversationStore(database: .inMemory())
        let now = Date()
        try await store.save(Conversation(createdAt: now, updatedAt: now, messages: [.user("x")]))
        let restored = try #require(try await store.mostRecent())
        #expect(abs(restored.createdAt.timeIntervalSince(now)) < 0.001)
        #expect(abs(restored.messages[0].createdAt.timeIntervalSince(now)) < 1)
    }

    @Test func parsesTimestampsWithAndWithoutFraction() {
        #expect(ISO8601Milliseconds.date(from: "2026-09-21T14:13:20.125Z") == StorageFixtures.date(0.125))
        #expect(ISO8601Milliseconds.date(from: "2026-09-21T14:13:20Z") == StorageFixtures.date(0))
        #expect(ISO8601Milliseconds.date(from: "gestern") == nil)
        #expect(ISO8601Milliseconds.string(from: StorageFixtures.date(0)) == "2026-09-21T14:13:20.000Z")
    }

    // MARK: Ordering, upsert, pruning

    @Test func mostRecentIsTheLatestUpdate() async throws {
        let store = try ConversationStore(database: .inMemory())
        #expect(try await store.mostRecent() == nil)
        let first = StorageFixtures.conversation("A", updated: 10)
        let latest = StorageFixtures.conversation("B", updated: 30)
        let middle = StorageFixtures.conversation("C", updated: 20)
        for conversation in [latest, first, middle] {
            try await store.save(conversation)
        }
        #expect(try await store.mostRecent()?.id == latest.id)

        var reopened = first
        reopened.updatedAt = StorageFixtures.date(40)
        reopened.messages.append(Message(role: .user, content: [.text("Weiter")], createdAt: StorageFixtures.date(40)))
        try await store.save(reopened)
        #expect(try await store.mostRecent() == reopened)
    }

    @Test func saveReplacesTheStoredConversation() async throws {
        let store = try ConversationStore(database: .inMemory())
        var conversation = StorageFixtures.conversation("Erster Titel", updated: 1)
        try await store.save(conversation)
        conversation.title = "Neuer Titel"
        conversation.messages.append(Message(role: .assistant, content: [.text("Antwort")], createdAt: StorageFixtures.date(2)))
        conversation.updatedAt = StorageFixtures.date(2)
        try await store.save(conversation)

        #expect(try await store.count() == 1)
        #expect(try await store.mostRecent() == conversation)
    }

    @Test func prunesTheOldestConversations() async throws {
        let database = try AppDatabase.inMemory()
        let store = ConversationStore(database: database, maximumCount: 3)
        let conversations = (1...5).map { StorageFixtures.conversation("Chat \($0)", updated: Double($0)) }
        for conversation in conversations.shuffled() {
            try await store.save(conversation)
        }
        #expect(try await store.count() == 3)
        let remaining = try await database.writer.read { db in
            try String.fetchSet(db, sql: "SELECT id FROM conversation")
        }
        #expect(remaining == Set(conversations.suffix(3).map(\.id.uuidString)))
    }

    @Test func keepsAtMostOneHundredByDefault() async throws {
        let store = try ConversationStore(database: .inMemory())
        #expect(store.maximumCount == 100)
        let conversations = (1...105).map { StorageFixtures.conversation("Chat \($0)", updated: Double($0)) }
        for conversation in conversations {
            try await store.save(conversation)
        }
        #expect(try await store.count() == 100)
        #expect(try await store.mostRecent()?.id == conversations.last?.id)
    }

    @Test func concurrentSavesAreSerialized() async throws {
        let store = try ConversationStore(database: .inMemory())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...20 {
                group.addTask {
                    try await store.save(StorageFixtures.conversation("Chat \(index)", updated: Double(index)))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.count() == 20)
        #expect(try await store.mostRecent()?.title == "Chat 20")
    }

    // MARK: Deleting

    @Test func deleteAllRemovesEverything() async throws {
        let store = try ConversationStore(database: .inMemory())
        for index in 1...3 {
            try await store.save(StorageFixtures.conversation("Chat \(index)", updated: Double(index)))
        }
        try await store.deleteAll()
        #expect(try await store.count() == 0)
        #expect(try await store.mostRecent() == nil)

        let next = StorageFixtures.conversation("Danach", updated: 9)
        try await store.save(next)
        #expect(try await store.mostRecent() == next)
    }

    @Test func undecodablePayloadIsReported() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO conversation (id, title, createdAt, updatedAt, payload) VALUES (?, NULL, ?, ?, ?)",
                           arguments: [UUID().uuidString, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z", Data("{}".utf8)])
        }
        let store = ConversationStore(database: database)
        await #expect(throws: ConversationStore.StoreError.undecodablePayload) {
            try await store.mostRecent()
        }
    }
}

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test func migrationCreatesTheSchema() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.read { db in
            let columns = try db.columns(in: "conversation").map(\.name)
            #expect(columns == ["id", "title", "createdAt", "updatedAt", "payload"])
            #expect(try db.primaryKey("conversation").columns == ["id"])
            let indexes = try db.indexes(on: "conversation")
            #expect(indexes.contains { $0.name == "conversation_on_updatedAt" && $0.columns == ["updatedAt"] })
            #expect(try db.columns(in: "conversation").first { $0.name == "payload" }?.isNotNull == true)
        }
        #expect(try await database.writer.read { db in try AppDatabase.migrator.hasCompletedMigrations(db) })
    }

    @Test func onDiskDatabaseUsesWALAndSecureDelete() async throws {
        let directory = try TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.url.appendingPathComponent("Orbit.sqlite"))
        #expect(database.writer is DatabasePool)
        let writerSettings = try await database.writer.write { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Int.fetchOne(db, sql: "PRAGMA secure_delete"))
        }
        #expect(writerSettings.0 == "wal")
        #expect(writerSettings.1 == 1)
        let readerSecureDelete = try await database.writer.read { db in try Int.fetchOne(db, sql: "PRAGMA secure_delete") }
        #expect(readerSecureDelete == 1)
    }

    @Test func createsItsDirectoryPrivately() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Nested/Orbit/Orbit.sqlite")
        let store = ConversationStore(url: url)
        try await store.save(StorageFixtures.conversation("x", updated: 1))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // A second store on the same file sees the chat (persistence across launches).
        #expect(try await ConversationStore(url: url).mostRecent()?.title == "x")
    }

    @Test func deleteAllLeavesNoTraceInTheFiles() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Orbit.sqlite")
        let store = ConversationStore(url: url)
        let marker = "ORBIT-PRIVATE-MARKER-\(UUID().uuidString)"
        for index in 1...5 {
            var conversation = StorageFixtures.conversation("Chat \(index)", updated: Double(index))
            conversation.messages.append(.user("\(marker) \(String(repeating: "Inhalt ", count: 500))"))
            try await store.save(conversation)
        }
        #expect(Self.filesContain(marker, url: url), "the marker should be on disk before deleting")

        try await store.deleteAll()
        #expect(!Self.filesContain(marker, url: url), "deleted chats must not remain in Orbit.sqlite, -wal or -shm")
        #expect(try await store.count() == 0)
    }

    @Test func movesAnUnreadableFileAside() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Orbit.sqlite")
        try Data(repeating: 0x42, count: 8192).write(to: url)

        let store = ConversationStore(url: url)
        try await store.save(StorageFixtures.conversation("Neu", updated: 1))
        #expect(try await store.mostRecent()?.title == "Neu")
        let damaged = AppDatabase.damagedFiles(for: url)[0]
        #expect(FileManager.default.fileExists(atPath: damaged.path))

        try await store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: damaged.path))
    }

    private static func filesContain(_ marker: String, url: URL) -> Bool {
        let needle = Data(marker.utf8)
        return AppDatabase.databaseFiles(for: url).contains { file in
            guard let data = try? Data(contentsOf: file) else { return false }
            return data.range(of: needle) != nil
        }
    }
}

/// A unique temporary directory, removed when the value is released.
private final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private enum StorageFixtures {
    /// 2026-09-21T14:13:20Z plus `offset` seconds (binary fractions stay exact).
    static func date(_ offset: Double) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + offset)
    }

    static func conversation(_ title: String, updated: Double) -> Conversation {
        Conversation(title: title, createdAt: date(0), updatedAt: date(updated), messages: [
            Message(role: .user, content: [.text(title)], createdAt: date(0)),
        ])
    }

    /// A conversation using every ChatItem, ResultCard and ContentBlock kind.
    static func everyKind() -> Conversation {
        let call = ToolCall(id: "toolu_01", name: "search_files", input: ["query": "Rechnung", "limit": 5, "kinds": ["pdf"]],
                            rawInput: #"{"query":"Rechnung","limit":5,"kinds":["pdf"]}"#)
        let brokenCall = ToolCall(id: "toolu_02", name: "read_file", rawInput: #"{"path": "/tmp/a"#,
                                  inputParseError: "Unexpected end of input")
        let messages = [
            Message(role: .user, content: [.text("Kontext: 14:13"), .text("Finde die Rechnung")], createdAt: date(0)),
            Message(role: .assistant, content: [
                .thinking(text: "Ich suche.", signature: "sig=="),
                .thinking(text: "Ohne Signatur", signature: nil),
                .redactedThinking(data: "encrypted"),
                .text("Ich suche die Rechnung."),
                .toolUse(call),
                .toolUse(brokenCall),
                .opaque(["type": "fallback", "nested": ["a": [1, 2.5, true, nil, "x"]]]),
            ], createdAt: date(1), model: "claude-sonnet-5-5"),
            Message(role: .user, content: [
                .toolResult(ToolResultBlock(toolCallID: "toolu_01", content: "2 Treffer")),
                .toolResult(ToolResultBlock(toolCallID: "toolu_02", content: "INVALID_JSON", isError: true)),
            ], createdAt: date(2)),
        ]

        let confirmation = ConfirmationRequest(
            id: UUID(), toolCallID: "toolu_03", toolName: "create_event", riskLevel: .write, title: "Create event",
            message: "Erstellt einen Termin.", fields: [
                ConfirmationField(id: "title", label: "Titel", value: "Zahnarzt", kind: .text),
                ConfirmationField(id: "notes", label: "Notizen", value: "Zeile 1\nZeile 2", kind: .multilineText),
                ConfirmationField(id: "start", label: "Start", value: "2026-10-01T09:00:00+02:00", kind: .dateTime),
                ConfirmationField(id: "calendar", label: "Kalender", value: "Privat", kind: .readOnly),
            ], warning: "Achtung", confirmLabel: "Create")
        let cards: [ResultCard] = [
            .files([FileItem(path: "/Users/test/Rechnung.pdf", name: "Rechnung.pdf", kindDescription: "PDF-Dokument",
                             contentType: "com.adobe.pdf", modified: date(3), size: 123_456),
                    FileItem(path: "/Users/test/Ordner", name: "Ordner", isDirectory: true)]),
            .mails([MailItem(id: "mail-1", messageID: "abc@example.com", sender: "Lisa", senderAddress: "lisa@example.com",
                             subject: "Projekt", date: date(4), preview: "Hallo", mailbox: "Eingang", account: "iCloud", isRead: false)]),
            .mailDraft(MailDraftItem(to: ["lisa@example.com"], cc: [], subject: "Re: Projekt", body: "Donnerstag passt.", isOpenInMail: true)),
            .mailDraft(MailDraftItem(to: ["Lisa <lisa@example.com>"], cc: ["max@example.com"], subject: "Re: Projekt",
                                     body: "Donnerstag passt.", isOpenInMail: true, draftID: 3,
                                     reply: MailReplyInfo(toAll: true, isTextOnClipboard: true))),
            .notes([NoteItem(id: "x-coredata://1", title: "Umzug", excerpt: "Kartons", folder: "Notizen", modified: date(5))]),
            .events([EventItem(id: "event-1", title: "Zahnarzt", start: date(6), end: date(7), isAllDay: false, location: "Praxis",
                               calendarName: "Privat", calendarColor: "#FF0000", notes: nil)]),
            .reminders([ReminderItem(id: "rem-1", title: "Milch", due: date(8), dueHasTime: true, isCompleted: false,
                                     listName: "Einkauf", listColor: "#00FF00", notes: "fettarm")]),
            .contacts([ContactItem(id: "contact-1", name: "Lisa Muster", organization: "Firma", emails: ["lisa@example.com"],
                                   phones: ["+49 30 123"])]),
            .photos([PhotoItem(id: "photo-1", creationDate: date(9), mediaType: .livePhoto, isFavorite: true, duration: nil,
                               pixelWidth: 4032, pixelHeight: 3024),
                     PhotoItem(id: "photo-2", creationDate: nil, mediaType: .video, isFavorite: false, duration: 12.5,
                               pixelWidth: nil, pixelHeight: nil)]),
            .info(InfoItem(title: "Dunkelmodus aktiviert", detail: nil, systemImage: "moon")),
        ]

        var items: [ChatItem] = [
            ChatItem(kind: .user(text: "Finde die Rechnung", attachments: [
                ContextAttachment(kind: .finderSelection(paths: ["/Users/test/Angebot.pdf"]), label: "Mit Auswahl: Angebot.pdf"),
                ContextAttachment(kind: .selectedText(text: "markierter Text", appName: "Safari"), label: "Markierter Text"),
                ContextAttachment(kind: .frontmostApp(name: "Finder", bundleID: "com.apple.finder", windowTitle: nil), label: "Finder"),
            ]), createdAt: date(0)),
            ChatItem(kind: .progress(text: "Ich suche…"), createdAt: date(1)),
            ChatItem(kind: .assistant(text: "## Ergebnis\n\n- eins", isStreaming: false), createdAt: date(2)),
            ChatItem(kind: .assistant(text: "Wird geschr", isStreaming: true), createdAt: date(3)),
            ChatItem(kind: .notice(Notice(style: .info, message: "Info")), createdAt: date(4)),
            ChatItem(kind: .notice(Notice(style: .warning, message: "Warnung", action: .openSettings)), createdAt: date(4)),
            ChatItem(kind: .notice(Notice(style: .error, message: "Fehler", action: .retry)), createdAt: date(4)),
            ChatItem(kind: .disclosure(items: [ContentDisclosure(kind: .emails, count: 3), ContentDisclosure(kind: .fileNames, count: 12)],
                                       providerName: "Claude"), createdAt: date(5)),
        ]
        for (index, state) in [ToolStatus.State.running, .succeeded, .failed, .cancelled].enumerated() {
            items.append(ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "call-\(index)", toolName: "search_files",
                                                               category: index == 0 ? nil : .files, text: "Searching files…",
                                                               state: state)), createdAt: date(6)))
        }
        for status in [ConfirmationState.Status.pending, .approved, .cancelled, .expired] {
            items.append(ChatItem(kind: .confirmation(ConfirmationState(request: confirmation, status: status)), createdAt: date(7)))
        }
        items += cards.map { ChatItem(kind: .card($0), createdAt: date(8)) }

        return Conversation(title: "Rechnung", createdAt: date(0), updatedAt: date(10.25),
                            systemPrompt: "You are Orbit.", toolNames: ["search_files", "read_file"],
                            messages: messages, items: items)
    }
}
