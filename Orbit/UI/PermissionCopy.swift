import SwiftUI

/// What Settings → Permissions and the onboarding say about each
/// permission: why Orbit needs it, its status, what to do about it.
enum PermissionCopy {
    static func systemImage(_ permission: PermissionKind) -> String {
        switch permission {
        case .contacts: "person.crop.circle"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .photos: "photo.on.rectangle"
        case .automationMail: "envelope"
        case .automationNotes: "note.text"
        case .automationFinder: "folder"
        case .automationSystemEvents: "gearshape.2"
        case .automationPhotos: "photo"
        case .accessibility: "accessibility"
        case .fullDiskAccess: "internaldrive"
        }
    }

    /// The app an Apple Events permission controls, as macOS names it.
    static func appName(_ permission: PermissionKind) -> String? {
        switch permission {
        case .automationMail: String(localized: "Mail")
        case .automationNotes: String(localized: "Notes")
        case .automationFinder: String(localized: "Finder")
        case .automationSystemEvents: String(localized: "System Events")
        case .automationPhotos: String(localized: "Photos")
        default: nil
        }
    }

    /// The onboarding's headline, e.g. "Mail".
    static func headline(_ permission: PermissionKind) -> String {
        switch permission {
        case .contacts: String(localized: "Contacts")
        case .calendars: permission.displayName
        case .reminders: String(localized: "Reminders")
        case .photos: String(localized: "Photos")
        case .accessibility: String(localized: "Accessibility")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        case .automationMail, .automationNotes, .automationFinder, .automationSystemEvents, .automationPhotos:
            appName(permission) ?? permission.displayName
        }
    }

    /// What Orbit does with the permission.
    static func purpose(_ permission: PermissionKind) -> String {
        switch permission {
        case .automationMail:
            String(localized: "Search and read mail and open reply drafts in Mail. Orbit never sends mail by itself.")
        case .automationNotes:
            String(localized: "Search and read notes and, after you confirm, create new ones.")
        case .contacts:
            String(localized: "Find contacts, turn names into email addresses, show contacts in search results and address you by the name on “My Card”.")
        case .fullDiskAccess:
            String(localized: "Optional: with it, Spotlight may show your mail to Orbit. Orbit then searches all mailboxes at once and also the text of the messages, faster than through Mail.")
        case .calendars:
            String(localized: "Show events and, after you confirm, create new ones. Orbit needs full access for this.")
        case .reminders:
            String(localized: "Show reminders and, after you confirm, create new ones. Orbit needs full access for this.")
        case .photos:
            String(localized: "Find photos and videos by date, album and favorites and show them as thumbnails. The pictures themselves never go to the language model.")
        case .automationPhotos:
            String(localized: "Show a photo you click in Orbit in the Photos app.")
        case .automationFinder:
            String(localized: "Use the items selected in Finder as context for your question.")
        case .automationSystemEvents:
            String(localized: "Switch between the light and dark appearance after you confirm.")
        case .accessibility:
            String(localized: "Use the selected text and the window title of the frontmost app as context for your question. Password fields are never read.")
        }
    }

    /// How macOS asks for the permission (onboarding).
    static func howMacOSAsks(_ permission: PermissionKind) -> String {
        if let app = appName(permission) {
            return String(format: String(localized: "macOS asks once whether Orbit may control “%1$@”. If %1$@ is not running, Orbit starts it in the background for this."), app)
        }
        switch permission {
        case .fullDiskAccess:
            return String(localized: "You turn on Full Disk Access in System Settings; macOS does not ask for it.")
        case .accessibility:
            return String(localized: "macOS shows a notice that leads to System Settings, where you turn on Orbit.")
        default:
            return String(localized: "macOS asks once whether Orbit may access it.")
        }
    }

    /// The note under an onboarding step: when Orbit reads with the
    /// permission. Accessibility and Automation: Finder serve the context of a
    /// request; while "Use the selection when opening" is on, the chips read
    /// the selection whenever the panel opens, before any question.
    static func onboardingFootnote(_ permission: PermissionKind, capturesSelectionOnOpen: Bool) -> String {
        switch permission {
        case .accessibility, .automationFinder:
            capturesSelectionOnOpen
                ? String(localized: "When you open Orbit, it takes your current selection as a chip above the input field; it reaches the language model only with your message. To turn this off: Settings > General > “Use the selection when opening”.")
                : String(localized: "Orbit reads your selection only when the assistant checks what you have in front of you for a question. What goes to the language model is shown in the chat below the answer.")
        default:
            String(localized: "Orbit reads only what you ask about. What goes to the language model is shown in the chat below the answer.")
        }
    }

    /// The help of "Skip" on an onboarding step: what is missing
    /// without the permission. Without Accessibility or Automation: Finder no
    /// tool is switched off; that part of the context is left out.
    static func skipHelp(_ permission: PermissionKind) -> String {
        switch permission {
        case .accessibility:
            String(localized: "Without this access, Orbit takes neither selected text nor window titles; no tool is turned off. You can allow it later in Settings.")
        case .automationFinder:
            String(localized: "Without this access, Orbit takes no selection from Finder; no tool is turned off. You can allow it later in Settings.")
        default:
            String(localized: "Without this access, the related tools stay off. You can allow it later in Settings.")
        }
    }

    /// Where the permission is in System Settings → Privacy & Security.
    static func settingsPane(_ permission: PermissionKind) -> String {
        switch permission {
        case .contacts: String(localized: "Contacts")
        case .calendars: permission.displayName
        case .reminders: String(localized: "Reminders")
        case .photos: String(localized: "Photos")
        case .automationMail, .automationNotes, .automationFinder, .automationSystemEvents, .automationPhotos:
            String(localized: "Automation")
        case .accessibility: String(localized: "Accessibility")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        }
    }

    // MARK: Status

    /// nil: not read yet.
    /// What VoiceOver hears after "Allow…": the permission and its status now
    /// ("Automation: Mail: Erlaubt").
    static func requestOutcome(_ permission: PermissionKind, status: PermissionStatus?) -> String {
        String(format: String(localized: "%1$@: %2$@"), permission.displayName, statusTitle(status))
    }

    /// What VoiceOver hears after "Allow…" for a permission the user turns
    /// on in System Settings (Accessibility): how macOS asks, not the status,
    /// asking only shows macOS's hint, so it still reads "Not allowed".
    static func requestNextStep(_ permission: PermissionKind) -> String {
        String(format: String(localized: "%1$@: %2$@"), permission.displayName, howMacOSAsks(permission))
    }

    static func statusTitle(_ status: PermissionStatus?) -> String {
        switch status {
        case nil: String(localized: "Checking…")
        case .granted: String(localized: "Allowed")
        case .denied: String(localized: "Not allowed")
        case .notDetermined: String(localized: "Not asked yet")
        case .restricted: String(localized: "Restricted")
        case .unknown: String(localized: "Unknown")
        case .writeOnly: String(localized: "Add Only")
        }
    }

    static func statusImage(_ status: PermissionStatus?) -> String {
        switch status {
        case nil, .unknown: "questionmark.circle"
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        case .restricted: "lock.circle.fill"
        case .writeOnly: "plus.circle.fill"
        }
    }

    static func statusColor(_ status: PermissionStatus?) -> Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .restricted, .writeOnly: .orange
        case nil, .notDetermined, .unknown: .secondary
        }
    }

    /// A note for the current status, if it needs one.
    static func hint(_ permission: PermissionKind, status: PermissionStatus?) -> String? {
        switch status {
        case .denied:
            if permission == .fullDiskAccess {
                return String(localized: "Turn on Orbit in System Settings > Privacy & Security > Full Disk Access, then restart Orbit.")
            }
            return String(format: String(localized: "You can allow it in System Settings > Privacy & Security > %@."),
                          settingsPane(permission))
        case .restricted:
            return String(localized: "A profile or Screen Time does not allow this access.")
        case .writeOnly:
            return String(format: String(localized: "Orbit may only add new items but cannot read any, which is not enough. In System Settings > Privacy & Security > %@, choose “Full Access” for Orbit."),
                          settingsPane(permission))
        case .unknown:
            if let app = appName(permission) {
                return String(format: String(localized: "macOS reports the status only while %@ is running."), app)
            }
            return String(localized: "The status cannot be checked right now.")
        case nil, .granted, .notDetermined:
            return nil
        }
    }

    /// Whether the status note is a warning (orange): the tools are off.
    static func isWarning(_ status: PermissionStatus?) -> Bool {
        status == .denied || status == .restricted || status == .writeOnly
    }

    // MARK: Actions

    /// The button of a permission: ask macOS, or open System Settings.
    static func actionTitle(_ permission: PermissionKind, status: PermissionStatus?) -> String {
        guard let status, permission.canRequest(from: status) else {
            return String(localized: "System Settings…")
        }
        return status == .unknown ? String(localized: "Check…") : String(localized: "Allow…")
    }

    /// VoiceOver and Voice Control: the button (`actionTitle`) with the
    /// permission it belongs to; the label contains the visible title, so
    /// "Click Check" finds "Check Automation: Mail".
    static func actionAccessibilityLabel(_ permission: PermissionKind, status: PermissionStatus?) -> String {
        guard let status, permission.canRequest(from: status) else {
            return String(format: String(localized: "Open System Settings for %@"), permission.displayName)
        }
        return status == .unknown ? String(format: String(localized: "Check %@"), permission.displayName)
            : requestAccessibilityLabel(permission)
    }

    /// VoiceOver and Voice Control: "Allow…" (the onboarding's button) with
    /// the permission it asks for.
    static func requestAccessibilityLabel(_ permission: PermissionKind) -> String {
        String(format: String(localized: "Allow %@"), permission.displayName)
    }
}

/// What VoiceOver hears of "Allow…" in Settings → Permissions and the
/// onboarding: macOS's answer at once, except for Accessibility, which macOS
/// only lets the user turn on in System Settings: asking shows macOS's hint and
/// returns before the user could decide. Then VoiceOver hears where to turn
/// Orbit on, and the new status once Orbit reads one (back from System Settings).
struct PermissionAnswers {
    /// Asked for, decided in System Settings: the status right after asking.
    private var awaited: [PermissionKind: PermissionStatus] = [:]

    /// "Allow…" returned with `status`: what VoiceOver hears now.
    mutating func requested(_ permission: PermissionKind, status: PermissionStatus?) -> String {
        guard permission == .accessibility, status != .granted else {
            awaited[permission] = nil
            return PermissionCopy.requestOutcome(permission, status: status)
        }
        awaited[permission] = status ?? .unknown
        return PermissionCopy.requestNextStep(permission)
    }

    /// The permissions were read again: the statuses VoiceOver hears now,
    /// each awaited one once, when it changed.
    mutating func statusesRead(_ statuses: [PermissionKind: PermissionStatus]) -> [String] {
        PermissionKind.displayOrder.compactMap { permission in
            guard let asked = awaited[permission], let status = statuses[permission], status != asked else { return nil }
            awaited[permission] = nil
            return PermissionCopy.requestOutcome(permission, status: status)
        }
    }
}
