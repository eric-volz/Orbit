import Foundation
import Testing
@testable import Orbit

/// A tool needing Notes that succeeds or throws as told.
private struct NotesProbeTool: Tool {
    var error: ToolError?
    var name = "search_notes"
    var description = "Searches notes."
    var inputSchema: JSONSchema = .empty
    var riskLevel: ToolRiskLevel = .read
    var category: ToolCategory = .notes
    var requiredPermissions: [PermissionKind] = [.automationNotes]

    func run(arguments: ToolArguments) async throws -> ToolResult {
        if let error { throw error }
        return ToolResult(text: "No notes.", summary: "Keine Notizen")
    }
}

@Suite("AgentLoop: permissions")
@MainActor
struct AgentLoopPermissionTests {
    private func harness(_ tool: any Tool) -> AgentHarness {
        AgentHarness(tools: [tool], scripts: [
            MockScript.toolCalls([MockScript.call("n1", tool.name)]),
            MockScript.answer("Fertig."),
        ])
    }

    @Test func aRefusalByMacOSIsReadAgain() async {
        let harness = harness(NotesProbeTool(error: .permissionDenied(.automationNotes)))
        await harness.send("Was steht in meinen Notizen?")
        #expect(harness.permissions.reportedChanges == [[.automationNotes]])
        harness.expectValidHistory()
    }

    @Test func theFirstUseOfAPermissionIsReadAgain() async {
        let harness = harness(NotesProbeTool())
        harness.permissions.set(.notDetermined, for: .automationNotes)
        await harness.send("Was steht in meinen Notizen?")
        #expect(harness.permissions.reportedChanges == [[.automationNotes]], "macOS may just have asked the user")
    }

    @Test func aFailureWhileUndecidedIsReadAgainToo() async {
        let harness = harness(NotesProbeTool(error: .failed("Notes did not answer.")))
        harness.permissions.set(.unknown, for: .automationNotes)
        await harness.send("Was steht in meinen Notizen?")
        #expect(harness.permissions.reportedChanges == [[.automationNotes]])
    }

    @Test func grantedPermissionsAndToolsWithoutPermissionsAreNotReadAgain() async {
        let notes = harness(NotesProbeTool())
        await notes.send("Was steht in meinen Notizen?")
        #expect(notes.permissions.reportedChanges.isEmpty)

        let files = harness(MockSearchFilesTool(log: MockToolLog()))
        await files.send("Finde die Rechnung")
        #expect(files.permissions.reportedChanges.isEmpty)
    }

    // MARK: What the chat and the model say (UX-2)

    private static let notesNotice = Notice(style: .info, message: "Orbit is not allowed to control Notes.",
                                            action: .openPermissionSettings)

    /// macOS refused while the tool ran: the chat says so with "Open
    /// Settings" (Permissions), and the model hears the permission by the name
    /// Settings shows, not Orbit's internal one.
    @Test func aRefusalByMacOSShowsANoticeThatOpensPermissions() async throws {
        let harness = harness(NotesProbeTool(error: .permissionDenied(.automationNotes)))
        await harness.send("Was steht in meinen Notizen?")
        #expect(harness.notices == [Self.notesNotice])
        #expect(Notice.Action.openPermissionSettings.settingsTab == .permissions)
        let result = try #require(harness.result(for: "n1"))
        #expect(result.isError)
        #expect(result.content.contains("macOS permission 'Automation: Notes'"))
        #expect(result.content.contains("under 'Permissions'"))
        #expect(!result.content.contains("automationNotes"))
        harness.expectValidHistory()
    }

    /// A call refused before it ran (the permission was denied already) gets
    /// the same notice, once per request, however many calls macOS refuses.
    @Test func callsRefusedBeforeTheyRanShowTheNoticeOncePerRequest() async throws {
        let harness = AgentHarness(tools: [NotesProbeTool()], scripts: [
            MockScript.toolCalls([MockScript.call("n1", "search_notes"), MockScript.call("n2", "search_notes")]),
            MockScript.toolCalls([MockScript.call("n3", "search_notes")]),
            MockScript.answer("Orbit is not allowed to control Notes."),
            MockScript.toolCalls([MockScript.call("n4", "search_notes")]),
            MockScript.answer("Weiterhin nicht."),
        ])
        harness.permissions.set(.denied, for: .automationNotes)
        await harness.send("Was steht in meinen Notizen?")
        #expect(harness.notices == [Self.notesNotice])
        #expect(harness.statuses.map(\.text) == Array(repeating: "Missing permission: Automation: Notes", count: 3))
        #expect(try #require(harness.result(for: "n2")).content.contains("'Automation: Notes'"))

        await harness.send("Und jetzt?")
        #expect(harness.notices == [Self.notesNotice, Self.notesNotice], "a new request says it again")
        harness.expectValidHistory()
    }

    @Test func noticesNameWhatMacOSDoesNotAllow() {
        #expect(AgentLoop.permissionNotice(for: .automationMail) == "Orbit is not allowed to control Mail.")
        #expect(AgentLoop.permissionNotice(for: .automationNotes) == "Orbit is not allowed to control Notes.")
        #expect(AgentLoop.permissionNotice(for: .contacts) == "Orbit is not allowed to access your contacts.")
        // Also when macOS allows adding only: Orbit needs full access.
        #expect(AgentLoop.permissionNotice(for: .calendars) == "Orbit does not have full access to your calendars.")
        #expect(AgentLoop.permissionNotice(for: .reminders) == "Orbit does not have full access to your reminders.")
        #expect(AgentLoop.permissionNotice(for: .photos) == "Orbit is not allowed to access your photos.")
        #expect(AgentLoop.permissionNotice(for: .automationPhotos) == "Orbit is not allowed to control Photos.")
        #expect(AgentLoop.permissionNotice(for: .accessibility) == "Orbit does not have the permission “Accessibility”.")
    }

    /// Model errors open Settings on Model, permissions on Permissions;
    /// both stay clickable on older notices. Saved chats keep decoding.
    @Test func settingsNoticesOpenTheirTab() throws {
        #expect(Notice.Action.openSettings.settingsTab == .model)
        #expect(Notice.Action.retry.settingsTab == nil)
        let notice = Notice(style: .info, message: "Orbit is not allowed to control Mail.", action: .openPermissionSettings)
        #expect(try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(notice)) == notice)
        let saved = #"{"style":"warning","message":"Kein Schlüssel","action":"openSettings"}"#
        #expect(try JSONDecoder().decode(Notice.self, from: Data(saved.utf8)).action == .openSettings)
    }

    @Test func aRefusedCallThatNeverRanReportsNothing() async {
        let harness = harness(NotesProbeTool())
        harness.permissions.set(.denied, for: .automationNotes)
        await harness.send("Was steht in meinen Notizen?")
        #expect(harness.permissions.reportedChanges.isEmpty, "the denial was already known; the tool did not run")
    }

    /// The live chain: macOS refuses during a run, the manager reads it, and the
    /// next request tells the model that the tool is unavailable now.
    @Test func theNextTurnTellsTheModelWhatMacOSRefused() async throws {
        let access = MockPermissionAccess([.automationNotes: .notDetermined])
        let manager = PermissionManager(access: access, permissions: [.automationNotes])
        await manager.refresh()
        let provider = MockLLMProvider(scripts: [
            MockScript.toolCalls([MockScript.call("n1", "search_notes")]),
            MockScript.answer("Orbit is not allowed to control Notes."),
            MockScript.answer("Weiterhin nicht."),
        ])
        let agent = AgentLoop(dependencies: AgentDependencies(
            settings: SettingsStore(defaults: AgentTestDefaults()),
            secrets: InMemorySecretStore([SecretAccount.anthropicAPIKey: "test-key"]),
            registry: ToolRegistry(tools: [NotesProbeTool(error: .permissionDenied(.automationNotes))]),
            store: nil,
            permissions: manager,
            providerFactory: LLMProviderFactory { _ in provider },
            userName: { nil }
        ))
        // The user declines macOS's prompt while the tool runs.
        access.set(.denied, for: .automationNotes)
        agent.send("Was steht in meinen Notizen?")
        await agent.waitUntilIdle()
        let prompt = try #require(agent.conversation.systemPrompt)
        #expect(prompt.contains("Available tools: search_notes."), "not decided yet: offered")
        #expect(await AgentHarness.eventually { manager.status(of: .automationNotes) == .denied })

        agent.send("Und jetzt?")
        await agent.waitUntilIdle()
        let context = try #require(agent.conversation.messages.last { $0.role == .user }?.textBlocks.first)
        #expect(context.contains("Tool availability changed: search_notes is unavailable (macOS permission 'Automation: Notes' was not granted)."))
    }
}
