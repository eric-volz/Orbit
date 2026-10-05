import Foundation

/// Maps Claude Code's error reports to `LLMError`. The CLI reports failures as
/// text ("Not logged in · Please run /login", "You've hit your limit · resets
/// 3pm", "API Error: Connection error.") plus a few structured fields; the
/// structured signals win, the texts are matched loosely. The CLI's text is
/// never part of what the user sees.
enum ClaudeCodeErrorClassifier {
    struct Report: Sendable, Hashable {
        /// `result.subtype`, e.g. "success" (with `is_error`), "error_during_execution".
        var subtype: String
        /// `result.terminal_reason`, e.g. "aborted_streaming", "prompt_too_long".
        var terminalReason: String?
        /// HTTP status of the API error, when Claude Code reports one.
        var apiErrorStatus: Int?
        /// Error texts of the result and of synthetic error messages.
        var text: String
        /// The last usage-limit state of the turn (a rejection, or a warning
        /// that may be about another window).
        var rateLimit: RateLimitInfo?
        var model: String
    }

    static func classify(_ report: Report, now: Date = Date()) -> LLMError {
        let text = report.text.lowercased()
        let status = report.apiErrorStatus

        switch report.terminalReason {
        case "aborted_streaming", "aborted_tools":
            return .cancelled
        case "prompt_too_long", "blocking_limit":
            return .contextTooLong
        default:
            break
        }
        if text.contains("prompt is too long") || (text.contains("context window") && text.contains("exceed")) {
            return .contextTooLong
        }
        if let resetsAt = legacyUsageLimitReset(in: report.text) {
            return .usageLimitReached(resetsAt: resetsAt)
        }
        if report.rateLimit?.isRejected == true || mentionsUsageLimit(text) {
            // Only the rejection tells when this limit resets: an earlier warning may be about another
            // window (e.g. the week's while the five hours ran out).
            let rejection = report.rateLimit.flatMap { $0.isRejected ? $0.resetsAt : nil }
            return .usageLimitReached(resetsAt: rejection ?? resetTime(in: report.text, now: now))
        }
        if status == 401 || mentionsLogin(text) {
            return .claudeCodeNotLoggedIn
        }
        if status == 403 || text.contains("permission_error") {
            return .permissionDenied
        }
        if text.contains("credit balance") {
            return .billing
        }
        if status == 529 || text.contains("overloaded") {
            return .overloaded
        }
        if status == 429 || text.contains("rate limit") || text.contains("rate_limit") {
            return .rateLimited(retryAfter: nil)
        }
        if let failure = networkFailure(text) {
            return .network(failure)
        }
        if status == 404 || mentionsMissingModel(text) {
            return .modelNotFound(model: report.model)
        }
        if let status, (500...599).contains(status) {
            return .server(status: status)
        }
        if text.contains("internal server error") || text.contains("api error: 5") {
            return .server(status: 500)
        }
        if status == 413 {
            return .requestTooLarge
        }
        if status == 400 {
            return .invalidRequest(message: report.text)
        }
        return .streamError(type: "claude_code_\(report.subtype)", message: report.text)
    }

    /// The error for a Claude Code process that ended without finishing the
    /// turn. `stderr` is its diagnostic output (never shown).
    static func processExit(_ exit: ClaudeCodeProcess.Exit, stderr: String, model: String, now: Date = Date()) -> LLMError {
        let text = stderr.lowercased()
        if mentionsLogin(text) {
            return .claudeCodeNotLoggedIn
        }
        if mentionsUsageLimit(text) {
            return .usageLimitReached(resetsAt: legacyUsageLimitReset(in: stderr) ?? resetTime(in: stderr, now: now))
        }
        if text.contains("unknown option") || text.contains("error: option") || text.contains("unexpected argument") {
            // Orbit's options exist in current versions only: an older Claude Code must be updated.
            return .claudeCodeOutdated
        }
        if mentionsMissingModel(text) {
            return .modelNotFound(model: model)
        }
        return .providerProcessFailed(detail: "Claude Code ended unexpectedly (\(exit))")
    }

    // MARK: Text patterns

    /// Older CLIs: "Claude AI usage limit reached|1790000000" (reset as Unix time).
    static func legacyUsageLimitReset(in text: String) -> Date? {
        guard let range = text.range(of: #"usage limit reached\|(\d{9,11})"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let digits = text[range].split(separator: "|").last.map(String.init) ?? ""
        return TimeInterval(digits).map { Date(timeIntervalSince1970: $0) }
    }

    /// "resets 3pm (Europe/Berlin)", "resets at 10:30am": the next such time
    /// after `now`, in the named time zone (else the Mac's); nil when the text
    /// names no time of day (e.g. "resets Oct 3").
    static func resetTime(in text: String, now: Date, timeZone: TimeZone = .current) -> Date? {
        let pattern = #"\bresets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b(?:\s*\(([A-Za-z_]+(?:/[A-Za-z0-9_+-]+)+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let hour = group(1).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(4).flatMap(TimeZone.init(identifier:)) ?? timeZone
        let hour24 = hour % 12 + (group(3)?.lowercased() == "pm" ? 12 : 0)
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour24, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }

    static func mentionsUsageLimit(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["usage limit", "hit your limit", "out of usage", "out of extra usage", "spend limit", "weekly limit",
                "session limit", "5-hour limit", "opus limit", "sonnet limit"].contains { text.contains($0) }
            || (text.contains("hit your") && text.contains("limit"))
    }

    static func mentionsLogin(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["/login", "not logged in", "login expired", "oauth token", "oauth access token", "re-authenticate",
                "invalid api key", "authentication_error", "authentication failed", "auth login", "please log in",
                "invalid bearer token"].contains { text.contains($0) }
    }

    private static func mentionsMissingModel(_ text: String) -> Bool {
        text.contains("model") && ["not found", "not_found", "does not exist", "invalid model", "not available",
                                   "unknown model"].contains { text.contains($0) }
    }

    private static func networkFailure(_ text: String) -> NetworkFailure? {
        if ["certificate", "ssl", "tls handshake", "self signed", "self-signed"].contains(where: text.contains) {
            return .secureConnection
        }
        if ["enotfound", "getaddrinfo", "network is unreachable", "enetunreach", "not connected to the internet",
            "offline"].contains(where: text.contains) {
            return .offline
        }
        if ["timed out", "timeout", "etimedout"].contains(where: text.contains) {
            return .timedOut
        }
        if ["connection error", "connection refused", "econnrefused", "econnreset", "socket hang up", "fetch failed",
            "unable to connect", "connection lost", "no response from api", "network error"].contains(where: text.contains) {
            return .other
        }
        return nil
    }
}
