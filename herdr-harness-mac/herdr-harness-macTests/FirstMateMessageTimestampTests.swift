import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Surface-aware First Mate timestamps")
struct FirstMateMessageTimestampTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ raw: String) -> Date { HerdrTimestamp.date(from: raw)! }
    private func label(_ raw: String, now: String, zone: TimeZone? = nil,
                       surface: FirstMateMessageTimestamp.Surface = .mainChat,
                       locale: String = "en_GB") -> FirstMateMessageTimestamp? {
        .make(raw, surface: surface, now: date(now), calendar: calendar,
              locale: Locale(identifier: locale), timeZone: zone ?? utc)
    }

    @Test("Standalone day pills supply dates; main chat adds contextual dates")
    func surfaces() throws {
        let raw = "2030-06-14T15:25:00Z"
        let standalone = try #require(label(raw, now: raw, surface: .standalone))
        let main = try #require(label(raw, now: raw))
        #expect(standalone.label == "15:25")
        #expect(main.label == "Today · 15:25")
        #expect(main.detail == standalone.detail)
        #expect(main.detail.contains("2030"))
        #expect(main.detail.contains("June"))
        #expect(main.detail.contains("15:25"))
        #expect(main.detail.contains("Greenwich Mean Time"))
        #expect(label("2030-06-14T15:25:00.123Z", now: raw)?.label == main.label)
        #expect(label("2030-06-14T17:25:00+02:00", now: raw)?.label == main.label)
    }

    @Test("Clock output honors 12/24-hour locales and explicit time zones")
    func preferredClock() throws {
        let raw = "2030-06-14T15:25:00Z"
        let us = try #require(label(raw, now: raw, surface: .standalone, locale: "en_US"))
        #expect(us.label.contains("3:25"))
        #expect(us.label.contains("PM"))
        #expect(label(raw, now: raw, surface: .standalone)?.label == "15:25")
        let offset = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!
        #expect(label(raw, now: raw, zone: offset, surface: .standalone)?.label == "20:55")
    }

    @Test("Calendar days, not elapsed 24-hour durations, determine Yesterday across DST")
    func boundaries() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(label("2030-03-10T07:59:00Z", now: "2030-03-10T08:01:00Z", zone: zone)?.label == "Yesterday · 23:59")
        // Spring's previous day is only 23 hours long; fall's is 25 hours long.
        #expect(label("2030-03-10T08:30:00Z", now: "2030-03-11T07:30:00Z", zone: zone)?.label == "Yesterday · 00:30")
        #expect(label("2030-11-03T07:30:00Z", now: "2030-11-04T08:30:00Z", zone: zone)?.label == "Yesterday · 00:30")
        #expect(label("2030-06-15T00:05:00Z", now: "2030-06-14T23:55:00Z")?.label == "15 Jun · 00:05")
    }

    @Test("Older years and future dates are explicit, never negative relative ages")
    func datesAndInvalidInput() {
        let now = "2030-06-14T15:25:00Z"
        #expect(label("2030-06-12T10:00:00Z", now: now)?.label == "12 Jun · 10:00")
        #expect(label("2029-06-14T10:00:00Z", now: now)?.label == "14 Jun 2029 · 10:00")
        #expect(label("2031-06-14T10:00:00Z", now: now)?.label == "14 Jun 2031 · 10:00")
        #expect(label("2029-12-31T23:59:00Z", now: "2030-01-01T00:01:00Z")?.label == "Yesterday · 23:59")
        for raw in ["", "not-a-date", "2030-06-14", "2030-99-99T00:00:00Z"] {
            #expect(label(raw, now: now) == nil)
            #expect(label(raw, now: now, surface: .standalone) == nil)
        }
    }

    @Test("Sidebar's non-today policy remains the shared policy")
    func sidebarPolicy() {
        var context = FirstMateTimestampContext(calendar: calendar, locale: Locale(identifier: "en_US"), timeZone: utc)
        context.calendar.timeZone = utc
        let now = date("2030-06-14T15:25:00Z")
        #expect(FirstMateMessageTimestamp.sidebarLabel(for: now, now: now, context: context) == context.clock(now))
        for raw in ["2030-06-13T10:00:00Z", "2030-06-10T10:00:00Z", "2029-06-14T10:00:00Z", "2030-06-15T10:00:00Z"] {
            let date = date(raw)
            #expect(FirstMateMessageTimestamp.sidebarLabel(for: date, now: now, context: context)
                    == FirstMateChatTime.label(for: date, now: now, calendar: context.calendar))
        }
    }
}
