import Foundation

/// Time labels for conversation rows, bubbles, and day separators.
enum FirstMateChatTime {
    /// Same day: 24-hour "HH:mm". The day before: "Yesterday". Within the
    /// last six days: the weekday name. Anything older, or in the future on
    /// another day: "MMM d".
    static func label(for date: Date, now: Date, calendar: Calendar) -> String {
        switch daysBefore(date, now: now, calendar: calendar) {
        case 0: clock(for: date, calendar: calendar)
        case 1: "Yesterday"
        case 2...6: weekday(for: date, calendar: calendar)
        default: monthDay(for: date, calendar: calendar)
        }
    }

    /// A bubble's time: always "HH:mm".
    static func clock(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A transcript day separator: "Today", "Yesterday", the weekday within
    /// the last six days, otherwise "MMM d".
    static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        daysBefore(date, now: now, calendar: calendar) == 0 ? "Today" : label(for: date, now: now, calendar: calendar)
    }

    /// Whole calendar days from `date` to `now`; negative in the future.
    static func daysBefore(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    private static func weekday(for date: Date, calendar: Calendar) -> String {
        let symbols = calendar.weekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : monthDay(for: date, calendar: calendar)
    }

    private static func monthDay(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        let symbols = calendar.shortMonthSymbols
        let month = (parts.month ?? 1) - 1
        return "\(symbols.indices.contains(month) ? symbols[month] : "") \(parts.day ?? 1)"
    }
}
