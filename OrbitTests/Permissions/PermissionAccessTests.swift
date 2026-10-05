import AppKit
import CoreServices
import EventKit
import Foundation
import Photos
import Testing
@testable import Orbit

/// The live permission access without touching the system: the pure mappings,
/// the System Settings links, Full Disk Access probed on temporary folders and
/// Contacts through a mock contact book. The Apple Events, Calendar, Photos and
/// Accessibility APIs themselves are never called here.
@Suite("Live permission access")
struct PermissionAccessTests {
    @Test(arguments: [
        (OSStatus(noErr), PermissionStatus.granted),
        (OSStatus(errAEEventNotPermitted), .denied),
        (OSStatus(errAEEventWouldRequireUserConsent), .notDetermined),
        (OSStatus(procNotFound), .unknown),
        (OSStatus(-1_708), .unknown),
    ])
    func appleEventsAnswers(result: OSStatus, expected: PermissionStatus) {
        #expect(LivePermissionAccess.status(appleEventsCheck: result) == expected)
    }

    @Test func appleEventsCodesAreMacOSs() {
        #expect(errAEEventNotPermitted == -1_743)
        #expect(errAEEventWouldRequireUserConsent == -1_744)
        #expect(procNotFound == -600)
    }

    @Test func contactsAccessMapsToStatuses() {
        #expect(LivePermissionAccess.status(ContactsAccess.authorized) == .granted)
        #expect(LivePermissionAccess.status(ContactsAccess.notDetermined) == .notDetermined)
        #expect(LivePermissionAccess.status(ContactsAccess.denied) == .denied)
        #expect(LivePermissionAccess.status(ContactsAccess.unavailable) == .restricted)
    }

    /// D2: "add only" (write-only) access is not enough: the tools read
    /// calendars, and only System Settings changes it to full access.
    @Test func calendarAccessNeedsFullAccess() {
        #expect(LivePermissionAccess.status(EKAuthorizationStatus.fullAccess) == .granted)
        #expect(LivePermissionAccess.status(EKAuthorizationStatus.writeOnly) == .writeOnly)
        #expect(LivePermissionAccess.status(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(LivePermissionAccess.status(EKAuthorizationStatus.denied) == .denied)
        #expect(LivePermissionAccess.status(EKAuthorizationStatus.restricted) == .restricted)
        #expect(!PermissionStatus.writeOnly.allowsUse, "the calendar tools are switched off")
        #expect(!PermissionKind.calendars.canRequest(from: .writeOnly), "System Settings, not a prompt")
        #expect(PermissionCopy.actionTitle(.calendars, status: .writeOnly) == "System Settings…")

        #expect(LiveCalendarStore.access(EKAuthorizationStatus.fullAccess) == .fullAccess)
        #expect(LiveCalendarStore.access(EKAuthorizationStatus.writeOnly) == .writeOnly)
        #expect(LiveCalendarStore.access(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(LiveCalendarStore.access(EKAuthorizationStatus.denied) == .denied)
        #expect(LiveCalendarStore.access(EKAuthorizationStatus.restricted) == .restricted)
        let statuses: [CalendarAccess: PermissionStatus] = [.fullAccess: .granted, .writeOnly: .writeOnly,
                                                            .notDetermined: .notDetermined, .denied: .denied,
                                                            .restricted: .restricted, .unavailable: .restricted]
        for (access, status) in statuses {
            #expect(LivePermissionAccess.status(access) == status, "\(access)")
        }
    }

    /// The new status keeps the stored statuses as they were (old raw values decode).
    @Test func permissionStatusesKeepTheirRawValues() throws {
        let raw = ["notDetermined", "granted", "denied", "restricted", "unknown", "writeOnly"]
        for value in raw {
            let decoded = try JSONDecoder().decode(PermissionStatus.self, from: Data("\"\(value)\"".utf8))
            #expect(decoded.rawValue == value)
        }
    }

    @Test func photosAccessMapsToStatuses() {
        #expect(LivePermissionAccess.status(PHAuthorizationStatus.authorized) == .granted)
        #expect(LivePermissionAccess.status(PHAuthorizationStatus.limited) == .granted)
        #expect(LivePermissionAccess.status(PHAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(LivePermissionAccess.status(PHAuthorizationStatus.denied) == .denied)
        #expect(LivePermissionAccess.status(PHAuthorizationStatus.restricted) == .restricted)
    }

    @Test func systemSettingsOpenThePrivacyPageOfThePermission() throws {
        let expected: [PermissionKind: String] = [
            .contacts: "Privacy_Contacts", .calendars: "Privacy_Calendars", .reminders: "Privacy_Reminders",
            .photos: "Privacy_Photos", .automationMail: "Privacy_Automation", .automationNotes: "Privacy_Automation",
            .automationFinder: "Privacy_Automation", .automationSystemEvents: "Privacy_Automation",
            .automationPhotos: "Privacy_Automation", .accessibility: "Privacy_Accessibility",
            .fullDiskAccess: "Privacy_AllFiles",
        ]
        for permission in PermissionKind.allCases {
            let url = try #require(LivePermissionAccess.settingsURL(for: permission))
            #expect(url.scheme == "x-apple.systempreferences")
            #expect(url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?" + (expected[permission] ?? "?"))
        }
    }

    @Test func accessibilityPromptOptionIsMacOSsKey() {
        #expect(LivePermissionAccess.accessibilityPromptOption == "AXTrustedCheckOptionPrompt")
    }

    // MARK: Full Disk Access

    @Test func fullDiskAccessIsGrantedWhenTheFolderOpens() throws {
        let folder = try TemporaryFolder("fda-probe")
        defer { folder.remove() }
        let store = try folder.makeFolder("Library/Mail")
        try folder.write("Library/Mail/V10/secret.emlx", "never read")
        #expect(LivePermissionAccess.fullDiskAccessStatus(probing: store) == .granted)
    }

    @Test func fullDiskAccessIsDeniedWhenOpeningIsRefused() throws {
        let folder = try TemporaryFolder("fda-probe")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path + "/Mail")
            folder.remove()
        }
        let store = try folder.makeFolder("Mail")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        #expect(LivePermissionAccess.fullDiskAccessStatus(probing: store) == .denied)
    }

    @Test func fullDiskAccessIsUnknownWithoutMailsFolder() throws {
        let folder = try TemporaryFolder("fda-probe")
        defer { folder.remove() }
        #expect(LivePermissionAccess.fullDiskAccessStatus(probing: folder.url.appendingPathComponent("Library/Mail")) == .unknown)
        let file = try folder.write("Mail", "not a folder")
        #expect(LivePermissionAccess.fullDiskAccessStatus(probing: file) == .unknown)
    }

    @Test func fullDiskAccessGoesThroughTheProbeFolder() async throws {
        let folder = try TemporaryFolder("fda-probe")
        defer { folder.remove() }
        let access = LivePermissionAccess(contactBook: MockContactBook(), fullDiskAccessProbe: try folder.makeFolder("Library/Mail"))
        #expect(access.status(of: .fullDiskAccess) == .granted)
        #expect(await access.request(.fullDiskAccess) == .granted, "there is no prompt; asking only reads again")
    }

    // MARK: Contacts

    @Test func contactsGoThroughTheContactBook() async {
        let book = MockContactBook(access: .notDetermined, grantOnRequest: true)
        let access = LivePermissionAccess(contactBook: book, fullDiskAccessProbe: URL(fileURLWithPath: "/nonexistent/Mail"))
        #expect(access.status(of: .contacts) == .notDetermined)
        #expect(book.accessRequests == 0, "reading never asks")
        #expect(await access.request(.contacts) == .granted)
        #expect(book.accessRequests == 1)
        let refusing = MockContactBook(access: .notDetermined, grantOnRequest: false)
        let refused = LivePermissionAccess(contactBook: refusing, fullDiskAccessProbe: URL(fileURLWithPath: "/nonexistent/Mail"))
        #expect(await refused.request(.contacts) == .denied)
    }
}

@Suite("Permission wiring")
struct PermissionWiringTests {
    @Test func liveServicesReadTheRealPermissionsAndProbeMailsStore() throws {
        // Constructed only: nothing is read or asked for.
        let services = AppServices.live(environment: ["HOME": NSHomeDirectory()],
                                        orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-live"))
        let access = try #require(services.permissionAccess as? LivePermissionAccess)
        #expect(access.fullDiskAccessProbe.path == services.fileScope.homeDirectory + "/Library/Mail")
        #expect(access.contactBook is LiveContactBook)
    }

    @Test func aRestrictedDebugSessionNeverReadsOrAsks() throws {
        let folder = try TemporaryFolder("restricted-permissions")
        defer { folder.remove() }
        let services = AppServices.live(environment: [FileSearchScope.debugScopeVariable: folder.path],
                                        orbitDataDirectory: folder.url.appendingPathComponent("Daten"))
        #expect(services.permissionAccess is FixedPermissionAccess)
        #expect(services.permissionAccess.status(of: .automationMail) == .granted,
                "unchanged: the tools run and say that Mail is off in this session")
    }

    #if DEBUG
    @Test func theFakeDataModeAnswersFromTheFakeData() throws {
        let folder = try TemporaryFolder("fake-permissions")
        defer { folder.remove() }
        let services = AppServices.live(environment: [FakePersonalData.variable: folder.path],
                                        orbitDataDirectory: folder.url.appendingPathComponent("Daten"))
        #expect(services.permissionAccess is FakePermissionAccess)
    }
    #endif

    @Test func handBuiltServicesGrantEverythingWithoutTheSystem() {
        let services = AppServices(spotlight: MockSpotlight(), workspace: MockWorkspace(),
                                   fileScope: FileSearchScope.restricted(to: "/nonexistent", homeDirectory: "/nonexistent"),
                                   fileAccess: FileAccessPolicy(homeDirectory: "/nonexistent", orbitDataDirectory: "/nonexistent/Orbit",
                                                                restriction: "/nonexistent"),
                                   appIndex: FakeAppIndex(), contacts: MockContactSearch(), searchOpener: MockSearchOpener(),
                                   launchCounts: InMemoryLaunchCounts(), quickLookPanel: FakeQuickLookPanel(),
                                   announcer: RecordingAnnouncer())
        #expect(services.permissionAccess is FixedPermissionAccess)
    }
}

@Suite("Permission texts")
@MainActor
struct PermissionCopyTests {
    @Test func everyPermissionIsExplained() {
        for permission in PermissionKind.allCases {
            #expect(NSImage(systemSymbolName: PermissionCopy.systemImage(permission), accessibilityDescription: nil) != nil,
                    "\(permission): SF Symbol exists")
            #expect(!PermissionCopy.purpose(permission).isEmpty)
            #expect(!PermissionCopy.headline(permission).isEmpty)
            #expect(!PermissionCopy.howMacOSAsks(permission).isEmpty)
            #expect(!PermissionCopy.settingsPane(permission).isEmpty)
            #expect((PermissionCopy.appName(permission) != nil) == permission.isAutomation)
        }
        #expect(PermissionCopy.purpose(.automationMail).contains("never sends"))
        #expect(PermissionCopy.howMacOSAsks(.automationNotes).contains("“Notes”"))
        #expect(PermissionCopy.howMacOSAsks(.automationNotes).contains("in the background"))
    }

    @Test func statusWordsAndColors() {
        #expect(PermissionCopy.statusTitle(nil) == "Checking…")
        #expect(PermissionCopy.statusTitle(.granted) == "Allowed")
        #expect(PermissionCopy.statusTitle(.denied) == "Not allowed")
        #expect(PermissionCopy.statusTitle(.notDetermined) == "Not asked yet")
        #expect(PermissionCopy.statusTitle(.restricted) == "Restricted")
        #expect(PermissionCopy.statusTitle(.unknown) == "Unknown")
        for status in [PermissionStatus.granted, .denied, .notDetermined, .restricted, .unknown] {
            #expect(NSImage(systemSymbolName: PermissionCopy.statusImage(status), accessibilityDescription: nil) != nil)
        }
    }

    @Test func hintsSayWhatToDo() {
        #expect(PermissionCopy.hint(.automationMail, status: .denied)
            == "You can allow it in System Settings > Privacy & Security > Automation.")
        #expect(PermissionCopy.hint(.contacts, status: .denied)?.hasSuffix("> Contacts.") == true)
        #expect(PermissionCopy.hint(.fullDiskAccess, status: .denied)?.contains("restart Orbit") == true)
        #expect(PermissionCopy.hint(.automationNotes, status: .unknown) == "macOS reports the status only while Notes is running.")
        #expect(PermissionCopy.hint(.fullDiskAccess, status: .unknown) == "The status cannot be checked right now.")
        #expect(PermissionCopy.hint(.contacts, status: .granted) == nil)
        #expect(PermissionCopy.hint(.contacts, status: .notDetermined) == nil)
        #expect(PermissionCopy.hint(.contacts, status: nil) == nil)
        #expect(PermissionCopy.hint(.photos, status: .restricted)?.contains("Screen Time") == true)
    }

    @Test func theButtonAsksMacOSOrOpensSystemSettings() {
        #expect(PermissionCopy.actionTitle(.contacts, status: .notDetermined) == "Allow…")
        #expect(PermissionCopy.actionTitle(.automationMail, status: .notDetermined) == "Allow…")
        #expect(PermissionCopy.actionTitle(.automationMail, status: .unknown) == "Check…")
        #expect(PermissionCopy.actionTitle(.automationMail, status: .denied) == "System Settings…")
        #expect(PermissionCopy.actionTitle(.contacts, status: .granted) == "System Settings…")
        #expect(PermissionCopy.actionTitle(.fullDiskAccess, status: .denied) == "System Settings…")
        #expect(PermissionCopy.actionAccessibilityLabel(.contacts, status: .notDetermined) == "Allow Contacts")
        #expect(PermissionCopy.actionAccessibilityLabel(.automationMail, status: .denied)
            == "Open System Settings for Automation: Mail")
    }

    @Test func toolsShowTheirMissingPermission() {
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let mail = PermissionTestTools.info("search_mail", [.automationMail])
        let files = PermissionTestTools.info("search_files", [], category: .files)
        let view = ToolsSettingsView(settings: settings, tools: [mail, files],
                                     permissionStatuses: [.automationMail: .denied, .contacts: .granted])
        #expect(view.missingPermission(of: mail) == .automationMail)
        #expect(view.missingPermission(of: files) == nil)
        for status in [PermissionStatus.granted, .notDetermined, .unknown] {
            let allowed = ToolsSettingsView(settings: settings, tools: [mail], permissionStatuses: [.automationMail: status])
            #expect(allowed.missingPermission(of: mail) == nil)
        }
        #expect(ToolsSettingsView(settings: settings, tools: [mail]).missingPermission(of: mail) == nil, "not read yet")
    }

    @Test func theSettingsTabSitsBetweenToolsAndPrivacy() {
        #expect(SettingsTab.allCases == [.general, .model, .tools, .permissions, .privacy])
        #expect(SettingsTab.permissions.title == "Permissions")
        #expect(SettingsTab.permissions.systemImage == "lock.shield")
        #expect(NSImage(systemSymbolName: SettingsTab.permissions.systemImage, accessibilityDescription: nil) != nil)
    }

    @Test func mailSearchModeTexts() {
        #expect(PermissionsSettingsView.modeTitle(.spotlight) == "Through Spotlight")
        #expect(PermissionsSettingsView.modeTitle(.appleScript) == "Through Mail")
        #expect(PermissionsSettingsView.modeExplanation(.appleScript).contains("Full Disk Access"))
        #expect(PermissionsSettingsView.modeExplanation(.appleScript).contains("searches only subjects and senders"))
        #expect(PermissionsSettingsView.modeExplanation(.spotlight).contains("also in the text of the messages"))
        #expect(PermissionsSettingsView.modeExplanation(nil).contains("No message is read"))
    }
}
