import Foundation
import Testing
@testable import Orbit

/// D5/D6: Accessibility and Automation: Finder belong to the context of a
/// request, listed in Settings → Permissions and the onboarding while the
/// context chips or `get_frontmost_context` are on, never switching a tool off.
@Suite("Context permissions")
@MainActor
struct ContextPermissionTests {
    @Test func theContextNeedsTwoPermissionsWhileItIsOn() {
        #expect(PermissionManager.contextPermissions(capturesSelection: true, contextToolEnabled: false) == [.automationFinder, .accessibility])
        #expect(PermissionManager.contextPermissions(capturesSelection: false, contextToolEnabled: true) == [.automationFinder, .accessibility])
        #expect(PermissionManager.contextPermissions(capturesSelection: false, contextToolEnabled: false).isEmpty)
        let tools = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos
        #expect(PermissionManager.permissions(for: tools, features: [.automationFinder, .accessibility])
            == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos, .automationPhotos,
                .automationFinder, .automationSystemEvents, .accessibility, .fullDiskAccess])
    }

    @Test func featurePermissionsAreListedAndReadWhileOn() async {
        let access = MockPermissionAccess([.accessibility: .denied])
        let manager = PermissionManager(access: access, tools: ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos)
        #expect(!manager.permissions.contains(.accessibility))
        #expect(manager.onboardingPermissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos])
        manager.featurePermissions = [.automationFinder, .accessibility]
        #expect(manager.permissions.suffix(4) == [.automationFinder, .automationSystemEvents, .accessibility, .fullDiskAccess])
        #expect(manager.onboardingPermissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
                                                  .automationFinder, .accessibility],
                "steps for both; Automation: System Events only in Settings")
        #expect(await AgentHarness.eventually { manager.statuses[.accessibility] == .denied }, "newly listed permissions are read")
        #expect(!manager.toolPermissions.contains(.accessibility), "no tool is switched off without them")
        let registry = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake()))
        await manager.refresh()
        let availability = registry.availability(disabledToolNames: [], permissions: manager)
        #expect(availability.allSatisfy { $0.isAvailable })
        manager.featurePermissions = []
        #expect(!manager.permissions.contains(.automationFinder))
    }

    /// The sync follows "Use the selection when opening" and the tool's switch in Tools.
    @Test func theListFollowsTheSettings() async {
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let registry = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake()))
        let manager = PermissionManager(access: MockPermissionAccess(), tools: registry.infos)
        let sync = ContextPermissionSync(settings: settings, registry: registry, permissions: manager)
        #expect(manager.featurePermissions == [.automationFinder, .accessibility], "both are on by default")

        settings.capturesSelectionOnOpen = false
        try? await Task.sleep(for: .milliseconds(20))
        #expect(manager.featurePermissions == [.automationFinder, .accessibility], "get_frontmost_context still reads the context")
        settings.setTool(GetFrontmostContextTool.toolName, enabled: false)
        #expect(await AgentHarness.eventually { manager.featurePermissions.isEmpty })
        settings.capturesSelectionOnOpen = true
        #expect(await AgentHarness.eventually { manager.featurePermissions == [.automationFinder, .accessibility] })
        #expect(sync.wanted == [.automationFinder, .accessibility])

        // Without the tool registered, only the setting counts.
        let bare = PermissionManager(access: MockPermissionAccess(), permissions: [])
        let noTool = ContextPermissionSync(settings: SettingsStore(defaults: AgentTestDefaults()), registry: ToolRegistry(tools: []),
                                           permissions: bare)
        #expect(noTool.wanted == [.automationFinder, .accessibility])
    }

    /// D6: users of the earlier version see the new steps once ("New in Orbit").
    @Test func existingUsersGetTheNewStepsOnce() {
        let before: Set<PermissionKind> = [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos]
        let now: [PermissionKind] = [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
                                     .automationFinder, .accessibility]
        #expect(OnboardingPlan.atLaunch(hasCompleted: true, presented: before, onboardingPermissions: now)
            == .newPermissions([.automationFinder, .accessibility]))
        #expect(OnboardingModel.steps(for: now, mode: .newPermissions([.automationFinder, .accessibility]))
            == [.permission(.automationFinder), .permission(.accessibility), .done])
        #expect(OnboardingPlan.atLaunch(hasCompleted: true, presented: Set(now), onboardingPermissions: now) == OnboardingPlan.none)
        #expect(OnboardingModel.Step(id: "accessibility") == .permission(.accessibility))
    }

    @Test func theCopyExplainsBoth() {
        #expect(PermissionCopy.purpose(.accessibility) == "Use the selected text and the window title of the frontmost app as context for your question. Password fields are never read.")
        #expect(PermissionCopy.purpose(.automationFinder) == "Use the items selected in Finder as context for your question.")
        #expect(PermissionCopy.purpose(.automationSystemEvents) == "Switch between the light and dark appearance after you confirm.")
        #expect(PermissionKind.accessibility.canRequest(from: .denied), "\"Erlauben …\" shows macOS's dialog that leads to System Settings")
        #expect(LivePermissionAccess.settingsAnchor(for: .accessibility) == "Privacy_Accessibility")
        #expect(AgentLoop.permissionNotice(for: .automationFinder) == "Orbit is not allowed to control Finder.")
    }

    /// UX-2: "Allow…" for Accessibility returns at once, still untrusted; the user switches Orbit on in System
    /// Settings and comes back: Orbit becomes active and reads the context permissions again too.
    @Test func backFromSystemSettingsTheContextPermissionsAreReadAgain() async {
        let access = MockPermissionAccess([.accessibility: .denied, .automationFinder: .notDetermined])
        let manager = PermissionManager(access: access, tools: ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos)
        let clock = AgentTestClock()
        manager.now = { clock.now }
        manager.featurePermissions = PermissionManager.contextPermissions(capturesSelection: true, contextToolEnabled: true)
        #expect(await AgentHarness.eventually { manager.statuses[.accessibility] == .denied })
        await manager.request(.accessibility)
        #expect(manager.statuses[.accessibility] == .denied)

        access.set(.granted, for: .accessibility)
        access.set(.granted, for: .automationFinder)
        clock.advance(by: PermissionManager.staleInterval + 1)
        manager.refreshIfStale()  // NSApplication.didBecomeActive
        #expect(await AgentHarness.eventually { manager.statuses[.accessibility] == .granted })
        #expect(await AgentHarness.eventually { manager.statuses[.automationFinder] == .granted })
        #expect(manager.routinePermissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders, .photos,
                                               .automationFinder, .automationSystemEvents, .accessibility],
                "the tools' permissions and the context's; Full Disk Access is not probed each time")

        manager.featurePermissions = []
        #expect(!manager.routinePermissions.contains(.accessibility), "not read while the context is off")
    }

    /// UX-6: the context steps say that the selection is read when the panel opens (not only on request) and that
    /// skipping switches no tool off.
    @Test func theOnboardingSaysWhenTheContextIsRead() {
        for permission in [PermissionKind.accessibility, .automationFinder] {
            let footnote = PermissionCopy.onboardingFootnote(permission, capturesSelectionOnOpen: true)
            #expect(footnote == "When you open Orbit, it takes your current selection as a chip above the input field; it reaches the language model only with your message. To turn this off: Settings > General > “Use the selection when opening”.")
            #expect(!footnote.contains("only what you ask about"))
            #expect(PermissionCopy.onboardingFootnote(permission, capturesSelectionOnOpen: false)
                == "Orbit reads your selection only when the assistant checks what you have in front of you for a question. What goes to the language model is shown in the chat below the answer.",
                "only get_frontmost_context reads it then")
            #expect(PermissionCopy.skipHelp(permission).contains("no tool is turned off"))
            #expect(!PermissionCopy.skipHelp(permission).contains("tools off"))
        }
        #expect(PermissionCopy.skipHelp(.accessibility).hasPrefix("Without this access, Orbit takes neither selected text nor window titles"))
        #expect(PermissionCopy.skipHelp(.automationFinder).hasPrefix("Without this access, Orbit takes no selection from Finder"))
        for permission in [PermissionKind.automationMail, .contacts, .calendars, .photos] {
            #expect(PermissionCopy.onboardingFootnote(permission, capturesSelectionOnOpen: true)
                == "Orbit reads only what you ask about. What goes to the language model is shown in the chat below the answer.")
            #expect(PermissionCopy.skipHelp(permission)
                == "Without this access, the related tools stay off. You can allow it later in Settings.")
        }
    }
}
