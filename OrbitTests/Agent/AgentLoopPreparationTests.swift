import Foundation
import Testing
@testable import Orbit

/// A write tool that checks and completes its arguments before its card
/// (`prepareForConfirmation`): "Montag" becomes a date, "nie" is refused.
private struct MockPreparingTool: Tool {
    var log: MockToolLog
    var name = "plan_meeting"
    var description = "Plans a meeting on a weekday after the user confirmed it."
    var inputSchema: JSONSchema = .object(properties: [
        "title": .string(description: "Title."),
        "day": .string(description: "A weekday or a date."),
    ], required: ["title", "day"])
    var riskLevel: ToolRiskLevel = .write
    var category: ToolCategory = .calendar
    var requiredPermissions: [PermissionKind] { [.calendars] }

    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        log.record("prepare", arguments)
        let day = try arguments.string("day")
        switch day.lowercased() {
        case "montag", "2026-10-05": break
        case "kalender": throw ToolError.permissionDenied(.calendars)
        case "absturz": throw CancellationError()
        default: throw ToolError.invalidArgument("'\(day)' is no day Orbit can plan.")
        }
        var prepared = arguments
        prepared["day"] = "2026-10-05"
        return prepared
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        ConfirmationRequest(toolName: name, riskLevel: riskLevel, title: "Treffen planen", message: "",
                            fields: [ConfirmationField(id: "title", label: "Titel", value: arguments.optionalString("title") ?? "", kind: .text),
                                     ConfirmationField(id: "day", label: "Tag", value: arguments.optionalString("day") ?? "", kind: .text)])
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        return ToolResult(text: "Planned \(try arguments.string("title")) on \(try arguments.string("day")).", summary: "Geplant")
    }
}

/// A write tool whose check adds tool-private values: the room it books
/// (`_room`, kept from the first check) and the room's name for the card.
private struct MockBookingTool: Tool {
    var log: MockToolLog
    var name = "book_room"
    var description = "Books a room after the user confirmed it."
    var inputSchema: JSONSchema = .object(properties: ["title": .string(description: "Title.")], required: ["title"])
    var riskLevel: ToolRiskLevel = .write
    var category: ToolCategory = .calendar

    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        log.record("prepare", arguments)
        var prepared = arguments
        prepared["_room"] = arguments["_room"] ?? "room-7"
        prepared["_shown"] = "Raum 7"
        return prepared
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        ConfirmationRequest(toolName: name, riskLevel: riskLevel, title: "Raum buchen", message: "",
                            fields: [ConfirmationField(id: "title", label: "Titel", value: arguments.optionalString("title") ?? "", kind: .text),
                                     ConfirmationField(id: "_shown", label: "Raum", value: arguments.optionalString("_shown") ?? "", kind: .readOnly)])
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        log.record(name, arguments)
        return ToolResult(text: "Booked \(try arguments.string("_room")) for \(try arguments.string("title")).")
    }
}

/// The tool checks a call before its confirmation card: the card shows the
/// completed values, a refused call gets no card, and edited values are
/// checked again before anything runs.
@Suite("AgentLoop: checks before the confirmation card")
@MainActor
struct AgentLoopPreparationTests {
    let log = MockToolLog()

    private func harness(_ day: String, extra: [[MockLLMProvider.Step]] = [MockScript.answer("Gut.")]) -> AgentHarness {
        let call = MockScript.call("p1", "plan_meeting", ["title": "Jour fixe", "day": .string(day)])
        return AgentHarness(tools: [MockPreparingTool(log: log)], scripts: [MockScript.toolCalls([call])] + extra)
    }

    @Test func theCardShowsWhatThePreparationCompleted() async throws {
        let harness = harness("Montag")
        harness.agent.send("Plane den Jour fixe am Montag")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.fields.map(\.value) == ["Jour fixe", "2026-10-05"])
        #expect(log.entries.map(\.tool) == ["prepare"], "only checked, nothing ran")
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(log.arguments(of: "plan_meeting") == [ToolArguments(["title": "Jour fixe", "day": "2026-10-05"])])
        #expect(harness.result(for: "p1")?.content == "Planned Jour fixe on 2026-10-05.")
        harness.expectValidHistory()
    }

    @Test func aRefusedCallGetsNoCard() async throws {
        let harness = harness("nie")
        await harness.send("Plane den Jour fixe nie")
        #expect(harness.confirmations.isEmpty)
        #expect(log.entries.map(\.tool) == ["prepare"])
        let result = try #require(harness.result(for: "p1"))
        #expect(result.isError)
        #expect(result.content == "Invalid arguments: 'nie' is no day Orbit can plan.")
        #expect(harness.statuses.map(\.state) == [.failed])
        #expect(harness.statuses.first?.text == "Invalid parameters")
        #expect(harness.assistantTexts.last == "Gut.")
        harness.expectValidHistory()
    }

    /// SEC1-V5: a refusal can name its reason in the chat (`ToolError.withStatus`), e.g. a link that opens only
    /// when the user typed it. The model still gets the failure's message, and nothing else about it changes.
    @Test func aRefusalCanNameItsReasonInTheChat() {
        let refusal = ToolError.withStatus(.invalidArgument("Only with the user's own link."), "Nur mit Link aus deiner Nachricht")
        #expect(AgentLoop.statusText(for: refusal) == "Nur mit Link aus deiner Nachricht")
        #expect(refusal.modelMessage == "Invalid arguments: Only with the user's own link.")
        #expect(refusal.underlying == .invalidArgument("Only with the user's own link."))
        #expect(refusal.disclosures.isEmpty)
        #expect(AgentLoop.logName(for: refusal) == "invalidArgument")
        let disclosing = ToolError.withStatus(ToolError.notFound("x").disclosing(.shortcuts, count: 2), "Eigener Status")
        #expect(disclosing.disclosures == [ContentDisclosure(kind: .shortcuts, count: 2)])
        #expect(disclosing.underlying == .notFound("x"))
        #expect(AgentLoop.statusText(for: disclosing.disclosing(.shortcuts, count: 1)) == "Eigener Status", "also inside a disclosure")
    }

    @Test func aMissingPermissionBeforeTheCardShowsTheNotice() async throws {
        let harness = harness("kalender")
        await harness.send("Plane den Jour fixe")
        #expect(harness.confirmations.isEmpty)
        #expect(harness.result(for: "p1")?.content == ToolError.permissionDenied(.calendars).modelMessage)
        #expect(harness.statuses.first?.text == "Missing permission: Calendars")
        #expect(harness.notices == [Notice(style: .info, message: "Orbit does not have full access to your calendars.",
                                           action: .openPermissionSettings)])
        #expect(harness.permissions.reportedChanges == [[.calendars]], "macOS may just have asked")
    }

    @Test func anUnexpectedFailureBeforeTheCardRunsNothing() async throws {
        let harness = harness("absturz")
        await harness.send("Plane den Jour fixe")
        #expect(harness.confirmations.isEmpty)
        #expect(harness.result(for: "p1")?.content == AgentLoop.ModelText.unexpectedFailure)
        #expect(harness.statuses.first?.text == "Failed")
        #expect(log.arguments(of: "plan_meeting").isEmpty)
    }

    @Test func editedValuesAreCheckedAgain() async throws {
        let harness = harness("Montag")
        harness.agent.send("Plane den Jour fixe am Montag")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["day": "Sonntag"]))
        await harness.agent.waitUntilIdle()
        #expect(log.arguments(of: "plan_meeting").isEmpty, "nothing runs with values the tool refuses")
        #expect(log.arguments(of: "prepare").map { $0["day"] } == ["Montag", "Sonntag"])
        #expect(harness.confirmations.map(\.status) == [.notRun])
        #expect(harness.statuses.map(\.text) == ["Invalid input"])
        #expect(harness.result(for: "p1")?.content
            == "Not run: the user edited the values before confirming, but they are invalid: 'Sonntag' is no day Orbit can plan. Nothing was changed.")
        harness.expectValidHistory()
    }

    @Test func editedValuesThatPassRunAsPrepared() async throws {
        let harness = harness("Montag")
        harness.agent.send("Plane den Jour fixe am Montag")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": "Team", "day": "montag"]))
        await harness.agent.waitUntilIdle()
        #expect(log.arguments(of: "plan_meeting") == [ToolArguments(["title": "Team", "day": "2026-10-05"])])
        #expect(harness.confirmations.map(\.status) == [.approved])
        let content = try #require(harness.result(for: "p1")?.content)
        #expect(content.hasPrefix("The user edited the proposed values before confirming; the action ran with: "))
        #expect(content.hasSuffix("Planned Team on 2026-10-05."))
    }

    // MARK: Tool-private values

    private func bookingHarness(_ arguments: [String: JSONValue] = ["title": "Jour fixe"]) -> AgentHarness {
        AgentHarness(tools: [MockBookingTool(log: log)],
                     scripts: [MockScript.toolCalls([MockScript.call("b1", "book_room", .object(arguments))]), MockScript.answer("Gut.")])
    }

    /// The values the check added (the room the card names) are no parameters: the schema would
    /// refuse them, yet they reach the check after edits and the run unchanged.
    @Test func toolPrivateValuesSurviveTheUsersEdits() async throws {
        let harness = bookingHarness()
        harness.agent.send("Buch einen Raum")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.fields.map(\.value) == ["Jour fixe", "Raum 7"])
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": "Team"]))
        await harness.agent.waitUntilIdle()
        #expect(log.arguments(of: "prepare").last == ToolArguments(["title": "Team", "_room": "room-7", "_shown": "Raum 7"]),
                "the check after edits gets the values the card was built from")
        #expect(log.arguments(of: "book_room") == [ToolArguments(["title": "Team", "_room": "room-7", "_shown": "Raum 7"])])
        #expect(harness.confirmations.map(\.status) == [.approved])
        #expect(harness.result(for: "b1")?.content.hasSuffix("Booked room-7 for Team.") == true)
        harness.expectValidHistory()
    }

    @Test func editsNeverChangeToolPrivateValues() async throws {
        let harness = bookingHarness()
        harness.agent.send("Buch einen Raum")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["title": "Team", "_room": "room-1"]))
        await harness.agent.waitUntilIdle()
        #expect(log.arguments(of: "book_room").map { $0["_room"] } == ["room-7"])
    }

    /// Only the tool's check sets them: a call that passes one is refused like any unknown parameter.
    @Test func theModelCannotPassToolPrivateValues() async throws {
        let harness = bookingHarness(["title": "Jour fixe", "_room": "room-1"])
        await harness.send("Buch einen Raum")
        #expect(harness.confirmations.isEmpty)
        #expect(log.entries.isEmpty)
        #expect(harness.result(for: "b1")?.content.hasPrefix("Invalid arguments: Unknown parameter '_room'.") == true)
    }

    /// So no tool may declare a parameter that starts with "_".
    @Test func noToolHasAParameterThatLooksToolPrivate() {
        for tool in AppEnvironment.makeTools(services: .fake()) {
            guard case .object(let properties, _, _) = tool.inputSchema else { continue }
            #expect(!properties.keys.contains(where: ToolArguments.isPrivateKey), "\(tool.name)")
        }
    }

    @Test func toolsWithoutAPreparationKeepTheirArguments() async throws {
        let tool = MockCreateNoteTool(log: log)
        let arguments = ToolArguments(["title": "Einkauf", "body": "Milch"])
        #expect(try await tool.prepareForConfirmation(arguments) == arguments)
        guard case .prepared(let same) = await AgentLoop.prepare(tool, arguments: arguments, timeout: .seconds(1)) else {
            Issue.record("prepared")
            return
        }
        #expect(same == arguments)
    }
}
