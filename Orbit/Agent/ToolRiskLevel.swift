import Foundation

/// How much a tool can change. Decides whether the user must confirm a call.
///
/// | Level         | Examples                                   | Behavior                  |
/// |---------------|--------------------------------------------|---------------------------|
/// | `read`        | search files, read mail, list events       | runs without confirmation |
/// | `draft`       | open a draft, open a file, launch an app   | runs without confirmation |
/// | `write`       | create note/event/reminder, change setting | confirmation card         |
/// | `destructive` | send mail, move to Trash, delete event     | confirmation + warning    |
///
/// A tool may give a single call another level (`Tool.review(_:for:)`):
/// `open_url` is `write`, but a link the user typed opens as `draft`.
enum ToolRiskLevel: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case read
    case draft
    case write
    case destructive

    var requiresConfirmation: Bool {
        self >= .write
    }

    private var rank: Int {
        switch self {
        case .read: 0
        case .draft: 1
        case .write: 2
        case .destructive: 3
        }
    }

    static func < (lhs: ToolRiskLevel, rhs: ToolRiskLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Groups tools for settings (enable/disable) and permissions.
enum ToolCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case files
    case mail
    case notes
    case calendar
    case reminders
    case contacts
    case photos
    case apps
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .files: String(localized: "Files")
        case .mail: String(localized: "Mail")
        case .notes: String(localized: "Notes")
        case .calendar: String(localized: "Calendar")
        case .reminders: String(localized: "Reminders")
        case .contacts: String(localized: "Contacts")
        case .photos: String(localized: "Photos")
        case .apps: String(localized: "Apps")
        case .system: String(localized: "System")
        }
    }

    /// SF Symbol name.
    var systemImage: String {
        switch self {
        case .files: "doc"
        case .mail: "envelope"
        case .notes: "note.text"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .apps: "square.grid.2x2"
        case .system: "gearshape"
        }
    }
}
