import Foundation

/// A macOS permission a tool may need. Every permission is optional: without it
/// the related tools are disabled and the agent is told why.
enum PermissionKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case contacts
    case calendars
    case reminders
    case photos
    /// Apple Events to Mail.
    case automationMail
    /// Apple Events to Notes.
    case automationNotes
    /// Apple Events to Finder (Finder selection for context chips).
    case automationFinder
    /// Apple Events to System Events (appearance, some system settings).
    case automationSystemEvents
    /// Apple Events to Photos (revealing a photo in Photos).
    case automationPhotos
    /// Selected text in the frontmost app (context chips).
    case accessibility
    /// Optional: faster mail search through Spotlight metadata.
    case fullDiskAccess

    var id: String { rawValue }

    /// The permission as Settings → Permissions names it, like System Settings > Privacy & Security.
    var displayName: String {
        switch self {
        case .contacts: String(localized: "Contacts")
        // The permission is "Calendars"; the app and a calendar field are "Calendar" (German: both "Kalender").
        case .calendars: String(localized: "Calendars")
        case .reminders: String(localized: "Reminders")
        case .photos: String(localized: "Photos")
        case .automationMail: String(localized: "Automation: Mail")
        case .automationNotes: String(localized: "Automation: Notes")
        case .automationFinder: String(localized: "Automation: Finder")
        case .automationSystemEvents: String(localized: "Automation: System Events")
        case .automationPhotos: String(localized: "Automation: Photos")
        case .accessibility: String(localized: "Accessibility")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        }
    }

    /// Bundle identifier of the automation target, for Apple Events permissions.
    var automationTargetBundleID: String? {
        switch self {
        case .automationMail: "com.apple.mail"
        case .automationNotes: "com.apple.Notes"
        case .automationFinder: "com.apple.finder"
        case .automationSystemEvents: "com.apple.systemevents"
        case .automationPhotos: "com.apple.Photos"
        default: nil
        }
    }
}

enum PermissionStatus: String, Codable, Sendable, Hashable {
    /// The user has not decided yet. Tools stay available; macOS asks on first use.
    case notDetermined
    case granted
    case denied
    case restricted
    /// Cannot be determined right now (e.g. the automation target app is not running).
    case unknown
    /// Calendars: macOS allows adding only, not reading ("Add Only",
    /// macOS 14+). Not enough for Orbit's tools, which read calendars; only
    /// System Settings changes it to full access.
    case writeOnly

    /// Whether tools needing this permission should be offered to the model.
    var allowsUse: Bool {
        switch self {
        case .granted, .notDetermined, .unknown: true
        case .denied, .restricted, .writeOnly: false
        }
    }
}

/// Read access to permission states. Implemented by `PermissionManager`; tests
/// use a fixed map.
protocol PermissionStatusProviding: Sendable {
    func status(of permission: PermissionKind) -> PermissionStatus

    /// A tool that needs these permissions just ran, or macOS refused one of
    /// them: the user may have answered macOS's prompt meanwhile. A live
    /// provider reads them again in the background (never asking the user).
    func permissionsMayHaveChanged(_ permissions: [PermissionKind])
}

extension PermissionStatusProviding {
    func permissionsMayHaveChanged(_ permissions: [PermissionKind]) {}
}

/// Grants everything. Used in tests and before the permission manager exists.
struct AllPermissionsGranted: PermissionStatusProviding {
    func status(of permission: PermissionKind) -> PermissionStatus { .granted }
}
