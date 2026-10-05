import Foundation

/// Parses the date formats models produce in tool arguments.
///
/// Accepted (time zone optional; without one the user's current time zone is used):
///   2026-09-28
///   2026-09-28T14:30 / 2026-09-28 14:30
///   2026-09-28T14:30:15 / 2026-09-28T14:30:15.250
///   2026-09-28T14:30:15Z / 2026-09-28T14:30:15+02:00 / 2026-09-28T14:30:15+0200
struct FlexibleDate: Sendable, Hashable {
    var date: Date
    /// True when the input had no time component ("2026-09-28").
    var isDateOnly: Bool

    static func parse(_ input: String, timeZone: TimeZone = .current) -> FlexibleDate? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 10 else { return nil }

        // Split off a trailing time zone designator.
        var body = Substring(text)
        var zone: TimeZone?
        if body.hasSuffix("Z") || body.hasSuffix("z") {
            zone = TimeZone(secondsFromGMT: 0)
            body = body.dropLast()
        } else if let signIndex = body.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  body.distance(from: body.startIndex, to: signIndex) >= 11 {
            // A sign after the date part ("…T14:30+02:00"); the date's own dashes come earlier.
            let designator = body[signIndex...]
            guard let offset = Self.parseOffset(designator) else { return nil }
            zone = TimeZone(secondsFromGMT: offset)
            body = body[..<signIndex]
        }

        let parts = body.split(whereSeparator: { $0 == "T" || $0 == "t" || $0 == " " })
        guard let datePart = parts.first, parts.count <= 2 else { return nil }
        let dateFields = datePart.split(separator: "-")
        guard dateFields.count == 3,
              dateFields[0].count == 4, let year = Int(dateFields[0]),
              let month = Int(dateFields[1]), (1...12).contains(month),
              let day = Int(dateFields[2]), (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0

        var isDateOnly = true
        if parts.count == 2 {
            isDateOnly = false
            let timeFields = parts[1].split(separator: ":")
            guard (2...3).contains(timeFields.count),
                  let hour = Int(timeFields[0]), (0...24).contains(hour),
                  let minute = Int(timeFields[1]), (0...59).contains(minute) else { return nil }
            components.hour = hour
            components.minute = minute
            if timeFields.count == 3 {
                let secondText = timeFields[2]
                guard let seconds = Double(secondText), seconds >= 0, seconds < 61 else { return nil }
                components.second = Int(seconds)
                components.nanosecond = Int((seconds - seconds.rounded(.down)) * 1_000_000_000)
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? timeZone
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day || components.hour == 24 else { return nil }
        return FlexibleDate(date: date, isDateOnly: isDateOnly)
    }

    /// Parses "+02:00", "+0200", "+02" into seconds from GMT.
    private static func parseOffset(_ designator: Substring) -> Int? {
        guard let sign = designator.first else { return nil }
        let digits = designator.dropFirst().filter { $0 != ":" }
        guard digits.allSatisfy(\.isNumber), digits.count == 2 || digits.count == 4 else { return nil }
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
        guard hours <= 14, minutes < 60 else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    /// Start of the day of `date` in `timeZone`.
    static func startOfDay(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    /// The last instant of the day of `date` in `timeZone` (start of next day − 1 ms).
    static func endOfDay(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return next.addingTimeInterval(-0.001)
    }

    /// ISO 8601 with offset in `timeZone`, e.g. "2026-09-28T14:30:00+02:00". Used
    /// when dates are shown to the model.
    static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
