import SwiftUI

/// Mac presentation only; the shared/mobile transcript time policy is unchanged.
struct FirstMateMessageTimestamp: Equatable {
    enum Surface { case standalone, mainChat }
    let label: String
    let detail: String

    static func make(
        _ raw: String, surface: Surface, now: Date,
        calendar: Calendar = .current, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> Self? {
        guard let date = HerdrTimestamp.date(from: raw) else { return nil }
        var calendar = calendar
        calendar.timeZone = timeZone
        let time = clock(for: date, calendar: calendar, locale: locale, timeZone: timeZone)
        let label: String
        if surface == .standalone {
            label = time
        } else {
            let days = FirstMateChatTime.daysBefore(date, now: now, calendar: calendar)
            let day: String
            switch days {
            case 0: day = String(localized: "Today", locale: locale)
            case 1: day = String(localized: "Yesterday", locale: locale)
            default:
                let formatter = formatter(calendar: calendar, locale: locale, timeZone: timeZone)
                formatter.setLocalizedDateFormatFromTemplate(
                    calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd"
                )
                day = formatter.string(from: date)
            }
            label = "\(day) · \(time)"
        }
        let full = formatter(calendar: calendar, locale: locale, timeZone: timeZone)
        full.setLocalizedDateFormatFromTemplate("yMMMMdjjmmsszzzz")
        return Self(label: label, detail: full.string(from: date))
    }

    /// DateFormatter's short style respects the system's preferred clock, including
    /// the macOS 24-hour override, rather than imposing an HH:mm pattern.
    static func clock(
        for date: Date, calendar: Calendar = .current,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        let formatter = formatter(calendar: calendar, locale: locale, timeZone: timeZone)
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func sidebarLabel(for date: Date, now: Date, context: FirstMateTimestampContext) -> String {
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return clock(for: date, calendar: calendar, locale: context.locale, timeZone: context.timeZone)
        }
        return FirstMateChatTime.label(for: date, now: now, calendar: calendar)
    }

    private static func formatter(calendar: Calendar, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        return formatter
    }
}

/// Injectable formatting preferences for hosted tests. Production resolves current
/// preferences on each render, including after app activation.
struct FirstMateTimestampContext {
    var calendar: Calendar = .current
    var locale: Locale = .current
    var timeZone: TimeZone = .current

    func timestamp(_ raw: String, surface: FirstMateMessageTimestamp.Surface, now: Date) -> FirstMateMessageTimestamp? {
        .make(raw, surface: surface, now: now, calendar: calendar, locale: locale, timeZone: timeZone)
    }

    func clock(_ date: Date) -> String {
        FirstMateMessageTimestamp.clock(for: date, calendar: calendar, locale: locale, timeZone: timeZone)
    }
}

private struct FirstMateTimestampContextKey: EnvironmentKey {
    static let defaultValue: FirstMateTimestampContext? = nil
}

extension EnvironmentValues {
    var firstMateTimestampContext: FirstMateTimestampContext? {
        get { self[FirstMateTimestampContextKey.self] }
        set { self[FirstMateTimestampContextKey.self] = newValue }
    }
}

struct FirstMateTimestampLabel: View {
    let timestamp: FirstMateMessageTimestamp
    let messageID: String

    var body: some View {
        Text(timestamp.label)
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .help(timestamp.detail)
            .accessibilityLabel("Sent \(timestamp.detail)")
            .accessibilityIdentifier("first-mate-timestamp-\(messageID)")
            .firstMateFooterPart(messageID, "timestamp")
            .preference(key: FirstMateClockLabelKey.self, value: [messageID: timestamp.label])
    }
}

struct FirstMateClockLabelKey: PreferenceKey {
    static let defaultValue: [String: String] = [:]
    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
