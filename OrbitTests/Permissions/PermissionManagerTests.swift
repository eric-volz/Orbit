import Foundation
import Testing
@testable import Orbit

@Suite("Permission manager")
@MainActor
struct PermissionManagerTests {
    private static let phase3: [PermissionKind] = [.automationMail, .automationNotes, .contacts, .fullDiskAccess]

    private func manager(_ access: MockPermissionAccess, _ permissions: [PermissionKind] = phase3) -> PermissionManager {
        PermissionManager(access: access, permissions: permissions)
    }

    // MARK: Which permissions

    @Test func theAppAsksForWhatItsToolsNeedPlusFullDiskAccess() {
        let manager = PermissionManager(access: MockPermissionAccess(), tools: PermissionTestTools.app)
        #expect(manager.permissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
                                        .automationPhotos, .automationSystemEvents, .fullDiskAccess])
        #expect(manager.toolPermissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
                                            .automationSystemEvents],
                "Automation: Photos only shows photos in Photos and never switches search_photos off; set_appearance needs System Events")
        #expect(manager.onboardingPermissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos],
                "Full Disk Access is optional and Automation: Photos and System Events asked on first use: all only in Settings")
    }

    /// A denied Automation: Photos keeps search_photos; denied Photos switches it off.
    @Test func photosAndTheirAutomation() async {
        let access = MockPermissionAccess([.automationPhotos: .denied])
        let manager = PermissionManager(access: access, tools: PermissionTestTools.app)
        await manager.refresh()
        let registry = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake()))
        #expect(registry.availability(disabledToolNames: [], permissions: manager).allSatisfy { $0.isAvailable })
        access.set(.denied, for: .photos)
        await manager.refresh()
        let off = registry.availability(disabledToolNames: [], permissions: manager).filter { !$0.isAvailable }
        #expect(off.map(\.info.name) == ["search_photos"])
        #expect(off.first?.unavailableReason == .permissionMissing(.photos))
    }

    /// D2: with "add only" access the calendar tools are switched off.
    @Test func addOnlyCalendarAccessSwitchesTheCalendarToolsOff() async {
        let access = MockPermissionAccess([.calendars: .writeOnly])
        let manager = PermissionManager(access: access, tools: PermissionTestTools.app)
        await manager.refresh()
        let registry = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake()))
        let off = registry.availability(disabledToolNames: [], permissions: manager).filter { !$0.isAvailable }
        #expect(off.map(\.info.name) == ["list_events", "create_event"])
        #expect(off.allSatisfy { $0.unavailableReason == .permissionMissing(.calendars) })
        #expect(PermissionManager.merged(previous: .writeOnly, reading: .unknown, for: .calendars) == .unknown)
    }

    @Test func permissionsFollowTheRegisteredToolsInDisplayOrder() {
        let notes = [PermissionTestTools.info("search_notes", [.automationNotes], category: .notes)]
        #expect(PermissionManager.permissions(for: notes) == [.automationNotes], "no Full Disk Access without mail tools")
        #expect(PermissionManager.permissions(for: []).isEmpty)
        let later = [
            PermissionTestTools.info("context", [.accessibility, .automationFinder], category: .system),
            PermissionTestTools.info("search_photos", [.photos], category: .photos),
            PermissionTestTools.info("list_events", [.calendars], category: .calendar),
            PermissionTestTools.info("read_mail", [.automationMail]),
            PermissionTestTools.info("search_mail", [.automationMail]),
        ]
        #expect(PermissionManager.permissions(for: later)
            == [.automationMail, .calendars, .photos, .automationPhotos, .automationFinder, .accessibility, .fullDiskAccess],
                "photo cards show photos in Photos (Automation: Photos)")
        let manager = PermissionManager(access: MockPermissionAccess(), tools: later)
        #expect(manager.toolPermissions == [.automationMail, .calendars, .photos, .automationFinder, .accessibility])
        #expect(Set(PermissionKind.displayOrder) == Set(PermissionKind.allCases))
        #expect(PermissionKind.displayOrder.count == PermissionKind.allCases.count)
    }

    // MARK: Reading

    @Test func everythingIsUnknownUntilRead() {
        let access = MockPermissionAccess([.automationMail: .denied])
        let manager = manager(access)
        #expect(manager.statuses.isEmpty)
        #expect(manager.status(of: .automationMail) == .unknown)
        #expect(manager.status(of: .automationMail).allowsUse, "tools stay available until macOS answered")
        #expect(access.reads.isEmpty)
    }

    @Test func refreshReadsOffTheMainThreadAndStoresTheStatuses() async {
        let access = MockPermissionAccess([.automationMail: .denied, .contacts: .notDetermined, .fullDiskAccess: .unknown])
        let manager = manager(access)
        await manager.refresh()
        #expect(access.reads == Self.phase3)
        #expect(access.readsOnMainThread == 0)
        #expect(manager.statuses == [.automationMail: .denied, .automationNotes: .granted, .contacts: .notDetermined,
                                     .fullDiskAccess: .unknown])
        #expect(manager.status(of: .automationMail) == .denied)
        #expect(manager.status(of: .contacts) == .notDetermined)
        // A permission Orbit does not use is never read.
        #expect(manager.status(of: .photos) == .unknown)
    }

    @Test func refreshReadsOnlyTheGivenPermissionsOnce() async {
        let access = MockPermissionAccess()
        let manager = manager(access)
        await manager.refresh([.contacts, .contacts, .automationNotes])
        #expect(access.reads == [.contacts, .automationNotes])
        #expect(manager.statuses.keys.sorted { $0.rawValue < $1.rawValue } == [.automationNotes, .contacts])
    }

    @Test func statusesAreReadableFromAnyThread() async {
        let access = MockPermissionAccess([.automationNotes: .denied])
        let manager = manager(access)
        await manager.refresh()
        let status = await Task.detached { manager.status(of: .automationNotes) }.value
        #expect(status == .denied)
    }

    @Test func aChangeShowsAfterTheNextReading() async {
        let access = MockPermissionAccess([.contacts: .notDetermined])
        let manager = manager(access)
        await manager.refresh()
        access.set(.denied, for: .contacts)
        #expect(manager.status(of: .contacts) == .notDetermined)
        await manager.refresh([.contacts])
        #expect(manager.status(of: .contacts) == .denied)
        #expect(manager.statuses[.contacts] == .denied)
    }

    @Test func toolRunsReadTheirPermissionsAgain() async {
        let access = MockPermissionAccess([.automationMail: .notDetermined])
        let manager = manager(access)
        await manager.refresh()
        access.set(.denied, for: .automationMail)
        manager.permissionsMayHaveChanged([.automationMail])
        #expect(await AgentHarness.eventually { manager.status(of: .automationMail) == .denied })
        #expect(access.reads.suffix(1) == [.automationMail])
        // Nothing to read.
        let count = access.reads.count
        manager.permissionsMayHaveChanged([])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(access.reads.count == count)
    }

    @Test func startingOrQuittingAnAppReadsItsAutomationPermission() async {
        let access = MockPermissionAccess()
        let manager = manager(access)
        manager.appDidLaunchOrQuit(bundleIdentifier: "com.apple.mail")
        #expect(await AgentHarness.eventually { access.reads == [.automationMail] })
        manager.appDidLaunchOrQuit(bundleIdentifier: "com.apple.notes")
        #expect(await AgentHarness.eventually { access.reads == [.automationMail, .automationNotes] },
                "bundle identifiers compare ignoring case (Notes is com.apple.Notes)")
        manager.appDidLaunchOrQuit(bundleIdentifier: "com.apple.Safari")
        manager.appDidLaunchOrQuit(bundleIdentifier: "com.apple.finder")
        manager.appDidLaunchOrQuit(bundleIdentifier: nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(access.reads == [.automationMail, .automationNotes], "Finder is not used by this manager")
    }

    @Test func openingThePanelReadsTheToolPermissionsAtMostEveryFewSeconds() async {
        let access = MockPermissionAccess()
        let manager = manager(access)
        let clock = AgentTestClock()
        manager.now = { clock.now }
        manager.refreshIfStale()
        #expect(await AgentHarness.eventually { access.reads.count == 3 })
        #expect(access.reads == [.automationMail, .automationNotes, .contacts], "Full Disk Access is not probed each time")
        clock.advance(by: PermissionManager.staleInterval - 0.5)
        manager.refreshIfStale()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(access.reads.count == 3)
        clock.advance(by: 1)
        manager.refreshIfStale()
        #expect(await AgentHarness.eventually { access.reads.count == 6 })
    }

    @Test func startReadsEverythingOnceAndCountsAsARecentReading() async {
        let access = MockPermissionAccess()
        let manager = manager(access)
        manager.now = { Date(timeIntervalSince1970: 1_000_000) }
        manager.start()
        defer { manager.stop() }
        #expect(await AgentHarness.eventually { manager.statuses.count == Self.phase3.count })
        manager.start()
        manager.refreshIfStale()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(access.reads == Self.phase3, "a second start and an immediate panel opening read nothing")
    }

    // MARK: Asking

    @Test func requestAsksMacOSAndStoresTheAnswer() async {
        let access = MockPermissionAccess([.contacts: .notDetermined])
        access.answer(.contacts, with: .granted)
        let manager = manager(access)
        await manager.refresh()
        await manager.request(.contacts)
        #expect(access.requests == [.contacts])
        #expect(manager.statuses[.contacts] == .granted)
        #expect(manager.status(of: .contacts) == .granted)
        #expect(manager.requesting.isEmpty)
    }

    @Test func aRunningRequestIsVisibleAndNotStartedTwice() async {
        let access = MockPermissionAccess([.automationNotes: .notDetermined])
        access.answer(.automationNotes, with: .denied)
        access.holdRequests()
        let manager = manager(access)
        let first = Task { await manager.request(.automationNotes) }
        #expect(await AgentHarness.eventually { manager.requesting == [.automationNotes] })
        await manager.request(.automationNotes)
        #expect(access.requests == [.automationNotes], "a click while macOS asks starts nothing")
        access.releaseRequests()
        await first.value
        #expect(manager.requesting.isEmpty)
        #expect(manager.statuses[.automationNotes] == .denied)
    }

    @Test func aReadingThatStartedBeforeTheAnswerDoesNotOverwriteIt() async {
        let access = MockPermissionAccess([.contacts: .notDetermined])
        access.answer(.contacts, with: .granted)
        let manager = manager(access)
        access.holdReadings()
        let reading = Task { await manager.refresh([.contacts]) }
        #expect(await AgentHarness.eventually { access.reads == [.contacts] })
        await manager.request(.contacts)
        #expect(manager.statuses[.contacts] == .granted)
        access.releaseReadings()
        await reading.value
        #expect(manager.statuses[.contacts] == .granted, "the older reading (not asked yet) arrived late and was dropped")
        // A reading that starts afterwards counts again.
        access.set(.denied, for: .contacts)
        await manager.refresh([.contacts])
        #expect(manager.statuses[.contacts] == .denied)
    }

    @Test func systemSettingsOpenThroughTheAccess() async {
        let access = MockPermissionAccess()
        let manager = manager(access)
        await manager.openSystemSettings(for: .fullDiskAccess)
        #expect(access.openedSettings == [.fullDiskAccess])
        #expect(access.requests.isEmpty)
    }

    // MARK: Apps that do not run

    @Test(arguments: [
        (PermissionStatus?.some(.granted), PermissionStatus.unknown, PermissionStatus.granted),
        (.some(.notDetermined), .unknown, .notDetermined),
        (.some(.denied), .unknown, .unknown),
        (.some(.unknown), .unknown, .unknown),
        (nil, .unknown, .unknown),
        (.some(.granted), .denied, .denied),
        (.some(.denied), .granted, .granted),
        (.some(.notDetermined), .granted, .granted),
    ])
    func anAppThatDoesNotRunKeepsWhatWasKnown(previous: PermissionStatus?, reading: PermissionStatus,
                                               expected: PermissionStatus) {
        #expect(PermissionManager.merged(previous: previous, reading: reading, for: .automationMail) == expected)
    }

    @Test func onlyAppleEventsPermissionsKeepTheirStatus() {
        #expect(PermissionManager.merged(previous: .granted, reading: .unknown, for: .fullDiskAccess) == .unknown)
        #expect(PermissionManager.merged(previous: .notDetermined, reading: .unknown, for: .contacts) == .unknown)
    }

    @Test func mailQuittingKeepsAGrantButNotADenial() async {
        let access = MockPermissionAccess([.automationMail: .granted, .automationNotes: .denied])
        let manager = manager(access)
        await manager.refresh()
        access.set(.unknown, for: .automationMail)
        access.set(.unknown, for: .automationNotes)
        await manager.refresh()
        #expect(manager.statuses[.automationMail] == .granted)
        #expect(manager.statuses[.automationNotes] == .unknown,
                "the user may have allowed Notes in System Settings meanwhile, so its tools come back")
        #expect(manager.status(of: .automationNotes).allowsUse)
    }

    // MARK: What can be asked

    @Test func whatMacOSCanStillAsk() {
        for permission in [PermissionKind.contacts, .calendars, .reminders, .photos] {
            #expect(permission.canRequest(from: .notDetermined))
            for status in [PermissionStatus.granted, .denied, .restricted, .unknown] {
                #expect(!permission.canRequest(from: status), "\(permission) \(status)")
            }
        }
        for permission in PermissionKind.allCases where permission.isAutomation {
            #expect(permission.canRequest(from: .notDetermined))
            #expect(permission.canRequest(from: .unknown), "the app is started, then macOS answers")
            #expect(!permission.canRequest(from: .granted))
            #expect(!permission.canRequest(from: .denied))
        }
        for status in [PermissionStatus.granted, .denied, .notDetermined, .restricted, .unknown] {
            #expect(!PermissionKind.fullDiskAccess.canRequest(from: status), "only System Settings grants it")
        }
        #expect(PermissionKind.accessibility.canRequest(from: .denied))
        #expect(!PermissionKind.accessibility.canRequest(from: .granted))
        #expect(PermissionKind.allCases.filter(\.isAutomation)
            == [.automationMail, .automationNotes, .automationFinder, .automationSystemEvents, .automationPhotos])
    }

    @Test func fixedAccessNeverChanges() async {
        let access = FixedPermissionAccess([.contacts: .denied])
        #expect(access.status(of: .contacts) == .denied)
        #expect(access.status(of: .automationMail) == .granted)
        #expect(await access.request(.contacts) == .denied)
        await access.openSystemSettings(for: .contacts)
        #expect(FixedPermissionAccess(otherwise: .unknown).status(of: .photos) == .unknown)
    }

    // MARK: Tools

    @Test func toolsWithADeniedPermissionAreSwitchedOff() async {
        let access = MockPermissionAccess([.automationMail: .denied, .automationNotes: .notDetermined, .contacts: .unknown])
        let manager = PermissionManager(access: access, tools: PermissionTestTools.app)
        let registry = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake()))
        let before = registry.availability(disabledToolNames: [], permissions: manager)
        #expect(before.allSatisfy { $0.isAvailable }, "nothing is switched off before macOS answered")
        await manager.refresh()
        let availability = registry.availability(disabledToolNames: [], permissions: manager)
        let off = availability.filter { !$0.isAvailable }
        #expect(off.map(\.info.name) == ["search_mail", "read_mail", "create_mail_draft"])
        #expect(off.allSatisfy { $0.unavailableReason == .permissionMissing(.automationMail) })
        #expect(off.first?.reasonForModel == "macOS permission 'Automation: Mail' was not granted")
    }
}
