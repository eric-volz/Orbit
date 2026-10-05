import Foundation
import Testing
@testable import Orbit

@Suite("AgentLoop: tool execution")
@MainActor
struct AgentLoopToolTests {
    @Test func runsAToolAndShowsStatusCardSummaryAndDisclosure() async throws {
        let log = MockToolLog()
        let call = MockScript.call("toolu_1", "search_files", ["query": "Rechnung", "limit": "5"])
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls([call], text: "Ich suche."),
            MockScript.answer("Ich habe 2 Rechnungen gefunden."),
        ])
        await harness.send("Finde meine Rechnungen")

        // Validated, normalized arguments reach the tool.
        #expect(log.arguments(of: "search_files") == [ToolArguments(["query": "Rechnung", "limit": 5])])

        let kinds = harness.agent.items.map(\.kind)
        #expect(kinds == [
            .user(text: "Finde meine Rechnungen", attachments: []),
            .assistant(text: "Ich suche.", isStreaming: false),
            .toolStatus(ToolStatus(toolCallID: "toolu_1", toolName: "search_files", category: .files,
                                   text: "2 Dateien gefunden", state: .succeeded)),
            .card(.files(MockSearchFilesTool.files)),
            .assistant(text: "Ich habe 2 Rechnungen gefunden.", isStreaming: false),
            .disclosure(items: [ContentDisclosure(kind: .fileNames, count: 2)], providerName: "Claude"),
        ])

        // History: user, assistant(tool_use), user(tool_result), assistant(answer).
        #expect(harness.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        let result = try #require(harness.result(for: "toolu_1"))
        #expect(!result.isError)
        #expect(result.content.hasPrefix("Found 2 files for 'Rechnung'"))
        #expect(harness.requests.count == 2)
        #expect(harness.requests[1].tools.map(\.name) == ["search_files"])
        harness.expectValidHistory()
    }

    @Test func showsTheRunningStatusWhileAToolRuns() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockBlockingTool(started: started, release: release, log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("b1", "blocking_tool")]),
            MockScript.answer("Fertig."),
        ])
        harness.agent.send("Los")
        await started.wait()
        #expect(await AgentHarness.eventually { harness.statuses.first?.state == .running })
        #expect(harness.statuses.first?.text == "Running blocking_tool…")
        release.open()
        await harness.agent.waitUntilIdle()
        #expect(harness.statuses.first?.state == .succeeded)
        #expect(harness.statuses.first?.text == "Completed")
    }

    @Test func runsIndependentReadOnlyCallsInParallelAndKeepsTheirOrder() async throws {
        let tracker = MockConcurrencyTracker()
        let log = MockToolLog()
        let tools = [
            MockSlowReadTool(name: "slow_a", delay: .milliseconds(300), tracker: tracker, log: log),
            MockSlowReadTool(name: "slow_b", delay: .milliseconds(100), tracker: tracker, log: log),
            MockSlowReadTool(name: "slow_c", delay: .milliseconds(200), tracker: tracker, log: log),
        ]
        let calls = [MockScript.call("a", "slow_a"), MockScript.call("b", "slow_b"), MockScript.call("c", "slow_c")]
        let harness = AgentHarness(tools: tools, scripts: [MockScript.toolCalls(calls), MockScript.answer("Alles da.")])

        await harness.send("Lies alles")

        // All three were running at the same moment.
        #expect(await tracker.maximum == 3)
        let results = harness.messages[2].toolResults
        #expect(results.map(\.toolCallID) == ["a", "b", "c"])
        #expect(results.map(\.content) == ["result of slow_a", "result of slow_b", "result of slow_c"])

        // Every card sits right below its own status line.
        let rows = harness.agent.items.compactMap { item -> String? in
            switch item.kind {
            case .toolStatus(let status): "status:\(status.toolCallID)"
            case .card(.info(let info)): "card:\(info.title)"
            default: nil
            }
        }
        #expect(rows == ["status:a", "card:slow_a", "status:b", "card:slow_b", "status:c", "card:slow_c"])
        harness.expectValidHistory()
    }

    @Test func runsCallsWithSideEffectsOneAfterAnother() async {
        let tracker = MockConcurrencyTracker()
        let log = MockToolLog()
        let calls = [MockScript.call("o1", "open_app", ["name": "Safari"]), MockScript.call("o2", "open_app", ["name": "Mail"])]
        let harness = AgentHarness(tools: [MockOpenAppTool(log: log, tracker: tracker)],
                                   scripts: [MockScript.toolCalls(calls), MockScript.answer("Geöffnet.")])
        await harness.send("Öffne Safari und Mail")
        #expect(await tracker.maximum == 1)
        #expect(log.entries.map { $0.arguments.optionalString("name") } == ["Safari", "Mail"])
        #expect(harness.messages[2].toolResults.map(\.toolCallID) == ["o1", "o2"])
    }

    @Test func statusLinesFollowCallOrderWhenSomeCallsAreRejected() async {
        let tracker = MockConcurrencyTracker()
        let log = MockToolLog()
        let tools: [any Tool] = [
            MockSlowReadTool(name: "slow_a", delay: .milliseconds(30), tracker: tracker, log: log),
            MockSearchMailTool(log: log),
            MockSlowReadTool(name: "slow_b", delay: .milliseconds(10), tracker: tracker, log: log),
        ]
        let calls = [MockScript.call("a", "slow_a"), MockScript.call("m", "search_mail", ["query": "x"]), MockScript.call("b", "slow_b")]
        let harness = AgentHarness(tools: tools, scripts: [MockScript.toolCalls(calls), MockScript.answer("Ok.")])
        harness.permissions.set(.denied, for: .automationMail)
        await harness.send("Alles")

        #expect(await tracker.maximum == 2)
        #expect(harness.statuses.map(\.toolCallID) == ["a", "m", "b"])
        #expect(harness.statuses.map(\.state) == [.succeeded, .failed, .succeeded])
        #expect(harness.messages[2].toolResults.map(\.toolCallID) == ["a", "m", "b"])
        harness.expectValidHistory()
    }

    @Test func duplicateCallIDsStillGetOneResultEach() async {
        let log = MockToolLog()
        let calls = [MockScript.call("same", "search_files", ["query": "eins"]), MockScript.call("same", "open_app", ["name": "Mail"])]
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log), MockOpenAppTool(log: log, tracker: MockConcurrencyTracker())],
                                   scripts: [MockScript.toolCalls(calls), MockScript.answer("Ok.")])
        await harness.send("Beides")
        let results = harness.messages[2].toolResults
        #expect(results.count == 2)
        #expect(results[0].content.hasPrefix("Found 2 files"))
        #expect(results[1].content == "Opened Mail.")
    }

    // MARK: Limit

    @Test func runsTheCallsWithinTheBudgetAndStopsAtFifteen() async throws {
        let log = MockToolLog()
        let first = (1...10).map { MockScript.call("a\($0)", "search_files", ["query": .string("q\($0)")]) }
        let second = (1...6).map { MockScript.call("b\($0)", "search_files", ["query": .string("r\($0)")]) }
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls(first),
            MockScript.toolCalls(second),
        ])
        await harness.send("Suche sehr viel")

        // 10 + the first 5 of the second batch; the 16th call is not run.
        #expect(log.entries.count == 15)
        #expect(harness.requests.count == 2)
        #expect(!harness.agent.isRunning)
        for call in second.prefix(5) {
            #expect(harness.result(for: call.id)?.isError == false)
        }
        let rejected = try #require(harness.result(for: "b6"))
        #expect(rejected.isError)
        #expect(rejected.content.contains("limit of 15 tool calls"))
        #expect(harness.notices.last?.style == .warning)
        #expect(harness.notices.last?.message.contains("after 15 tool calls") == true)
        harness.expectValidHistory()

        // The conversation continues normally afterwards; the new text joins
        // the trailing tool-result message.
        harness.provider.enqueue(MockScript.answer("Weiter geht's."))
        await harness.send("Mach weiter")
        #expect(harness.assistantTexts.last == "Weiter geht's.")
        #expect(harness.messages.last?.role == .assistant)
        harness.expectValidHistory()
    }

    @Test func allowsExactlyFifteenCalls() async {
        let log = MockToolLog()
        let calls = (1...15).map { MockScript.call("c\($0)", "search_files", ["query": "q"]) }
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)],
                                   scripts: [MockScript.toolCalls(calls), MockScript.answer("Fertig.")])
        await harness.send("Viele Suchen")
        #expect(log.entries.count == 15)
        #expect(harness.assistantTexts.last == "Fertig.")
        #expect(harness.notices.isEmpty)
    }

    // MARK: Rejected calls

    @Test func invalidArgumentsAreReportedToTheModel() async throws {
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("t1", "search_files", ["limit": 500, "colour": "red"])]),
            MockScript.answer("Korrigiert."),
        ])
        await harness.send("Suche")
        #expect(log.entries.isEmpty)
        let result = try #require(harness.result(for: "t1"))
        #expect(result.isError)
        #expect(result.content.hasPrefix("Invalid arguments: "))
        #expect(result.content.contains("Missing required parameter 'query'."))
        #expect(result.content.contains("'limit' must be at most 50."))
        #expect(result.content.contains("Unknown parameter 'colour'"))
        #expect(result.content.hasSuffix("The tool was not run; call it again with corrected arguments."))
        #expect(harness.statuses.isEmpty)
        harness.expectValidHistory()
    }

    @Test func unknownToolsListTheAvailableOnes() async throws {
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: MockToolLog())], scripts: [
            MockScript.toolCalls([MockScript.call("t1", "delete_everything")]),
            MockScript.answer("Geht nicht."),
        ])
        await harness.send("Lösch alles")
        let result = try #require(harness.result(for: "t1"))
        #expect(result == ToolResultBlock(toolCallID: "t1", content: "Error: there is no tool named 'delete_everything'. Available tools: search_files.", isError: true))
        harness.expectValidHistory()
    }

    @Test func toleratesSlightlyWrongToolNames() async {
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("t1", "SearchFiles", ["query": "a"])]),
            MockScript.answer("Ok."),
        ])
        await harness.send("Suche")
        #expect(log.entries.count == 1)
    }

    @Test func unparsableArgumentsReturnInvalidJSON() async throws {
        let log = MockToolLog()
        let raw = #"{"query": "Rech"#
        let call = ToolCall(id: "t1", name: "search_files", input: [:], rawInput: raw, inputParseError: "Unexpected end of input")
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)],
                                   scripts: [MockScript.toolCalls([call]), MockScript.answer("Nochmal.")])
        await harness.send("Suche")
        #expect(log.entries.isEmpty)
        let result = try #require(harness.result(for: "t1"))
        #expect(result.isError)
        #expect(result.content == #"{"INVALID_JSON":"{\"query\": \"Rech"}"#)
        #expect(try JSONValue.parse(result.content) == ["INVALID_JSON": .string(raw)])
    }

    @Test func missingPermissionKeepsTheToolListedButRefusesToRunIt() async throws {
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log), MockSearchMailTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("m1", "search_mail", ["query": "Lisa"])]),
            MockScript.answer("Keine Berechtigung."),
        ])
        harness.permissions.set(.denied, for: .automationMail)
        await harness.send("Was schrieb Lisa?")

        #expect(harness.agent.conversation.toolNames == ["search_files", "search_mail"])
        let prompt = try #require(harness.agent.conversation.systemPrompt)
        #expect(prompt.contains("Available tools: search_files."))
        #expect(prompt.contains("- search_mail: macOS permission 'Automation: Mail' was not granted"))

        #expect(log.entries.isEmpty)
        let result = try #require(harness.result(for: "m1"))
        #expect(result == ToolResultBlock(toolCallID: "m1", content: ToolError.permissionDenied(.automationMail).modelMessage, isError: true))
        #expect(harness.statuses == [ToolStatus(toolCallID: "m1", toolName: "search_mail", category: .mail,
                                                text: "Missing permission: Automation: Mail", state: .failed)])
        harness.expectValidHistory()
    }

    @Test func toolDisabledDuringTheChatIsRefusedAndTheModelIsTold() async throws {
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.answer("Hallo!"),
            MockScript.toolCalls([MockScript.call("t1", "search_files", ["query": "a"])]),
            MockScript.answer("Ist deaktiviert."),
        ])
        await harness.send("Hallo")
        harness.settings.setTool("search_files", enabled: false)
        await harness.send("Suche Dateien")

        #expect(log.entries.isEmpty)
        let result = try #require(harness.result(for: "t1"))
        #expect(result.isError)
        #expect(result.content.contains("was disabled by the user"))
        #expect(harness.statuses.last?.text == "Turned off in Settings")
        // The tool list stays frozen; the change is announced in the user message.
        #expect(harness.requests[1].tools == harness.requests[0].tools)
        let context = harness.messages[2].textBlocks[0]
        #expect(context.contains("Tool availability changed: search_files is unavailable (disabled by the user in Orbit's settings)."))
        harness.expectValidHistory()
    }

    @Test func toolDisabledBeforeTheChatIsNotOffered() async throws {
        let log = MockToolLog()
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log), MockSearchMailTool(log: log)], scripts: [
            MockScript.toolCalls([MockScript.call("m1", "search_mail", ["query": "x"])]),
            MockScript.answer("Nicht aktiviert."),
        ])
        harness.settings.setTool("search_mail", enabled: false)
        await harness.send("Mails?")

        #expect(harness.agent.conversation.toolNames == ["search_files"])
        #expect(harness.requests[0].tools.map(\.name) == ["search_files"])
        #expect(harness.agent.conversation.systemPrompt?.contains("- search_mail: disabled by the user in Orbit's settings") == true)
        let result = try #require(harness.result(for: "m1"))
        #expect(result.content.contains("is not enabled in this chat"))
        #expect(log.entries.isEmpty)
    }

    // MARK: Results

    @Test func longResultsAreCappedWithANote() async throws {
        let harness = AgentHarness(tools: [MockLongOutputTool()], scripts: [
            MockScript.toolCalls([MockScript.call("l1", "long_output")]),
            MockScript.answer("Viel Text."),
        ])
        await harness.send("Gib mir alles")
        let result = try #require(harness.result(for: "l1"))
        #expect(result.content.count < Truncation.maxToolResultCharacters + 100)
        #expect(result.content.hasSuffix("of 50000 characters.]"))
        #expect(result.content.contains("[Truncated: showing the first "))
    }

    @Test func toolErrorsReachTheModelAndTheStatus() async throws {
        let harness = AgentHarness(tools: [MockFailingTool(error: ToolError.notFound("No note named 'Umzug'."))], scripts: [
            MockScript.toolCalls([MockScript.call("f1", "failing_tool")]),
            MockScript.answer("Nicht gefunden."),
        ])
        await harness.send("Lies die Notiz")
        #expect(harness.result(for: "f1") == ToolResultBlock(toolCallID: "f1", content: "Not found: No note named 'Umzug'.", isError: true))
        #expect(harness.statuses.last?.state == .failed)
        #expect(harness.statuses.last?.text == "Not found")
    }

    @Test func unexpectedErrorsStayGeneric() async throws {
        let harness = AgentHarness(tools: [MockFailingTool()], scripts: [
            MockScript.toolCalls([MockScript.call("f1", "failing_tool")]),
            MockScript.answer("Hat nicht geklappt."),
        ])
        await harness.send("Mach")
        let result = try #require(harness.result(for: "f1"))
        #expect(result.isError)
        #expect(result.content == AgentLoop.ModelText.unexpectedFailure)
        #expect(!result.content.contains("boom"))
        #expect(harness.statuses.last?.text == "Failed")
    }

    @Test func stuckToolsTimeOut() async throws {
        let release = AsyncGate()
        defer { release.open() }
        let harness = AgentHarness(tools: [MockStuckTool(release: release)], scripts: [
            MockScript.toolCalls([MockScript.call("s1", "stuck_tool")]),
            MockScript.answer("Zu langsam."),
        ], toolTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        await harness.send("Mach")
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(harness.result(for: "s1") == ToolResultBlock(toolCallID: "s1", content: ToolError.timedOut.modelMessage, isError: true))
        #expect(harness.statuses.last?.text == "Timed out")
        #expect(harness.assistantTexts.last == "Zu langsam.")
    }

    @Test func emptyResultsGetAPlaceholder() async throws {
        struct SilentTool: Tool {
            var name = "silent"
            var description = "Returns nothing."
            var inputSchema: JSONSchema = .empty
            var riskLevel: ToolRiskLevel = .read
            var category: ToolCategory = .system
            func run(arguments: ToolArguments) async throws -> ToolResult { ToolResult(text: " ") }
        }
        let harness = AgentHarness(tools: [SilentTool()], scripts: [
            MockScript.toolCalls([MockScript.call("s1", "silent")]), MockScript.answer("Ok."),
        ])
        await harness.send("Mach")
        #expect(harness.result(for: "s1")?.content == "(The tool returned no text.)")
    }

    @Test func disclosuresAreMergedPerRun() async {
        let log = MockToolLog()
        let calls = [MockScript.call("a", "search_files", ["query": "a"]), MockScript.call("b", "search_files", ["query": "b"])]
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls(calls), MockScript.answer("Vier Dateien."),
        ])
        let selection = ContextAttachment(kind: .finderSelection(paths: ["/tmp/a.pdf", "/tmp/b.pdf", "/tmp/c.pdf"]), label: "Mit Auswahl: 3 Dateien")
        await harness.send("Vergleiche", attachments: [selection])
        // 3 selected paths + 2 × 2 found file names.
        #expect(harness.disclosures == [[ContentDisclosure(kind: .fileNames, count: 7)]])
    }

    @Test func disclosureWaitsUntilTheContentIsActuallySent() async throws {
        let log = MockToolLog()
        let started = AsyncGate()
        let release = AsyncGate()
        defer { release.open() }
        let tools: [any Tool] = [MockSearchFilesTool(log: log), MockBlockingTool(started: started, release: release, log: log)]
        let calls = [MockScript.call("s1", "search_files", ["query": "a"]), MockScript.call("b1", "blocking_tool")]
        let harness = AgentHarness(tools: tools, scripts: [MockScript.toolCalls(calls), MockScript.answer("Weiter.")])

        harness.agent.send("Suche")
        await started.wait()
        #expect(await AgentHarness.eventually { harness.statuses.first?.state == .succeeded })
        harness.agent.cancel()
        // The search result is in the history but was not sent yet.
        #expect(try #require(harness.result(for: "s1")).content.hasPrefix("Found 2 files"))
        #expect(harness.result(for: "b1")?.content == "Cancelled by the user.")
        #expect(harness.disclosures.isEmpty)

        await harness.send("Weiter")
        #expect(harness.disclosures == [[ContentDisclosure(kind: .fileNames, count: 2)]])
        harness.expectValidHistory()
    }
}
