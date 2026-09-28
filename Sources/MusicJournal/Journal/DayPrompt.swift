import Foundation

/// When to ask "How was the day?" (DESIGN: ask once the day has mostly happened).
/// From 5 pm, about today. From 4 am to 5 pm, once about yesterday if you wrote that day
/// and didn't rate it. Between midnight and 4 am it's still "tonight", so the day that
/// just ended. A day you've rated yourself, or dismissed with "Not now", isn't asked again.
enum DayPrompt {
    static func day(now: Date, calendar: Calendar = .current,
                    isConfirmed: (Date) -> Bool, hasEntries: (Date) -> Bool,
                    dismissed: Set<String>) -> Date? {
        let hour = calendar.component(.hour, from: now)
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        let candidate: Date
        if hour >= 17 {
            candidate = today
        } else if hour >= 4 {
            guard hasEntries(yesterday) else { return nil }
            candidate = yesterday
        } else {
            candidate = yesterday
        }
        guard !isConfirmed(candidate), !dismissed.contains(key(candidate, calendar: calendar)) else { return nil }
        return candidate
    }

    /// "2026-09-27", for remembering dismissed days.
    static func key(_ day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
