import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("My First Mate briefing")
struct FirstMateLeadBriefingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2030, month: 1, day: day, hour: hour, minute: minute))!
    }

    @Test("The full briefing names each feature that needs you, then what is moving and what shipped")
    func fullBriefing() {
        let conversations = [
            ChatFixtures.conversation("Receipt export", hud: .blocked, step: 3),
            ChatFixtures.conversation("Release checklist refresh", hud: .turn, step: 2),
            ChatFixtures.conversation("Review search", hud: .ready, step: 4),
            ChatFixtures.conversation("Quiet notifications", hud: .working, step: 1),
            ChatFixtures.conversation("Offline sync", hud: .working, step: 2),
            ChatFixtures.conversation("Home screen widgets", hud: .idle, step: 0),
            ChatFixtures.conversation("Workspace launch polish", hud: .done, step: 5, activityAt: date(9, 16)),
        ]
        let briefing = FirstMateLeadBriefing.build(conversations: conversations, now: date(10, 9), calendar: calendar)
        #expect(briefing.greeting == "Good morning")
        #expect(briefing.plainText == "Good morning. 3 features need you: Receipt export is blocked in QA, "
            + "Release checklist refresh needs a call, and Review search is ready for review. "
            + "Quiet notifications, Offline sync, and Home screen widgets are moving, and Workspace launch polish shipped yesterday.")
        let mentions = briefing.segments.compactMap { segment -> String? in
            if case .mention(let conversation) = segment { return conversation.title }
            return nil
        }
        // Needs you (blocked, turn, ready), then moving, then the one that shipped.
        #expect(mentions == conversations.map(\.title))
        for (previous, next) in zip(briefing.segments, briefing.segments.dropFirst()) {
            if case .text = previous, case .text = next { Issue.record("Adjacent text segments were not merged") }
        }
    }

    @Test("Groups read blocked, your turn, then ready, whatever the list order")
    func needsYouOrder() {
        let conversations = [
            ChatFixtures.conversation("C", hud: .ready),
            ChatFixtures.conversation("B", hud: .turn),
            ChatFixtures.conversation("A", hud: .blocked, step: 0),
            ChatFixtures.conversation("D", hud: .blocked, step: 4),
        ]
        let text = FirstMateLeadBriefing.build(conversations: conversations, now: date(10, 13), calendar: calendar).plainText
        #expect(text == "Good afternoon. 4 features need you: A is blocked in Plan, D is blocked in PR, B needs a call, and C is ready for review.")
    }

    @Test("One of each reads in the singular, and two items take no comma")
    func pluralization() {
        let single = FirstMateLeadBriefing.build(conversations: [
            ChatFixtures.conversation("Solo", hud: .turn),
            ChatFixtures.conversation("Mover", hud: .working),
        ], now: date(10, 20), calendar: calendar).plainText
        #expect(single == "Good evening. 1 feature needs you: Solo needs a call. Mover is moving.")

        let pair = FirstMateLeadBriefing.build(conversations: [
            ChatFixtures.conversation("A", hud: .ready),
            ChatFixtures.conversation("B", hud: .ready),
            ChatFixtures.conversation("C", hud: .working),
            ChatFixtures.conversation("D", hud: .idle),
        ], now: date(10, 8), calendar: calendar).plainText
        #expect(pair == "Good morning. 2 features need you: A is ready for review and B is ready for review. C and D are moving.")
    }

    @Test("A blocked feature with an unknown step is just blocked")
    func unknownStep() {
        let text = FirstMateLeadBriefing.build(conversations: [ChatFixtures.conversation("Legacy", hud: .blocked)],
                                               now: date(10, 8), calendar: calendar).plainText
        #expect(text == "Good morning. 1 feature needs you: Legacy is blocked.")
    }

    @Test("When nothing needs you the briefing says so, and still reports progress")
    func nothingNeedsYou() {
        #expect(FirstMateLeadBriefing.build(conversations: [], now: date(10, 23), calendar: calendar).plainText
            == "Good evening. Nothing needs you right now.")
        let conversations = [
            ChatFixtures.conversation("Older", hud: .done, activityAt: date(1, 12)),
            ChatFixtures.conversation("Newest", hud: .done, activityAt: date(10, 7)),
        ]
        #expect(FirstMateLeadBriefing.build(conversations: conversations, now: date(10, 9), calendar: calendar).plainText
            == "Good morning. Nothing needs you right now. Newest shipped today.")
        #expect(FirstMateLeadBriefing.build(conversations: [conversations[0]], now: date(10, 9), calendar: calendar).plainText
            == "Good morning. Nothing needs you right now. Older shipped on January 1.")
    }

    @Test("Greetings follow the hour")
    func greetings() {
        #expect(FirstMateLeadBriefing.greeting(for: date(10, 4), calendar: calendar) == "Good evening")
        #expect(FirstMateLeadBriefing.greeting(for: date(10, 5), calendar: calendar) == "Good morning")
        #expect(FirstMateLeadBriefing.greeting(for: date(10, 11, 59), calendar: calendar) == "Good morning")
        #expect(FirstMateLeadBriefing.greeting(for: date(10, 12), calendar: calendar) == "Good afternoon")
        #expect(FirstMateLeadBriefing.greeting(for: date(10, 17), calendar: calendar) == "Good evening")
    }

    @Test("The lead row and header summarize the same groups")
    func rowAndHeader() {
        let demo = [
            ChatFixtures.conversation("a", hud: .blocked), ChatFixtures.conversation("b", hud: .turn),
            ChatFixtures.conversation("c", hud: .ready), ChatFixtures.conversation("d", hud: .working),
            ChatFixtures.conversation("e", hud: .working), ChatFixtures.conversation("f", hud: .idle),
            ChatFixtures.conversation("g", hud: .done),
        ]
        #expect(FirstMateLeadBriefing.leadRowPreview(conversations: demo) == "3 features need you")
        #expect(FirstMateLeadBriefing.headerSubtitle(conversations: demo) == "3 need you, 3 moving, 1 done")
        #expect(FirstMateLeadBriefing.leadRowPreview(conversations: [demo[0]]) == "1 feature needs you")
        #expect(FirstMateLeadBriefing.leadRowPreview(conversations: [demo[3]]) == "Nothing needs you")
        #expect(FirstMateLeadBriefing.headerSubtitle(conversations: [demo[3], demo[6]]) == "1 moving, 1 done")
        #expect(FirstMateLeadBriefing.headerSubtitle(conversations: []) == "No features yet")
    }

    @Test("The sidebar subtitle agrees in number")
    func sidebarSubtitle() {
        #expect(FirstMateChatSidebar.subtitle(featureCount: 1, needCount: 1) == "1 feature, 1 needs you")
        #expect(FirstMateChatSidebar.subtitle(featureCount: 7, needCount: 3) == "7 features, 3 need you")
        #expect(FirstMateChatSidebar.subtitle(featureCount: 7, needCount: 0) == "7 features, 0 need you")
    }
}

@Suite("First Mate chat time labels")
struct FirstMateChatTimeTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2030, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Same day, yesterday, this week, and older dates", arguments: [
        (1, 10, 9, 5, "09:05"),
        (1, 10, 0, 0, "00:00"),
        (1, 10, 23, 59, "23:59"),
        (1, 9, 23, 59, "Yesterday"),
        (1, 9, 0, 0, "Yesterday"),
        (1, 7, 12, 0, "Monday"),
        (1, 4, 12, 0, "Friday"),
        (1, 3, 12, 0, "Jan 3"),
        (12, 25, 8, 0, "Dec 25"),
        (1, 11, 8, 0, "Jan 11"),
    ])
    func labels(month: Int, day: Int, hour: Int, minute: Int, expected: String) {
        // Thursday, January 10, 2030, at noon.
        let now = date(1, 10, 12)
        #expect(FirstMateChatTime.label(for: date(month, day, hour, minute).addingTimeInterval(month == 12 ? -365 * 86_400 : 0),
                                        now: now, calendar: calendar) == expected)
    }

    @Test("Day separators say Today, and bubbles always show the clock")
    func dayLabelsAndClock() {
        let now = date(1, 10, 12)
        #expect(FirstMateChatTime.dayLabel(for: date(1, 10, 7), now: now, calendar: calendar) == "Today")
        #expect(FirstMateChatTime.dayLabel(for: date(1, 9, 7), now: now, calendar: calendar) == "Yesterday")
        #expect(FirstMateChatTime.clock(for: date(1, 2, 16, 22), calendar: calendar) == "16:22")
    }

    @Test("Labels follow the calendar's time zone")
    func timeZone() {
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = date(1, 10, 12)
        // 20:00 UTC on January 9 is 05:00 on January 10 in Tokyo.
        #expect(FirstMateChatTime.label(for: date(1, 9, 20), now: now, calendar: tokyo) == "05:00")
        #expect(FirstMateChatTime.label(for: date(1, 9, 20), now: now, calendar: calendar) == "Yesterday")
    }
}
