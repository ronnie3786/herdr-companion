import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate conversation list")
@MainActor
struct FirstMateConversationListTests {
    @Test("The dot shows only for an unread conversation that needs you")
    func dotRule() {
        for status in FirstMateHudStatus.allCases {
            for unread in [true, false] {
                let conversation = ChatFixtures.conversation("c", hud: status, unread: unread)
                #expect(conversation.showsDot == (unread && [.blocked, .turn, .ready].contains(status)), "\(status) unread=\(unread)")
            }
        }
    }

    @Test("Older companions use the fallback status, emoji, unknown step, and needs-you as unread")
    func fallback() throws {
        let host = ChatFixtures.host("legacy", features: [
            ChatFixtures.feature("f-blocked", title: "Receipt export", status: "blocked",
                                 activityAt: "2030-01-01T11:00:00Z", latestMessage: "**QA failed** on `iPad`. See [the log](https://example.invalid/log)."),
            ChatFixtures.feature("f-running", status: "coordinating", activityAt: "2030-01-01T10:00:00Z"),
            ChatFixtures.feature("f-done", status: "completed", activityAt: "2030-01-01T09:00:00Z"),
        ])
        let conversations = FirstMateConversationList.build(hosts: [host], readState: .init())
        #expect(conversations.map(\.featureID) == ["f-blocked", "f-running", "f-done"])
        let blocked = conversations[0]
        #expect(blocked.hudStatus == .blocked)
        #expect(blocked.emoji == FirstMateDefaultEmoji.emoji(for: "f-blocked"))
        #expect(blocked.label == "Receipt export")
        #expect(blocked.name == "Receipt export")
        #expect(!blocked.isUserNamed)
        #expect(blocked.stepIndex == nil)
        #expect(blocked.stepFraction == nil)
        #expect(blocked.isUnread)
        #expect(blocked.showsDot)
        #expect(blocked.previewText == "QA failed on iPad. See the log.")
        #expect(!blocked.previewIsFromUser)
        #expect(blocked.latestFirstMateMessageID == nil)
        #expect(conversations[1].hudStatus == .working)
        #expect(!conversations[1].isUnread)
        #expect(conversations[2].hudStatus == .done)
        #expect(conversations[2].previewText == "")
    }

    @Test("User labels become names; default and legacy clipped labels keep the full title")
    func presentationNames() throws {
        let longTitle = "A synthetic feature title that exceeds the default label limit"
        let entries = [
            FirstMateFleetEntry(featureID: "user", title: longTitle, label: "Friendly", emoji: "🪁",
                                status: "running", labelSource: "user"),
            FirstMateFleetEntry(featureID: "default", title: longTitle, label: "Friendly", status: "running", labelSource: "default"),
            FirstMateFleetEntry(featureID: "legacy", title: longTitle,
                                label: FirstMateFleetEntry.serverDefaultLabel(title: longTitle), status: "running"),
            FirstMateFleetEntry(featureID: "legacy-user", title: longTitle, label: "Legacy nickname", status: "running"),
        ]
        let host = ChatFixtures.host("alpha", features: [ChatFixtures.feature("fallback", title: longTitle)], entries: entries)
        let rows = Dictionary(uniqueKeysWithValues: FirstMateConversationList.build(hosts: [host], readState: .init()).map { ($0.featureID, $0) })
        #expect(rows["user"]?.name == "Friendly")
        #expect(rows["user"]?.emoji == "🪁")
        #expect(rows["user"]?.isUserNamed == true)
        #expect(rows["default"]?.name == longTitle)
        #expect(rows["default"]?.label == "Friendly")
        #expect(rows["legacy"]?.name == longTitle)
        #expect(rows["legacy-user"]?.name == "Legacy nickname")
        #expect(rows["fallback"]?.name == longTitle)
        #expect(rows["fallback"]?.isUserNamed == false)
    }

    @Test("Mentions present the user name while retaining title and label search aliases")
    func mentionNames() throws {
        let entry = FirstMateFleetEntry(featureID: "f1", title: "Synthetic feature", label: "Friendly name",
                                        status: "running", labelSource: "user")
        let row = try #require(FirstMateConversationList.build(hosts: [ChatFixtures.host("alpha", entries: [entry])], readState: .init()).first)
        let catalog = FirstMateMentionCatalog(conversations: [row], snapshot: nil)
        #expect(catalog.entries.map(\.name) == ["Friendly name", "Synthetic feature"])
        #expect(catalog.entry(for: .feature(featureID: "f1"))?.name == "Friendly name")
        let option = try #require(FirstMateMentionOption.options(query: "synthetic", features: [row], crew: []).first)
        #expect(option.candidate.name == "Friendly name")
        let picks = FirstMateMentionOption.picksForSend([], draft: "Ask @Synthetic feature", features: [row], crew: [])
        #expect(picks.map(\.name) == ["Synthetic feature"])
    }

    @Test("Newest activity comes first, undated rows last, ties stay stable")
    func ordering() {
        let alpha = ChatFixtures.host("alpha", entries: [
            ChatFixtures.entry("old", hud: .working, activityAt: "2030-01-01T08:00:00Z"),
            ChatFixtures.entry("new", hud: .working, activityAt: "2030-01-01T12:00:00.500Z"),
            ChatFixtures.entry("undated", hud: .idle, latestFirstMate: nil, activityAt: nil),
            ChatFixtures.entry("tie-b", hud: .idle, activityAt: "2030-01-01T09:00:00Z"),
        ])
        let beta = ChatFixtures.host("beta", features: [
            ChatFixtures.feature("tie-a", status: "ready", activityAt: "2030-01-01T09:00:00Z"),
            ChatFixtures.feature("middle", status: "ready", activityAt: "2030-01-01T10:00:00Z"),
        ])
        let order = FirstMateConversationList.build(hosts: [beta, alpha], readState: .init()).map(\.featureID)
        #expect(order == ["new", "middle", "tie-b", "tie-a", "old", "undated"])
    }

    @Test("Previews prefix your messages and prefer a First Mate message's skim sentence")
    func previews() throws {
        let host = ChatFixtures.host("alpha", entries: [
            ChatFixtures.entry("mine", hud: .working, latest: .init(id: "m1", role: "user", text: "Ship **it**\nplease")),
            ChatFixtures.entry("skim", hud: .working, latest: .init(id: "m2", role: "assistant", text: "A very long reply",
                                                                   skimSay: "Short and sweet.")),
            ChatFixtures.entry("empty-skim", hud: .working, latest: .init(id: "m3", role: "assistant", text: "# Heading\n\n- item one",
                                                                         skimSay: "  ")),
            FirstMateFleetEntry(featureID: "quiet", title: "Quiet", status: "ready", now: "Waiting for the data store."),
        ])
        let byID = Dictionary(uniqueKeysWithValues: FirstMateConversationList.build(hosts: [host], readState: .init()).map { ($0.featureID, $0) })
        #expect(byID["mine"]?.previewText == "You: Ship it please")
        #expect(byID["mine"]?.previewIsFromUser == true)
        #expect(byID["skim"]?.previewText == "Short and sweet.")
        #expect(byID["empty-skim"]?.previewText == "Heading item one")
        #expect(byID["quiet"]?.previewText == "Waiting for the data store.")
    }

    @Test("Fleet rows carry the summary; listed features the summary lacks fall back")
    func fleetAndFallbackTogether() throws {
        let host = ChatFixtures.host(
            "alpha",
            features: [ChatFixtures.feature("covered", status: "blocked"), ChatFixtures.feature("new", status: "awaiting_direction")],
            entries: [ChatFixtures.entry("covered", hud: .ready, unread: false, step: 4),
                      ChatFixtures.entry("summary-only", hud: .working, step: 1)]
        )
        let byID = Dictionary(uniqueKeysWithValues: FirstMateConversationList.build(hosts: [host], readState: .init()).map { ($0.featureID, $0) })
        #expect(byID.count == 3)
        #expect(byID["covered"]?.hudStatus == .ready)
        #expect(byID["covered"]?.stepIndex == 4)
        #expect(byID["covered"]?.isUnread == false)
        #expect(byID["new"]?.hudStatus == .turn)
        #expect(byID["new"]?.isUnread == true)
        #expect(byID["summary-only"]?.machineName == "Alpha Mac")
    }

    @Test("Markdown becomes one plain line", arguments: [
        ("## Status\n\nAll **good** and _done_.", "Status All good and done."),
        ("> Quote with `code` and ~~old~~ text", "Quote with code and old text"),
        ("1. First\n2. Second\n- [x] Checked", "First Second Checked"),
        ("Ask [Device QA](herdr://first-mate?feature_id=f&assignment_id=a) and ![chart](x.png)", "Ask Device QA and chart"),
        ("```swift\nlet a = 1\n```\nAfter the code", "let a = 1 After the code"),
        ("| a | b |\n|---|---|\n| 1 | 2 |", "a b 1 2"),
        ("snake_case_name and 2*3*4 stay", "snake_case_name and 2*3*4 stay"),
        ("Escaped \\*stars\\* and <https://example.invalid>", "Escaped *stars* and https://example.invalid"),
        ("  lots\t of \n\n whitespace  ", "lots of whitespace"),
    ])
    func markdownStripping(markdown: String, expected: String) {
        #expect(FirstMateChatPreview.plainText(markdown) == expected)
    }

    @Test("Status words: a working feature shows its step, otherwise the status label")
    func statusWords() {
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .idle, step: 3, featureStatus: "paused")) == "Paused")
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .idle, featureStatus: "cancelled")) == "Cancelled")
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .working, step: 3, featureStatus: "recovering")) == "Recovering")
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .working, step: 3, featureStatus: "coordinating")) == "Responding")
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .working, step: 2)) == "In review")
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .working)) == "Working")
        #expect(FirstMateChatStatusStyle.word(for: ChatFixtures.conversation("a", hud: .blocked, step: 3)) == "Blocked")
        #expect(FirstMateHudStatus.allCases.filter { $0 != .unknown }.map(FirstMateChatStatusStyle.label(for:))
            == ["Blocked", "Your turn", "Ready for review", "Working", "Ready to plan", "Complete"])
        #expect(FirstMateChatStatusStyle.stepText(for: ChatFixtures.conversation("a", hud: .blocked, step: 3)) == "QA")
        #expect(FirstMateChatStatusStyle.stepText(for: ChatFixtures.conversation("a", hud: .blocked)) == nil)
        #expect(FirstMateChatStatusStyle.stepText(for: ChatFixtures.conversation("a", hud: .done)) == nil)
    }
}
