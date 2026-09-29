import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("Transcript-owned presentation clock", .serialized)
@MainActor
struct FirstMateTranscriptClockTests {
    @Test("Appearance, day change, and activation refresh one owner; stop removes observations")
    func notifications() {
        let center = NotificationCenter()
        var now = HerdrTimestamp.date(from: "2030-06-14T23:59:00Z")!
        let clock = FirstMateTranscriptClock(now: { now }, center: center)
        #expect(clock.observationCount == 0)
        now = now.addingTimeInterval(30)
        clock.start()
        #expect(clock.now == now)
        #expect(clock.observationCount == 2)
        clock.start()
        #expect(clock.observationCount == 2)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let raw = "2030-06-14T20:00:00Z"
        let message = FirstMateMessage(id: "clock", featureID: "synthetic", role: "assistant", text: "Answer", status: "done", createdAt: raw)
        func context() -> String? {
            FirstMateMessageTimestamp.make(raw, surface: .mainChat, now: clock.now, calendar: calendar,
                                           locale: Locale(identifier: "en_GB"), timeZone: calendar.timeZone)?.label
        }
        func pill() -> String? {
            FirstMateTranscriptLayout.rows(for: [message], now: clock.now, calendar: calendar).first?.dayLabel
        }
        #expect(context() == "Today · 20:00")
        #expect(pill() == "Today")
        now = now.addingTimeInterval(60)
        center.post(name: .NSCalendarDayChanged, object: nil)
        #expect(clock.now == now)
        #expect(context() == "Yesterday · 20:00")
        #expect(pill() == "Yesterday")
        now = now.addingTimeInterval(24 * 3600)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(clock.now == now)
        #expect(context() == "14 Jun · 20:00")
        #expect(pill() != "Yesterday")

        clock.stop()
        #expect(clock.observationCount == 0)
        let stopped = clock.now
        now = now.addingTimeInterval(24 * 3600)
        center.post(name: .NSCalendarDayChanged, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(clock.now == stopped)
        clock.start()
        #expect(clock.now == now)
        #expect(clock.observationCount == 2)
        clock.stop()
    }

    @Test("Destroying an active owner cleans up notification tokens without retaining it")
    func destruction() {
        let center = CountingNotificationCenter()
        var clock: FirstMateTranscriptClock? = FirstMateTranscriptClock(center: center)
        weak var weakClock = clock
        clock?.start()
        #expect(center.added == 2)
        clock = nil
        #expect(weakClock == nil)
        #expect(center.removed == 2)
    }
}

private final class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
    var added = 0
    var removed = 0
    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        added += 1
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}
