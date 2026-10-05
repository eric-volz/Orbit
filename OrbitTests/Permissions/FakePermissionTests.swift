#if DEBUG
import Foundation
import Testing
@testable import Orbit

/// Permissions in the DEBUG fake-data mode: from the fake data, never from macOS.
@Suite("Fake permissions (DEBUG)")
struct FakePermissionTests {
    @Test func theRepositoryFixturesAllowEverything() {
        let access = FakePermissionAccess(data: FakePersonalDataTests.data())
        for permission in PermissionKind.allCases {
            #expect(access.status(of: permission) == .granted, "\(permission)")
        }
    }

    @Test func statusesFollowTheFakeData() async throws {
        let folder = try TemporaryFolder("fake-permissions")
        defer { folder.remove() }
        try folder.write("contacts.json", #"{"access": "notDetermined", "contacts": []}"#)
        try folder.write("notes.json", #"{"automation": "denied", "notes": []}"#)
        try folder.write("mails.json", #"{"automation": "denied"}"#)
        let data = FakePersonalData(directory: folder.path)
        #expect(data.errors.isEmpty)
        let access = FakePermissionAccess(data: data)
        #expect(access.status(of: .contacts) == .notDetermined)
        #expect(access.status(of: .automationNotes) == .denied)
        #expect(access.status(of: .automationMail) == .denied)
        #expect(access.status(of: .fullDiskAccess) == .granted)
        #expect(access.status(of: .calendars) == .granted)
    }

    @Test func askingAndSystemSettingsAreOnlyRecorded() async throws {
        let folder = try TemporaryFolder("fake-permissions")
        defer { folder.remove() }
        try folder.write("contacts.json", #"{"access": "notDetermined", "contacts": []}"#)
        try folder.write("notes.json", #"{"automation": "denied"}"#)
        let data = FakePersonalData(directory: folder.path)
        let access = FakePermissionAccess(data: data)
        #expect(await access.request(.contacts) == .granted, "the fake user clicks Allow")
        #expect(await access.request(.automationNotes) == .denied, "a denial stays")
        await access.openSystemSettings(for: .automationNotes)
        let state = data.stateSummary()
        #expect(state["permissionRequests"] == ["contacts", "automationNotes"])
        #expect(state["openedSystemSettings"] == ["automationNotes"])
        #expect(state["contactsAccess"] == "authorized")
        #expect(state["contactsAccessRequests"] == 1)
        #expect(access.status(of: .contacts) == .granted)
    }

    @MainActor
    @Test func theManagerOnTheFakeDataSwitchesTheToolsOff() async throws {
        let folder = try TemporaryFolder("fake-permissions")
        defer { folder.remove() }
        try folder.write("mails.json", #"{"automation": "denied"}"#)
        let services = AppServices.live(environment: [FakePersonalData.variable: folder.path],
                                        orbitDataDirectory: folder.url.appendingPathComponent("Daten"))
        let registry = ToolRegistry(tools: AppEnvironment.makeTools(services: services))
        let manager = PermissionManager(access: services.permissionAccess, tools: registry.infos)
        await manager.refresh()
        #expect(manager.statuses == [.automationMail: .denied, .automationNotes: .granted, .contacts: .granted,
                                     .calendars: .granted, .reminders: .granted, .photos: .granted, .automationPhotos: .granted,
                                     .automationSystemEvents: .granted, .fullDiskAccess: .granted])
        let off = registry.availability(disabledToolNames: [], permissions: manager).filter { !$0.isAvailable }
        #expect(off.map(\.info.name) == ["search_mail", "read_mail", "create_mail_draft"])
    }
}
#endif
