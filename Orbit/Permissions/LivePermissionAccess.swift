import AppKit
import ApplicationServices
import CoreServices
import EventKit
import Foundation
import Photos
import os

/// The permissions of this Mac, read and requested through macOS's own APIs.
///
/// Reading never asks the user and reads nothing personal: Contacts, Calendar
/// and Photos report only their authorization; the Apple Events check
/// (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`)
/// sends no event and answers only while the target app runs (otherwise
/// `.unknown`); Full Disk Access is probed by opening Mail's store folder and
/// closing it again, without reading it.
///
/// `request` runs only after the user clicked "Allow…": it shows macOS's
/// prompt. For Apple Events macOS can only ask while the target app runs, so
/// an app that is not running (Mail, Notes, …) is started in the background
/// first (hidden, not activated) and keeps running afterwards.
struct LivePermissionAccess: PermissionAccessing {
    /// How long `request` waits for an app it started before asking.
    static let launchTimeout: Duration = .seconds(15)

    let contactBook: any ContactBook
    /// Opened (and closed) to find out whether Orbit has Full Disk Access:
    /// Mail's store, `~/Library/Mail`.
    let fullDiskAccessProbe: URL

    init(contactBook: any ContactBook, fullDiskAccessProbe: URL) {
        self.contactBook = contactBook
        self.fullDiskAccessProbe = fullDiskAccessProbe
    }

    // MARK: Reading

    func status(of permission: PermissionKind) -> PermissionStatus {
        switch permission {
        case .contacts:
            Self.status(contactBook.access())
        case .calendars:
            Self.status(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            Self.status(EKEventStore.authorizationStatus(for: .reminder))
        case .photos:
            Self.status(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case .automationMail, .automationNotes, .automationFinder, .automationSystemEvents, .automationPhotos:
            permission.automationTargetBundleID.map {
                Self.status(appleEventsCheck: Self.checkAppleEvents(to: $0, askUserIfNeeded: false))
            } ?? .unknown
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        case .fullDiskAccess:
            Self.fullDiskAccessStatus(probing: fullDiskAccessProbe)
        }
    }

    // MARK: Asking

    func request(_ permission: PermissionKind) async -> PermissionStatus {
        switch permission {
        case .contacts:
            return Self.status(await contactBook.requestAccess())
        case .calendars:
            _ = try? await EKEventStore().requestFullAccessToEvents()
            return Self.status(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
            return Self.status(EKEventStore.authorizationStatus(for: .reminder))
        case .photos:
            return Self.status(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        case .automationMail, .automationNotes, .automationFinder, .automationSystemEvents, .automationPhotos:
            return await requestAppleEvents(permission)
        case .accessibility:
            // Shows macOS's dialog that leads to System Settings when Orbit is not trusted yet.
            let trusted = await MainActor.run {
                AXIsProcessTrustedWithOptions([Self.accessibilityPromptOption: true] as CFDictionary)
            }
            return trusted ? .granted : .denied
        case .fullDiskAccess:
            // macOS has no prompt for Full Disk Access; only System Settings grants it.
            return Self.fullDiskAccessStatus(probing: fullDiskAccessProbe)
        }
    }

    /// `kAXTrustedCheckOptionPrompt` (its global is not concurrency-safe in Swift 6).
    static let accessibilityPromptOption = "AXTrustedCheckOptionPrompt"

    private func requestAppleEvents(_ permission: PermissionKind) async -> PermissionStatus {
        guard let bundleID = permission.automationTargetBundleID else { return .unknown }
        var check = await Self.inBackground { Self.checkAppleEvents(to: bundleID, askUserIfNeeded: false) }
        if Int(check) == procNotFound {
            guard await Self.launchInBackground(bundleID) else {
                Log.permissions.error("\(permission.rawValue, privacy: .public): the app could not be started")
                return .unknown
            }
            check = await Self.waitUntilRunning(bundleID)
        }
        guard Self.status(appleEventsCheck: check) == .notDetermined else {
            return Self.status(appleEventsCheck: check)
        }
        // Blocks until the user answered macOS's prompt.
        let answer = await Self.inBackground { Self.checkAppleEvents(to: bundleID, askUserIfNeeded: true) }
        return Self.status(appleEventsCheck: answer)
    }

    /// Starts the app hidden and without activating it, so macOS can answer for it.
    @MainActor
    private static func launchInBackground(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        Log.permissions.info("Starting an automation target in the background")
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }

    /// Checks again until the started app answers (macOS knows it only once
    /// it finished launching), at most `launchTimeout`.
    private static func waitUntilRunning(_ bundleID: String) async -> OSStatus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: launchTimeout)
        var check = OSStatus(procNotFound)
        while clock.now < deadline {
            check = await inBackground { checkAppleEvents(to: bundleID, askUserIfNeeded: false) }
            guard Int(check) == procNotFound else { return check }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return check
    }

    /// Runs blocking work on a background queue (never on the main thread).
    private static func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: System Settings

    func openSystemSettings(for permission: PermissionKind) async {
        guard let url = Self.settingsURL(for: permission) else { return }
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
    }

    /// The page in System Settings → Privacy & Security.
    static func settingsURL(for permission: PermissionKind) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + settingsAnchor(for: permission))
    }

    static func settingsAnchor(for permission: PermissionKind) -> String {
        switch permission {
        case .contacts: "Privacy_Contacts"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .photos: "Privacy_Photos"
        case .automationMail, .automationNotes, .automationFinder, .automationSystemEvents, .automationPhotos:
            "Privacy_Automation"
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        }
    }

    // MARK: Mapping (pure)

    static func status(_ access: ContactsAccess) -> PermissionStatus {
        switch access {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .unavailable: .restricted
        }
    }

    static func status(_ authorization: EKAuthorizationStatus) -> PermissionStatus {
        switch authorization {
        case .fullAccess: .granted
        // Orbit needs full access to read events: "add only" is not enough, and only System Settings changes it.
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    /// The calendar store's access as a permission status.
    static func status(_ access: CalendarAccess) -> PermissionStatus {
        switch access {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted, .unavailable: .restricted
        }
    }

    /// The photo library's access as a permission status ("limited": the
    /// photos the user shared with Orbit, enough for the tools).
    static func status(_ access: PhotoAccess) -> PermissionStatus {
        switch access {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted, .unavailable: .restricted
        }
    }

    static func status(_ authorization: PHAuthorizationStatus) -> PermissionStatus {
        switch authorization {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    /// The answer of `AEDeterminePermissionToAutomateTarget`.
    static func status(appleEventsCheck result: OSStatus) -> PermissionStatus {
        switch Int(result) {
        case Int(noErr): .granted
        case errAEEventNotPermitted: .denied
        case errAEEventWouldRequireUserConsent: .notDetermined
        // procNotFound: macOS answers only for running apps.
        default: .unknown
        }
    }

    /// Whether Orbit may send Apple Events to the app (any event: typeWildCard).
    /// Sends no event. Blocks until the user answered when `askUserIfNeeded`.
    static func checkAppleEvents(to bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard),
                                                         askUserIfNeeded)
        }
    }

    /// Full Disk Access: whether `folder` (Mail's store, which macOS protects)
    /// can be opened. Nothing is read; the folder is closed right away. A
    /// missing folder (Mail never set up) says nothing: `.unknown`.
    static func fullDiskAccessStatus(probing folder: URL) -> PermissionStatus {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        switch errno {
        case EPERM, EACCES: return .denied
        default: return .unknown
        }
    }
}
