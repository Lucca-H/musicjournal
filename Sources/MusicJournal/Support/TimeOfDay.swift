import Foundation

/// "Friday early morning", "Saturday late afternoon": a specific, human time of day.
/// Shown as the greeting and sent with each mood so Claude reads the moment the same way.
enum TimeOfDay {
    /// The part of the day for an hour, 0–23.
    static func part(forHour hour: Int) -> String {
        switch hour {
        case 0..<3: "late night"
        case 3..<5: "small hours"
        case 5..<8: "early morning"
        case 8..<11: "morning"
        case 11..<13: "midday"
        case 13..<15: "early afternoon"
        case 15..<17: "late afternoon"
        case 17..<19: "early evening"
        case 19..<21: "evening"
        default: "night"
        }
    }

    static func describe(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        // Weekday and hour must come from the same calendar and time zone.
        let style = Date.FormatStyle(
            date: .omitted, time: .omitted,
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone
        ).weekday(.wide)
        let weekday = date.formatted(style)
        return "\(weekday) \(part(forHour: calendar.component(.hour, from: date)))"
    }
}
