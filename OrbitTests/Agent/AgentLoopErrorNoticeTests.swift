import AppKit
import Foundation
import os
import Testing
@testable import Orbit

/// D2: every failed request ends with one clear notice that offers what helps
/// ("Open Settings" (the Model tab), "Try Again", "Sign In…",
/// "New Chat"), and VoiceOver hears it once.
@Suite("AgentLoop: error notices")
@MainActor
struct AgentLoopErrorNoticeTests {
    private func claudeCodeHarness(scripts: [[MockLLMProvider.Step]],
                                   account: (any ClaudeCodeAccountServicing)? = nil) -> AgentHarness {
        let provider = MockLLMProvider(kind: .claudeCode, scripts: scripts, executesToolsInternally: true)
        let harness = AgentHarness(apiKey: nil, provider: provider, claudeCodeAccount: account)
        harness.settings.providerKind = .claudeCode
        return harness
    }

    // MARK: Buttons

    @Test(arguments: [
        (LLMError.missingAPIKey, [Notice.Action.openSettings, .retry]),
        (.keychainUnavailable, [.retry]),
        (.invalidAPIKey, [.openSettings, .retry]),
        (.permissionDenied, [.openSettings, .retry]),
        (.billing, [.retry]),
        (.modelNotFound(model: "x"), [.openSettings, .retry]),
        (.toolsNotSupported(model: "x"), [.openSettings, .retry]),
        (.rateLimited(retryAfter: 5), [.retry]),
        (.overloaded, [.retry]),
        (.server(status: 502), [.retry]),
        (.requestTooLarge, [.newChat]),
        (.contextTooLong, [.newChat]),
        (.invalidRequest(message: "x"), [.openSettings, .retry]),
        (.network(.offline), [.retry]),
        (.network(.connectionLost), [.retry]),
        (.network(.timedOut), [.retry]),
        (.network(.cannotConnect), [.retry]),
        (.network(.secureConnection), [.retry]),
        (.network(.insecureConnectionBlocked), [.openSettings, .retry]),
        (.network(.other), [.retry]),
        (.invalidResponse(detail: "x"), [.retry]),
        (.streamError(type: "x", message: "y"), [.retry]),
        (.invalidBaseURL, [.openSettings, .retry]),
        (.cancelled, [.retry]),
        (.claudeCodeNotInstalled, [.openSettings, .retry]),
        (.claudeCodeNotLoggedIn, [.signIn, .retry]),
        (.claudeCodeOutdated, [.retry, .openSettings]),
        (.usageLimitReached(resetsAt: nil), [.retry]),
        (.providerProcessFailed(detail: "x"), [.retry]),
    ] as [(LLMError, [Notice.Action])])
    func everyErrorOffersWhatHelps(error: LLMError, actions: [Notice.Action]) async {
        #expect(AgentLoop.noticeActions(for: error) == actions)
        // The harness talks to Anthropic's API.
        let harness = AgentHarness(scripts: [[.fail(error)]])
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: error.userMessage(for: .anthropicAPI), action: actions.first,
                                           secondaryAction: actions.dropFirst().first)])
    }

    /// A server at an address the user typed: start it and try again, or correct the address.
    @Test func unreachableServersAlsoOfferTheSettings() {
        for failure in [NetworkFailure.cannotConnect, .secureConnection] {
            let error = LLMError.network(failure)
            #expect(AgentLoop.noticeActions(for: error, destination: .thisMac(address: "localhost:11434")) == [.retry, .openSettings])
            #expect(AgentLoop.noticeActions(for: error, destination: .server(address: "llm.example.com")) == [.retry, .openSettings])
            #expect(AgentLoop.noticeActions(for: error, destination: .anthropicAPI) == [.retry])
            #expect(AgentLoop.noticeActions(for: error, destination: .claudeSubscription) == [.retry])
        }
    }

    @Test func aServerOnThisMacThatIsNotRunningSaysToStartIt() async {
        let provider = MockLLMProvider(kind: .openAICompatible, displayName: ProviderRecipient.localModel,
                                       scripts: [[.fail(LLMError.network(.cannotConnect))], MockScript.answer("Da bin ich.")])
        let harness = AgentHarness(provider: provider)
        harness.settings.providerKind = .openAICompatible
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(
            style: .error,
            message: "The server on this Mac (localhost:11434) cannot be reached. Start it (for example Ollama or LM Studio) and try again.",
            action: .retry, secondaryAction: .openSettings)])

        // Ollama started: the same request goes again.
        harness.agent.retry()
        await harness.agent.waitUntilIdle()
        #expect(harness.notices.isEmpty)
        #expect(harness.assistantTexts == ["Da bin ich."])
    }

    @Test func aRefusedModelOfTheSubscriptionSaysSo() async {
        let harness = claudeCodeHarness(scripts: [[.fail(LLMError.permissionDenied)]])
        await harness.send("Hallo")
        #expect(harness.notices.first?.message == LLMError.permissionDenied.userMessage(for: .claudeSubscription))
        #expect(harness.notices.first?.actions == [.openSettings, .retry])
    }

    @Test func contextLimitsOfferANewChat() async {
        let harness = AgentHarness(scripts: [[.fail(LLMError.requestTooLarge)]])
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: LLMError.requestTooLarge.userMessage, action: .newChat)])
    }

    /// "New Chat" of a notice that the conversation no longer fits keeps the
    /// request for the new chat's input (`AppEnvironment.startNewChat()`)
    /// (as typed, without its chips), so it need not be typed again. Also in a
    /// chat restored after a relaunch; never from another notice, while a
    /// request runs, or once the new chat started.
    @Test(arguments: [
        [MockLLMProvider.Step.fail(LLMError.contextTooLong)],
        [.fail(LLMError.requestTooLarge)],
        [.end([], stopReason: .contextWindowExceeded)],
    ])
    func aNewChatFromATooLongConversationKeepsTheRequest(failure: [MockLLMProvider.Step]) async {
        let harness = AgentHarness(scripts: [MockScript.answer("Eins."), failure])
        await harness.send("Erste Frage")
        #expect(harness.agent.requestForNewChat == nil)
        await harness.send("  Und was steht in der langen Datei?  ", attachments: SampleData.attachments)
        #expect(harness.notices.last?.actions == [.newChat])
        #expect(harness.agent.requestForNewChat == "Und was steht in der langen Datei?")

        await harness.agent.waitForPendingSaves()
        harness.relaunch()
        await harness.agent.restoreMostRecentConversation()
        #expect(harness.agent.requestForNewChat == "Und was steht in der langen Datei?")
        harness.agent.newChat()
        #expect(harness.agent.requestForNewChat == nil)
    }

    @Test func otherNoticesKeepNoRequest() async {
        let harness = AgentHarness(scripts: [[.fail(LLMError.overloaded)]])
        await harness.send("Hallo")
        #expect(harness.notices.last?.actions == [.retry])
        #expect(harness.agent.requestForNewChat == nil)
    }

    // MARK: Usage limit of the subscription

    @Test func aUsageLimitReplacesTheWarningOfItsRunAndSaysWhenItResets() async {
        let reset = AgentTestClock.start.addingTimeInterval(3 * 3600)
        let rejected = RateLimitInfo(status: "rejected", utilization: 1, resetsAt: reset, window: "five_hour", isUsingOverage: false)
        // Claude Code's text named no time ("You've hit your limit"): the rejection event's time is used.
        let harness = claudeCodeHarness(scripts: [[.event(.rateLimit(rejected)), .fail(LLMError.usageLimitReached(resetsAt: nil))]])
        await harness.send("Hallo")
        #expect(harness.notices == [Notice(style: .error, message: LLMError.usageLimitReached(resetsAt: reset).userMessage,
                                           action: .retry)])
        #expect(harness.notices.first?.message.contains(ProviderUsage.resetDate(reset)) == true)
    }

    @Test func aWarningOfAnEarlierRequestStays() async {
        let reset = AgentTestClock.start.addingTimeInterval(3 * 3600)
        let warning = RateLimitInfo(status: "allowed_warning", utilization: 0.96, resetsAt: reset, window: "five_hour",
                                    isUsingOverage: false)
        let harness = claudeCodeHarness(scripts: [
            [.event(.rateLimit(warning))] + MockScript.answer("Eins."),
            [.fail(LLMError.usageLimitReached(resetsAt: reset))],
        ])
        await harness.send("1")
        await harness.send("2")
        #expect(harness.notices.map(\.style) == [.info, .error])
    }

    /// Only a rejection says when the limit resets; not a warning, and not a time that has passed.
    @Test func onlyAFutureRejectionGivesTheResetTime() async {
        let past = RateLimitInfo(status: "rejected", utilization: nil, resetsAt: AgentTestClock.start.addingTimeInterval(-60),
                                 window: "five_hour", isUsingOverage: false)
        let warning = RateLimitInfo(status: "allowed_warning", utilization: 0.5,
                                    resetsAt: AgentTestClock.start.addingTimeInterval(3600), window: "seven_day", isUsingOverage: false)
        for info in [past, warning] {
            let harness = claudeCodeHarness(scripts: [[.event(.rateLimit(info)), .fail(LLMError.usageLimitReached(resetsAt: nil))]])
            await harness.send("Hallo")
            #expect(harness.notices.last?.message == LLMError.usageLimitReached(resetsAt: nil).userMessage)
        }
    }

    // MARK: VoiceOver

    @Test func voiceOverHearsEachNoticeOnceWhenItAppears() async {
        let harness = AgentHarness(scripts: [[.fail(LLMError.overloaded)], [.fail(LLMError.overloaded)]])
        await harness.send("Hallo")
        #expect(harness.announcer.announcements == [LLMError.overloaded.userMessage])
        #expect(harness.announcer.priorities == [.high], "an error interrupts")

        // The retry's notice replaces the first one and is heard once.
        harness.agent.retry()
        await harness.agent.waitUntilIdle()
        #expect(harness.notices.count == 1)
        #expect(harness.announcer.announcements == [LLMError.overloaded.userMessage, LLMError.overloaded.userMessage])

        // A chat restored at launch is not read out again.
        await harness.agent.waitForPendingSaves()
        harness.relaunch()
        await harness.agent.restoreMostRecentConversation()
        #expect(harness.notices.count == 1)
        #expect(harness.announcer.announcements.count == 2)
    }

    @Test func otherNoticesDoNotInterrupt() async {
        let gate = AsyncGate()
        let harness = AgentHarness(scripts: [[.text("Lang"), .signal(gate), .wait(AsyncGate())]])
        harness.agent.send("Erzähl")
        await gate.wait()
        harness.agent.cancel()
        #expect(harness.announcer.announcements == ["Canceled."])
        #expect(harness.announcer.priorities == [.medium])
    }

    // MARK: Signing in to Claude Code

    @Test func signingInFromTheNoticeSendsTheRequestAgain() async {
        let account = GatedClaudeCodeAccount()
        let harness = claudeCodeHarness(scripts: [[.fail(LLMError.claudeCodeNotLoggedIn)], MockScript.answer("Hallo!")],
                                        account: account)
        await harness.send("Hallo")
        #expect(harness.notices.first?.actions == [.signIn, .retry])

        harness.agent.signInAndRetry()
        #expect(harness.agent.isSigningIn)
        harness.agent.signInAndRetry()
        #expect(await AgentHarness.eventually { account.signInCount == 1 })
        #expect(harness.requests.count == 1, "nothing is sent before the sign-in finished")

        account.gate.open()
        #expect(await AgentHarness.eventually { !harness.agent.isSigningIn && harness.assistantTexts == ["Hallo!"] })
        await harness.agent.waitUntilIdle()
        #expect(harness.notices.isEmpty)
        #expect(account.signInCount == 1, "a second click while signing in starts nothing")
        #expect(harness.requests.count == 2)
        harness.expectValidHistory()
    }

    @Test(arguments: [
        (LLMError.claudeCodeNotLoggedIn, "Sign-in was not completed. Please try again."),
        (.claudeCodeNotInstalled, LLMError.claudeCodeNotInstalled.userMessage),
    ])
    func aFailedSignInSaysSoInTheNotice(error: LLMError, message: String) async {
        let account = GatedClaudeCodeAccount(failure: error)
        let harness = claudeCodeHarness(scripts: [[.fail(LLMError.claudeCodeNotLoggedIn)]], account: account)
        await harness.send("Hallo")
        harness.agent.signInAndRetry()
        account.gate.open()
        #expect(await AgentHarness.eventually { !harness.agent.isSigningIn })
        #expect(harness.notices == [Notice(style: .error, message: message, action: .signIn, secondaryAction: .retry)])
        #expect(harness.announcer.announcements.last == message)
        #expect(harness.announcer.priorities.last == .high)
        #expect(harness.requests.count == 1)
    }

    @Test func aCancelledSignInChangesNothing() async {
        let account = GatedClaudeCodeAccount()
        let harness = claudeCodeHarness(scripts: [[.fail(LLMError.claudeCodeNotLoggedIn)]], account: account)
        await harness.send("Hallo")
        harness.agent.signInAndRetry()
        #expect(await AgentHarness.eventually { account.signInCount == 1 })
        harness.agent.cancelSignIn()
        #expect(await AgentHarness.eventually { !harness.agent.isSigningIn })
        #expect(harness.notices.first?.message == LLMError.claudeCodeNotLoggedIn.userMessage)
        #expect(harness.announcer.announcements.count == 1)
        #expect(harness.requests.count == 1)
    }

    /// The user went on (and it worked): the sign-in that finishes later sends nothing.
    @Test func aSignInAfterTheChatMovedOnSendsNothing() async {
        let account = GatedClaudeCodeAccount()
        let harness = claudeCodeHarness(scripts: [[.fail(LLMError.claudeCodeNotLoggedIn)], MockScript.answer("Hallo!")],
                                        account: account)
        await harness.send("Hallo")
        harness.agent.signInAndRetry()
        await harness.send("Und jetzt?")
        account.gate.open()
        #expect(await AgentHarness.eventually { !harness.agent.isSigningIn })
        await harness.agent.waitUntilIdle()
        #expect(harness.requests.count == 2)
        #expect(harness.notices.first?.actions == [], "the old notice no longer resends anything")
    }

    @Test func withoutASignInNoticeNothingStarts() async {
        let account = GatedClaudeCodeAccount()
        let harness = claudeCodeHarness(scripts: [[.fail(LLMError.overloaded)]], account: account)
        await harness.send("Hallo")
        harness.agent.signInAndRetry()
        #expect(!harness.agent.isSigningIn)
        #expect(account.signInCount == 0)
    }

    // MARK: Older notices

    /// A new message makes the old request's buttons that would send it again
    /// go; "Open Settings" stays.
    @Test func aNewMessageRetiresResendingButtonsButKeepsTheSettings() async throws {
        let harness = AgentHarness(scripts: [MockScript.answer("Ok")], apiKey: nil)
        await harness.send("Eins")
        #expect(harness.notices.first?.actions == [.openSettings, .retry])
        try harness.secrets.setSecret("key", for: SecretAccount.anthropicAPIKey)
        await harness.send("Zwei")
        #expect(harness.notices == [Notice(style: .error, message: LLMError.missingAPIKey.userMessage, action: .openSettings)])
        harness.expectValidHistory()
    }

    // MARK: Saved chats

    @Test func noticesOfOlderChatsStillDecodeAndNewOnesRoundTrip() throws {
        let saved = #"{"style":"error","message":"Der Dienst ist gerade überlastet.","action":"retry"}"#
        let old = try JSONDecoder().decode(Notice.self, from: Data(saved.utf8))
        #expect(old == Notice(style: .error, message: "Der Dienst ist gerade überlastet.", action: .retry))
        #expect(old.secondaryAction == nil)
        #expect(old.actions == [.retry])
        let noAction = try JSONDecoder().decode(Notice.self, from: Data(#"{"style":"info","message":"Abgebrochen."}"#.utf8))
        #expect(noAction.actions.isEmpty)
        for notice in [Notice(style: .error, message: "a", action: .signIn, secondaryAction: .retry),
                       Notice(style: .warning, message: "b", action: .newChat),
                       Notice(style: .error, message: "c", action: .retry, secondaryAction: .openSettings)] {
            #expect(try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(notice)) == notice)
        }
    }

    // MARK: The row

    /// Buttons that act on the request show on the latest notice while nothing
    /// runs; "Open Settings" always.
    @Test func theRowOffersTheButtonsThatCanWorkNow() {
        let settingsAndRetry = Notice(style: .error, message: "x", action: .openSettings, secondaryAction: .retry)
        #expect(NoticeRow.offeredActions(settingsAndRetry, isActionAvailable: true) == [.openSettings, .retry])
        #expect(NoticeRow.offeredActions(settingsAndRetry, isActionAvailable: false) == [.openSettings])
        let signIn = Notice(style: .error, message: "x", action: .signIn, secondaryAction: .retry)
        #expect(NoticeRow.offeredActions(signIn, isActionAvailable: false).isEmpty)
        #expect(NoticeRow.offeredActions(Notice(style: .warning, message: "x", action: .newChat), isActionAvailable: true) == [.newChat])
        #expect(NoticeRow.offeredActions(Notice(style: .info, message: "x", action: .openPermissionSettings),
                                         isActionAvailable: false) == [.openPermissionSettings])
        #expect(Notice.Action.signIn.settingsTab == nil)
        #expect(Notice.Action.newChat.settingsTab == nil)
        #expect(NoticeRow.title(.signIn) == "Sign In…")
        #expect(NoticeRow.title(.newChat) == "New Chat")
    }
}

/// A Claude Code account whose sign-in waits until the test opens `gate`,
/// then succeeds or fails with `failure`.
final class GatedClaudeCodeAccount: ClaudeCodeAccountServicing {
    let gate = AsyncGate()
    private let failure: LLMError?
    private let signIns = OSAllocatedUnfairLock(initialState: 0)

    init(failure: LLMError? = nil) {
        self.failure = failure
    }

    var signInCount: Int { signIns.withLock { $0 } }

    func status() async -> ClaudeCodeStatus {
        ClaudeCodeStatus(availability: .notLoggedIn)
    }

    func signIn() async throws {
        signIns.withLock { $0 += 1 }
        await gate.wait()
        try Task.checkCancellation()
        if let failure { throw failure }
    }
}
