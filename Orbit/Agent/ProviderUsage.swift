import Foundation

/// Texts about the usage limits of the Claude subscription, as Claude Code
/// reports them (`RateLimitInfo`). Used by the chat notice and the settings.
enum ProviderUsage {
    /// Shares of the limit at which Orbit warns, once per window each.
    /// (Claude Code reports "allowed_warning" much earlier, e.g. at 26 %.)
    static let warningThresholds = [0.8, 0.95]

    /// The highest warning threshold `info` has reached; nil = no warning.
    static func warningThreshold(for info: RateLimitInfo) -> Double? {
        guard info.isWarning || info.isRejected, let utilization = info.utilization else { return nil }
        return warningThresholds.last { utilization >= $0 }
    }

    /// Used share in percent (0…100), if reported.
    static func percent(of info: RateLimitInfo) -> Int? {
        info.utilization.map { Int((min(max($0, 0), 1) * 100).rounded()) }
    }

    /// "5-hour window", "7-day window", …; nil for unknown windows.
    static func windowName(_ window: String?) -> String? {
        switch window {
        case "five_hour": String(localized: "5-hour window")
        case "seven_day": String(localized: "7-day window")
        case "seven_day_opus": String(localized: "7-day window for Opus")
        case "seven_day_sonnet": String(localized: "7-day window for Sonnet")
        default: nil
        }
    }

    /// Chat notice, e.g. "Du hast 82 % deines Claude-Kontingents genutzt
    /// (5-Stunden-Fenster). Es wird am 29. Sept. 2026, 18:00 zurückgesetzt."
    static func warningMessage(for info: RateLimitInfo) -> String {
        let percent = Int64(percent(of: info) ?? 0)
        var message: String
        if let window = windowName(info.window) {
            message = String(format: String(localized: "You have used %1$lld%% of your Claude usage limit (%2$@)."),
                             percent, window)
        } else {
            message = String(format: String(localized: "You have used %lld%% of your Claude usage limit."), percent)
        }
        if let reset = resetText(for: info) {
            message += " " + reset
        }
        return message
    }

    /// Settings line, e.g. "26 % genutzt (7-Tage-Fenster)".
    static func usageText(for info: RateLimitInfo) -> String? {
        guard let percent = percent(of: info).map(Int64.init) else { return nil }
        if let window = windowName(info.window) {
            return String(format: String(localized: "%1$lld%% used (%2$@)"), percent, window)
        }
        return String(format: String(localized: "%lld%% used"), percent)
    }

    /// "Es wird am 29. Sept. 2026, 18:00 zurückgesetzt."; nil when unknown.
    static func resetText(for info: RateLimitInfo, locale: Locale = AppLanguage.locale) -> String? {
        guard let resetsAt = info.resetsAt else { return nil }
        return String(format: String(localized: "It resets on %@."), resetDate(resetsAt, locale: locale))
    }

    /// When a limit resets: "29. Sept. 2026, 18:00", "Sep 29, 2026 at 6:00 PM".
    static func resetDate(_ date: Date, locale: Locale = AppLanguage.locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }
}
