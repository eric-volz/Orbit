import Foundation
import Testing
@testable import Orbit

@Suite("Claude Code error classifier")
struct ClaudeCodeErrorClassifierTests {
    private func classify(_ text: String, status: Int? = nil, terminal: String? = nil, subtype: String = "success",
                          rateLimit: RateLimitInfo? = nil, now: Date = ClaudeCodeErrorClassifierTests.now) -> LLMError {
        ClaudeCodeErrorClassifier.classify(ClaudeCodeErrorClassifier.Report(
            subtype: subtype, terminalReason: terminal, apiErrorStatus: status, text: text, rateLimit: rateLimit,
            model: "sonnet"
        ), now: now)
    }

    static let reset = Date(timeIntervalSince1970: 1_790_700_000)
    /// 2026-10-04 10:30 in Berlin (08:30 UTC).
    static let now = FlexibleDate.parse("2026-10-04T10:30:00+02:00")!.date
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test(arguments: [
        ("Not logged in · Please run /login", LLMError.claudeCodeNotLoggedIn),
        ("OAuth token revoked · Please run /login", .claudeCodeNotLoggedIn),
        ("Login expired · Please run /login", .claudeCodeNotLoggedIn),
        ("Invalid API key · Fix external API key", .claudeCodeNotLoggedIn),
        ("OAuth access token has expired. Re-authenticate to continue.", .claudeCodeNotLoggedIn),
        ("Claude AI usage limit reached|1790700000", .usageLimitReached(resetsAt: reset)),
        ("You've hit your limit · resets 3pm (Europe/Berlin)",
         .usageLimitReached(resetsAt: FlexibleDate.parse("2026-10-04T15:00:00+02:00")!.date)),
        // A day without a time of day is not guessed.
        ("You've hit your weekly limit · resets Oct 3", .usageLimitReached(resetsAt: nil)),
        ("You're out of usage credits. /model to switch models.", .usageLimitReached(resetsAt: nil)),
        ("Prompt is too long", .contextTooLong),
        ("Credit balance is too low", .billing),
        ("API Error: Connection error.", .network(.other)),
        ("API Error: Request timed out.", .network(.timedOut)),
        ("getaddrinfo ENOTFOUND api.anthropic.com", .network(.offline)),
        ("API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}", .overloaded),
        ("API Error: 500 Internal server error", .server(status: 500)),
        ("API Error: 404 model: claude-nope not_found_error", .modelNotFound(model: "sonnet")),
    ])
    func classifiesErrorTexts(text: String, expected: LLMError) {
        #expect(classify(text) == expected)
    }

    @Test func structuredSignalsWin() {
        #expect(classify("", terminal: "aborted_streaming", subtype: "error_during_execution") == .cancelled)
        #expect(classify("", terminal: "aborted_tools", subtype: "error_during_execution") == .cancelled)
        #expect(classify("", terminal: "prompt_too_long") == .contextTooLong)
        #expect(classify("", status: 401) == .claudeCodeNotLoggedIn)
        #expect(classify("", status: 403) == .permissionDenied)
        #expect(classify("", status: 429) == .rateLimited(retryAfter: nil))
        #expect(classify("", status: 503) == .server(status: 503))
        let rejected = RateLimitInfo(status: "rejected", utilization: 1, resetsAt: Self.reset, window: "five_hour",
                                     isUsingOverage: false)
        #expect(classify("API Error: 429", status: 429, rateLimit: rejected) == .usageLimitReached(resetsAt: Self.reset))
        // A warning is not a rejection.
        let warning = RateLimitInfo(status: "allowed_warning", utilization: 0.9, resetsAt: Self.reset, window: nil,
                                    isUsingOverage: false)
        #expect(classify("API Error: Connection error.", rateLimit: warning) == .network(.other))
    }

    /// Only a rejection says when the limit resets. Claude Code warns early
    /// (from about a quarter of a window, e.g. the week's): a limit it then
    /// reports only as text gets the time of that text, not the warning's.
    @Test func aWarningOfAnotherWindowDoesNotSetTheResetTime() {
        let text = "You've hit your limit · resets 3pm (Europe/Berlin)"
        let weekWarning = RateLimitInfo(status: "allowed_warning", utilization: 0.31, resetsAt: Self.now.addingTimeInterval(5 * 86_400),
                                        window: "seven_day", isUsingOverage: false)
        #expect(classify(text, status: 429, rateLimit: weekWarning)
                == .usageLimitReached(resetsAt: FlexibleDate.parse("2026-10-04T15:00:00+02:00")!.date))
        #expect(classify("You've hit your limit", rateLimit: weekWarning) == .usageLimitReached(resetsAt: nil), "no time is guessed")
        // A rejection is about this limit: its time wins over the text's.
        let rejected = RateLimitInfo(status: "rejected", utilization: 1, resetsAt: Self.reset, window: "five_hour",
                                     isUsingOverage: false)
        #expect(classify(text, status: 429, rateLimit: rejected) == .usageLimitReached(resetsAt: Self.reset))
    }

    @Test func unknownErrorsStayGenericAndKeepTheTextOutOfTheUI() {
        let error = classify("Something odd happened", subtype: "error_during_execution")
        #expect(error == .streamError(type: "claude_code_error_during_execution", message: "Something odd happened"))
        #expect(!error.userMessage.contains("odd"))
        #expect(error.isRetryable)
    }

    @Test func classifiesProcessExits() {
        // Orbit's options exist in current versions only.
        #expect(ClaudeCodeErrorClassifier.processExit(.exited(1), stderr: "error: unknown option '--disable-slash-commands'",
                                                      model: "sonnet") == .claudeCodeOutdated)
        #expect(ClaudeCodeErrorClassifier.processExit(.exited(1), stderr: "You've hit your limit · resets 3pm (Europe/Berlin)",
                                                      model: "sonnet", now: Self.now)
                == .usageLimitReached(resetsAt: FlexibleDate.parse("2026-10-04T15:00:00+02:00")!.date))
        #expect(ClaudeCodeErrorClassifier.processExit(.exited(1), stderr: "Not logged in. Run claude auth login to authenticate.",
                                                      model: "sonnet") == .claudeCodeNotLoggedIn)
        #expect(ClaudeCodeErrorClassifier.processExit(.exited(1), stderr: "Error: model 'x' not found", model: "x")
                == .modelNotFound(model: "x"))
        #expect(ClaudeCodeErrorClassifier.processExit(.signaled(9), stderr: "", model: "sonnet")
                == .providerProcessFailed(detail: "Claude Code ended unexpectedly (signal 9)"))
    }

    /// "resets 3pm (Europe/Berlin)": the next 3 pm in that zone, tomorrow once
    /// it has passed; without a zone in the Mac's.
    @Test func readsTheResetTimeOfTheLimitText() {
        func reset(_ text: String, now: Date = Self.now) -> Date? {
            ClaudeCodeErrorClassifier.resetTime(in: text, now: now, timeZone: Self.berlin)
        }
        #expect(reset("You've hit your limit · resets 3pm (Europe/Berlin)") == FlexibleDate.parse("2026-10-04T15:00:00+02:00")!.date)
        #expect(reset("resets at 10:15am") == FlexibleDate.parse("2026-10-05T10:15:00+02:00")!.date, "10:15 has passed today")
        #expect(reset("Limit reached, resets 9am (America/New_York)") == FlexibleDate.parse("2026-10-04T09:00:00-04:00")!.date)
        #expect(reset("resets 12am") == FlexibleDate.parse("2026-10-05T00:00:00+02:00")!.date)
        #expect(reset("resets 12pm") == FlexibleDate.parse("2026-10-04T12:00:00+02:00")!.date)
        #expect(reset("resets 3pm (Not/A_Zone)") == FlexibleDate.parse("2026-10-04T15:00:00+02:00")!.date, "an unknown zone: the Mac's")
        for text in ["resets Oct 3", "resets 13pm", "resets 3:75pm", "resets soon", "presets 3pm", "You've hit your limit"] {
            #expect(reset(text) == nil, "\(text)")
        }
    }

    @Test func parsesTheLegacyResetTime() {
        #expect(ClaudeCodeErrorClassifier.legacyUsageLimitReset(in: "Claude AI usage limit reached|1790700000") == Self.reset)
        #expect(ClaudeCodeErrorClassifier.legacyUsageLimitReset(in: "usage limit reached") == nil)
    }
}
