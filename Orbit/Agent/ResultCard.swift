import Foundation

/// Structured data a tool hands to the UI. Every case is rendered by a card in
/// UI/ResultCards. Items are Codable so chats can be restored after relaunch.
enum ResultCard: Sendable, Hashable, Codable {
    case files([FileItem])
    case mails([MailItem])
    case mailDraft(MailDraftItem)
    case notes([NoteItem])
    case events([EventItem])
    case reminders([ReminderItem])
    case contacts([ContactItem])
    case photos([PhotoItem])
    /// A simple confirmation of something that happened ("Dunkelmodus aktiviert").
    case info(InfoItem)
}

struct FileItem: Sendable, Hashable, Codable, Identifiable {
    var path: String
    var name: String
    /// Localized kind, e.g. "PDF-Dokument".
    var kindDescription: String?
    /// Uniform Type Identifier, e.g. "com.adobe.pdf".
    var contentType: String?
    var modified: Date?
    var size: Int64?
    var isDirectory: Bool = false
    /// The folder as Finder names it, outermost first (["Dokumente",
    /// "Rechnungen"]; see `FolderNames`), found when the tool ran. nil in chats
    /// saved before, whose rows show the path.
    var folderNames: [String]? = nil

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

struct MailItem: Sendable, Hashable, Codable, Identifiable {
    /// Opaque id understood by `read_mail`.
    var id: String
    /// RFC 5322 Message-ID without angle brackets; opens the message via message://.
    var messageID: String?
    var sender: String
    var senderAddress: String?
    var subject: String
    var date: Date?
    var preview: String?
    var mailbox: String?
    var account: String?
    var isRead: Bool?
}

struct MailDraftItem: Sendable, Hashable, Codable {
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    /// True once the draft window is open in Mail.
    var isOpenInMail: Bool
    /// The draft window's id in Mail ("Show in Mail" brings it to the
    /// front); nil in chats saved before.
    var draftID: Int? = nil
    /// Set when the draft is Mail's own reply window: Mail chose its
    /// recipients and subject and added the quote and signature, and `body`
    /// (the text Orbit wrote) is not in it but goes to the clipboard for the
    /// user to paste. nil for new messages (with `body` in the window) and in
    /// chats saved before.
    var reply: MailReplyInfo? = nil
}

/// How a reply draft was opened (`MailDraftItem.reply`).
struct MailReplyInfo: Sendable, Hashable, Codable {
    /// Answers everyone who got the message, not only the sender.
    var toAll: Bool
    /// Whether Orbit put the text on the clipboard (false: it could not, or
    /// there was no text).
    var isTextOnClipboard: Bool
}

struct NoteItem: Sendable, Hashable, Codable, Identifiable {
    /// Notes' note id (x-coredata://…).
    var id: String
    var title: String
    var excerpt: String?
    var folder: String?
    var modified: Date?
}

struct EventItem: Sendable, Hashable, Codable, Identifiable {
    /// Unique per row: an occurrence of a recurring event has its own.
    var id: String
    var title: String
    var start: Date
    /// All-day events: the start of the day after the last one.
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarName: String?
    /// "#RRGGBB"
    var calendarColor: String?
    var notes: String?
    /// EventKit's eventIdentifier ("Show in Calendar"); nil in chats saved before.
    var eventIdentifier: String? = nil
    /// The user declined the invitation; nil in chats saved before.
    var isDeclined: Bool? = nil
    /// The organizer canceled the event; nil in chats saved before.
    var isCanceled: Bool? = nil
    /// An occurrence of a recurring event; nil in chats saved before.
    var isRecurring: Bool? = nil
    /// Orbit created the event (`create_event`): the card says so; nil otherwise.
    var wasCreated: Bool? = nil
}

struct ReminderItem: Sendable, Hashable, Codable, Identifiable {
    /// EventKit's calendarItemIdentifier ("Show in Reminders").
    var id: String
    var title: String
    var due: Date?
    var dueHasTime: Bool
    var isCompleted: Bool
    var listName: String?
    /// "#RRGGBB"
    var listColor: String?
    var notes: String?
    /// When it was completed; nil when it is open and in chats saved before.
    var completionDate: Date? = nil
    /// Orbit created the reminder (`create_reminder`): the card says so; nil otherwise.
    var wasCreated: Bool? = nil
}

struct ContactItem: Sendable, Hashable, Codable, Identifiable {
    var id: String
    var name: String
    var organization: String?
    var emails: [String]
    var phones: [String]
}

struct PhotoItem: Sendable, Hashable, Codable, Identifiable {
    enum MediaType: String, Sendable, Hashable, Codable {
        case image
        case video
        case livePhoto
        case other
    }

    /// PHAsset.localIdentifier
    var id: String
    var creationDate: Date?
    var mediaType: MediaType
    var isFavorite: Bool
    /// Seconds, for videos.
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// A screenshot (Photos' "Bildschirmfotos"); nil otherwise and in chats saved before.
    var isScreenshot: Bool? = nil
}

struct InfoItem: Sendable, Hashable, Codable {
    var title: String
    var detail: String?
    /// SF Symbol name.
    var systemImage: String
}
