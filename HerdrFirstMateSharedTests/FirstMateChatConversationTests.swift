import Foundation
import SwiftUI
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

/// The chat window's conversation column: grouping, what your bubble shows,
/// file cards, suggested replies, the `@` trigger and picker, mention runs,
/// and the capsule readout's step bars. All data is synthetic.
@Suite("First Mate chat conversation")
@MainActor
struct FirstMateChatConversationTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = ISO8601DateFormatter().date(from: "2030-03-06T12:00:00Z")!

    static func message(
        _ id: String,
        role: String = "assistant",
        text: String = "Synthetic text",
        at time: String = "2030-03-06T10:00:00Z",
        status: String = "delivered",
        assignment: String? = nil,
        skim: FirstMateSkim? = nil
    ) -> FirstMateMessage {
        FirstMateMessage(id: id, featureID: "fmf_synthetic", role: role, text: text, status: status, createdAt: time,
                         visibility: "conversation", skim: skim, assignmentID: assignment)
    }

    // MARK: Grouping

    @Test("Groups mark their first and last bubbles; a new day breaks a group")
    func grouping() {
        let messages = [
            Self.message("a", role: "user", at: "2030-03-05T09:00:00Z"),
            Self.message("b", at: "2030-03-05T09:01:00Z"),
            Self.message("c", at: "2030-03-06T09:02:00Z"),
            Self.message("d", at: "2030-03-06T09:03:00Z"),
            Self.message("e", at: "2030-03-06T09:04:00Z", assignment: "as_1"),
            Self.message("f", role: "human", at: "2030-03-06T09:05:00Z"),
            Self.message("g", role: "user", at: "2030-03-06T09:06:00Z"),
        ]
        let rows = FirstMateTranscriptLayout.rows(for: messages, now: Self.now, calendar: Self.calendar)
        #expect(rows.map(\.isFirstInGroup) == [true, true, true, false, true, true, false])
        #expect(rows.map(\.isLastInGroup) == [true, true, false, true, true, false, true])
        #expect(rows.map(\.dayLabel) == ["Yesterday", nil, "Today", nil, nil, nil, nil])
        #expect(rows[4].speaker == .agent("as_1"))
        #expect(rows[5].speaker == .user)
    }

    @Test("The typing bubble takes the avatar and tail from First Mate's last bubble")
    func typingJoinsFirstMateGroup() {
        let firstMateLast = [Self.message("a", role: "user"), Self.message("b")]
        let typing = FirstMateTranscriptLayout.rows(for: firstMateLast, typing: true, now: Self.now, calendar: Self.calendar)
        #expect(typing.last?.isLastInGroup == false)
        #expect(!FirstMateTranscriptLayout.typingStartsGroup(typing))

        let userLast = [Self.message("a"), Self.message("b", role: "user")]
        let afterUser = FirstMateTranscriptLayout.rows(for: userLast, typing: true, now: Self.now, calendar: Self.calendar)
        #expect(afterUser.last?.isLastInGroup == true)
        #expect(FirstMateTranscriptLayout.typingStartsGroup(afterUser))
    }

    @Test("Typing shows for a send, a queued or processing message of yours, or a reported reply")
    func typingSignals() {
        let delivered = [Self.message("a", role: "user")]
        #expect(!FirstMateTranscriptLayout.isTyping(messages: delivered, isSending: false, isWorkingOnReply: false))
        #expect(FirstMateTranscriptLayout.isTyping(messages: delivered, isSending: true, isWorkingOnReply: false))
        #expect(FirstMateTranscriptLayout.isTyping(messages: delivered, isSending: false, isWorkingOnReply: true))
        #expect(FirstMateTranscriptLayout.isTyping(messages: [Self.message("a", role: "user", status: "queued")], isSending: false, isWorkingOnReply: false))
        #expect(FirstMateTranscriptLayout.isTyping(messages: [Self.message("a", role: "user", status: "processing")], isSending: false, isWorkingOnReply: false))
        #expect(!FirstMateTranscriptLayout.isTyping(messages: [Self.message("a", status: "queued")], isSending: false, isWorkingOnReply: false))
    }

    @Test("A partial reply stays after its optimistic user row and ends speculative typing")
    func partialReplyOrdering() throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let context = store.operationContext
        var snapshot = try #require(store.snapshot(for: context))
        let handle = try #require(store.beginOutgoingMessage("Synthetic direction", expectedContext: context))
        let reply = FirstMateMessage(id: "synthetic-new-reply", featureID: snapshot.feature.id,
                                     role: "assistant", text: "Working on it", status: "delivered",
                                     createdAt: "2030-03-06T12:01:00Z")
        snapshot.messages.append(reply)
        store.receive(snapshot)
        let ordered = FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: snapshot)
        let localIndex = try #require(ordered.firstIndex(where: { $0.id == handle.messageID }))
        let replyIndex = try #require(ordered.firstIndex(where: { $0.id == reply.id }))
        #expect(localIndex < replyIndex)
        #expect(!FirstMateTranscriptLayout.isAwaitingReply(store: store, snapshot: snapshot))
    }

    @Test("The chat window presents one checkpoint and retains its closing reply and crew identity")
    func canonicalCheckpointRows() throws {
        let snapshot = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-receipts" })
        let latest = snapshot.messages.last(where: \.isConversation)
        var checkpoint = try #require(latest)
        checkpoint.metadata = .init(turnID: "turn", visitID: "visit", checkpoint: true)
        var closing = Self.message("closing", text: "A second question")
        closing.featureID = checkpoint.featureID
        closing.metadata = .init(inReplyTo: "turn")
        let rows = FirstMateTranscriptLayout.rows(for: [checkpoint, closing],
            pendingDecisionMessageID: checkpoint.id, now: Self.now, calendar: Self.calendar)
        #expect(rows.map(\.id) == [checkpoint.id])
        #expect(rows[0].isPendingDecision)
        #expect(rows[0].additionalReplies == [closing])
        #expect(FirstMateTranscriptLayout.suggestedReplies(messages: [checkpoint, closing], needsYou: true, isTyping: false)
            == ["Ship iPhone-only", "Investigate iPad"])
        var crew = Self.message("crew", assignment: "assignment")
        crew.featureID = checkpoint.featureID
        crew.metadata?.inReplyTo = "turn"
        let withCrew = FirstMateTranscriptLayout.rows(for: [checkpoint, crew, closing], now: Self.now, calendar: Self.calendar)
        #expect(withCrew.map(\.id) == [checkpoint.id, "crew"])
        #expect(withCrew[1].speaker == .agent("assignment"))
        #expect(withCrew[0].additionalReplies == [closing])
    }

    // MARK: Your bubble

    @Test("The dictation note is stripped for display and marks the bubble as voice")
    func dictationSuffix() {
        let text = "Ship it\n\n" + FirstMateMessageDisplay.dictationSuffix
        let display = FirstMateMessageDisplay.parse(text)
        #expect(display == FirstMateMessageDisplay(body: "Ship it", attachments: [], isVoice: true))
        #expect(!FirstMateMessageDisplay.parse("Ship it (transcribed audio)").isVoice)
        #expect(FirstMateMessageDisplay.parse(FirstMateMessageDisplay.dictationSuffix + " later").isVoice == false)
    }

    @Test("Attachment lines become chips, in order, and leave the text")
    func attachmentLines() {
        let text = "Look at these\n\nAttachment: `/tmp/synthetic/one.png`\nAttachment: `/tmp/synthetic/two.log`\n\n" + FirstMateMessageDisplay.dictationSuffix
        let display = FirstMateMessageDisplay.parse(text)
        #expect(display.body == "Look at these")
        #expect(display.attachments == ["/tmp/synthetic/one.png", "/tmp/synthetic/two.log"])
        #expect(display.isVoice)
        #expect(FirstMateMessageDisplay.fileName(of: display.attachments[0]) == "one.png")
        #expect(FirstMateMessageDisplay.attachmentPath(in: "Attachment: `a`b`") == nil)
        #expect(FirstMateMessageDisplay.attachmentPath(in: "Attachment: ``") == nil)
        #expect(FirstMateMessageDisplay.attachmentPath(in: "See Attachment: `x`") == nil)
    }

    @Test("VoiceOver reads your bubble's text, files, queued state, and voice note")
    func userBubbleAccessibilityLabel() {
        let voice = FirstMateMessageDisplay.parse("Ship it\n\n" + FirstMateMessageDisplay.dictationSuffix)
        #expect(voice.accessibilityLabel(isQueued: false) == "You: Ship it, sent by voice")
        let filesOnly = FirstMateMessageDisplay.parse("Attachment: `/tmp/synthetic/one.png`\nAttachment: `/tmp/synthetic/two.log`")
        #expect(filesOnly.accessibilityLabel(isQueued: true) == "You: attached one.png, two.log, queued")
        #expect(FirstMateMessageDisplay.parse("Hello").accessibilityLabel(isQueued: false) == "You: Hello")
    }

    // MARK: File cards

    @Test("A document's card shows once, on the earliest reply naming it as whole words")
    func fileCards() {
        let document = FirstMateDocument(id: "doc_1", featureID: "fmf_synthetic", title: "QA failure log",
                                         mediaType: "text/markdown", contentHash: "h", createdAt: "2030-03-06T10:00:00Z")
        let other = FirstMateDocument(id: "doc_2", featureID: "fmf_synthetic", title: "Plan",
                                      mediaType: "text/markdown", contentHash: "h2", createdAt: "2030-03-06T10:00:00Z")
        let messages = [
            Self.message("a", role: "user", text: "Where is the QA failure log?"),
            Self.message("b", text: "The QA failure log is ready.", assignment: "as_1"),
            Self.message("c", text: "The QA failure log points at the anchor. Planning next."),
        ]
        let cards = FirstMateTranscriptLayout.fileCards(messages: messages, documents: [document, other])
        #expect(cards == ["b": [document]])
        #expect(FirstMateTranscriptLayout.containsWholeWords("Plan", in: "The Plan."))
        #expect(!FirstMateTranscriptLayout.containsWholeWords("Plan", in: "Planning"))
        #expect(FirstMateTranscriptLayout.containsWholeWords("PR #214 summary", in: "See the PR #214 summary."))
    }

    // MARK: Suggested replies

    @Test("Suggested replies come from the newest reply's skim, only when the chat needs you")
    func suggestedReplies() throws {
        let snapshot = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-receipts" })
        let messages = snapshot.messages.filter(\.isConversation)
        #expect(FirstMateTranscriptLayout.suggestedReplies(messages: messages, needsYou: true, isTyping: false)
            == ["Ship iPhone-only", "Investigate iPad"])
        #expect(FirstMateTranscriptLayout.suggestedReplies(messages: messages, needsYou: false, isTyping: false).isEmpty)
        #expect(FirstMateTranscriptLayout.suggestedReplies(messages: messages, needsYou: true, isTyping: true).isEmpty)
        let answered = messages + [Self.message("reply", role: "user", text: "Ship iPhone-only")]
        #expect(FirstMateTranscriptLayout.suggestedReplies(messages: answered, needsYou: true, isTyping: false).isEmpty)
        #expect(FirstMateTranscriptLayout.suggestedReplies(messages: [Self.message("plain")], needsYou: true, isTyping: false).isEmpty)
    }

    // MARK: The @ trigger and picker

    @Test("The trigger is a trailing @query of at most 24 characters")
    func trigger() {
        #expect(FirstMateMentionTrigger.match(in: "@") == .init(query: "", offset: 0))
        #expect(FirstMateMentionTrigger.match(in: "Ask @Rec") == .init(query: "Rec", offset: 4))
        #expect(FirstMateMentionTrigger.match(in: "(@Rec")?.query == "Rec")
        #expect(FirstMateMentionTrigger.match(in: "Ask @Receipt export")?.query == "Receipt export")
        #expect(FirstMateMentionTrigger.match(in: "mail@example") == nil)
        #expect(FirstMateMentionTrigger.match(in: "Ask @ Rec") == nil)
        #expect(FirstMateMentionTrigger.match(in: "Ask @Receipt  export") == nil)
        #expect(FirstMateMentionTrigger.match(in: "Ask @Rec\nmore") == nil)
        #expect(FirstMateMentionTrigger.match(in: "@" + String(repeating: "a", count: 24))?.query.count == 24)
        #expect(FirstMateMentionTrigger.match(in: "@" + String(repeating: "a", count: 25)) == nil)
        #expect(FirstMateMentionTrigger.match(in: "No trigger") == nil)
    }

    @Test("Picking replaces the trailing @query with the name and a space")
    func insertPick() {
        #expect(FirstMateMentionTrigger.insert("Receipt export", into: "Ask @Rec") == "Ask @Receipt export ")
        #expect(FirstMateMentionTrigger.insert("Receipt export", into: "@") == "@Receipt export ")
    }

    @Test("Options list at most five features, then the crew, filtered ignoring case")
    func options() {
        let features = (1...7).map { ChatFixtures.conversation("Feature \($0)", hud: .working, step: 1) }
        let crew = [
            FirstMateAssignment(id: "as_1", featureID: "Feature 1", visitID: "v", title: "Device QA", role: "Tester",
                                status: "blocked", attempt: 1, generation: 1, inputRevision: 1, updatedAt: "2030-03-06T10:00:00Z"),
            FirstMateAssignment(id: "as_2", featureID: "Feature 1", visitID: "v", title: "Export flow", role: "Builder",
                                status: "completed", attempt: 1, generation: 1, inputRevision: 1, updatedAt: "2030-03-06T10:00:00Z"),
        ]
        let all = FirstMateMentionOption.options(query: "", features: features, crew: crew)
        #expect(all.filter { $0.section == .features }.count == FirstMateMentionOption.featureLimit)
        #expect(all.filter { $0.section == .crew }.map(\.candidate.name) == ["Device QA", "Export flow"])
        #expect(all.first?.detail == "Building")
        #expect(all.last?.detail == "Builder")
        #expect(all.last?.status == .done)

        let filtered = FirstMateMentionOption.options(query: "qa", features: features, crew: crew)
        #expect(filtered.map(\.candidate.name) == ["Device QA"])
        #expect(filtered.first?.candidate.target == .agent(featureID: "Feature 1", assignmentID: "as_1"))
        #expect(FirstMateMentionOption.options(query: "feature 7", features: features, crew: crew).map(\.candidate.name) == ["Feature 7"])

        #expect(FirstMateMentionOption.move(0, by: -1, count: 3) == 2)
        #expect(FirstMateMentionOption.move(2, by: 1, count: 3) == 0)
        #expect(FirstMateMentionOption.move(0, by: 1, count: 0) == 0)
    }

    @Test("Picked tags serialize to mention links at send")
    func serializePicks() {
        let pick = FirstMateMentionCandidate(name: "Receipt export", target: .feature(featureID: "fmf_1"))
        let draft = FirstMateMentionTrigger.insert("Receipt export", into: "Check @Rec") + "please"
        #expect(FirstMateMention.serializeComposer(draft, picks: [pick])
            == "Check [Receipt export](herdr://first-mate?feature_id=fmf_1) please")
    }

    static func conversation(_ title: String, machineID: String, unread: Bool = false, latest: String? = nil) -> FirstMateConversation {
        let base = ChatFixtures.conversation(title, hud: .blocked, step: 3, unread: unread)
        return FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: machineID, featureID: base.featureID), machineID: machineID,
            machineName: machineID, featureID: base.featureID, title: base.title, label: base.label, emoji: base.emoji,
            hudStatus: base.hudStatus, featureStatus: base.featureStatus, stepIndex: base.stepIndex, stepFraction: nil,
            now: nil, previewText: "", previewIsFromUser: false, isWorkingOnReply: false, activityAt: nil,
            latestFirstMateMessageID: latest, isUnread: unread, isArchived: false
        )
    }

    @Test("Only the chat's own machine's features can be tagged")
    func taggableFeatures() {
        let features = [
            Self.conversation("Receipt export", machineID: "mac-a"),
            Self.conversation("Offline sync", machineID: "mac-b"),
            Self.conversation("Search polish", machineID: "mac-a"),
        ]
        #expect(FirstMateMentionOption.taggableFeatures(features, machineID: "mac-a").map(\.title) == ["Receipt export", "Search polish"])
        #expect(FirstMateMentionOption.taggableFeatures(features, machineID: "mac-c").isEmpty)
        #expect(FirstMateMentionOption.taggableFeatures(features, machineID: nil).isEmpty)
    }

    @Test("A restored draft's tags are recovered at send; recorded picks keep their names")
    func picksForSend() {
        let features = [
            Self.conversation("Receipt export", machineID: "local"),
            Self.conversation("Offline sync", machineID: "local"),
        ]
        let crew = [
            FirstMateAssignment(id: "as_1", featureID: "Receipt export", visitID: "v", title: "Device QA", role: "Tester",
                                status: "blocked", attempt: 1, generation: 1, inputRevision: 1, updatedAt: "2030-03-06T10:00:00Z"),
        ]
        let draft = "Ask @Device QA about @Receipt export please"
        let restored = FirstMateMentionOption.picksForSend([], draft: draft, features: features, crew: crew)
        #expect(Set(restored.map(\.name)) == ["Receipt export", "Device QA"])
        #expect(FirstMateMention.serializeComposer(draft, picks: restored)
            == "Ask [Device QA](herdr://first-mate?feature_id=Receipt%20export&assignment_id=as_1) about [Receipt export](herdr://first-mate?feature_id=Receipt%20export) please")

        let recorded = FirstMateMentionCandidate(name: "Receipt export", target: .feature(featureID: "fmf_recorded"))
        let kept = FirstMateMentionOption.picksForSend([recorded], draft: draft, features: features, crew: crew)
        #expect(kept.first == recorded)
        #expect(kept.filter { $0.name == "Receipt export" }.count == 1)
        #expect(FirstMateMentionOption.picksForSend([], draft: "Receipt export without a tag", features: features, crew: crew).isEmpty)
    }

    @Test("Read marking re-runs when the fleet flips the chat to unread or reports a newer reply")
    func readKey() {
        let read = Self.conversation("Receipt export", machineID: "local", unread: false, latest: "m1")
        let unread = Self.conversation("Receipt export", machineID: "local", unread: true, latest: "m1")
        let newer = Self.conversation("Receipt export", machineID: "local", unread: true, latest: "m2")
        func key(_ conversation: FirstMateConversation?) -> FirstMateTranscriptLayout.ReadKey {
            .init(followsLatest: true, isKey: true, newest: "m2", conversation: conversation)
        }
        #expect(key(read) != key(unread))
        #expect(key(unread) != key(newer))
        #expect(key(read) == key(read))
        #expect(key(nil) != key(read))
    }


    // MARK: Mention runs

    static var catalog: FirstMateMentionCatalog {
        FirstMateMentionCatalog(entries: [
            .init(name: "Receipt export", emoji: "🧾", status: .blocked, target: .feature(featureID: "fmf_1")),
            .init(name: "Device QA", emoji: "🧪", status: .blocked, target: .agent(featureID: "fmf_1", assignmentID: "as_1")),
        ])
    }

    @Test("Mention links and plain names become tinted runs; code and other links stay as they are")
    func mentionRuns() throws {
        let source = PiMarkdownText.render(
            "[Receipt export](herdr://first-mate?feature_id=fmf_1) needs Device QA, not `Device QA` or [Device QA](https://example.invalid)."
        )
        let spans = FirstMateMentionLinker.spans(in: source, catalog: Self.catalog)
        #expect(spans.map(\.entry.name) == ["Receipt export", "Device QA"])

        let linked = FirstMateMentionLinker.link(source, catalog: Self.catalog)
        let text = String(linked.characters)
        #expect(text.contains("🧾\u{00A0}Receipt export"))
        #expect(text.contains("\u{2009}🧪\u{00A0}Device QA\u{2009},"))
        let links = linked.runs.compactMap(\.link)
        #expect(links.contains(FirstMateMention.url(for: .agent(featureID: "fmf_1", assignmentID: "as_1"))))
        #expect(links.contains(URL(string: "https://example.invalid")!))
        let tinted = linked.runs.filter { $0.link.flatMap(FirstMateMention.parse) != nil }
        #expect(tinted.count == 2)
        #expect(tinted.allSatisfy { $0.backgroundColor != nil })
    }

    @Test("Your bubbles tag only what you picked; unknown mention targets still link")
    func mentionRunsWithoutPlainNames() {
        let source = PiMarkdownText.render("Can Device QA check [Other](herdr://first-mate?feature_id=fmf_9)?")
        let spans = FirstMateMentionLinker.spans(in: source, catalog: Self.catalog.withoutPlainNames)
        #expect(spans.map(\.entry.name) == ["Other"])
        #expect(spans.first?.entry.status == .unknown)
    }

    @Test("Text without mentions is returned unchanged")
    func mentionRunsNoop() {
        let source = PiMarkdownText.render("Nothing to tag **here**.")
        #expect(FirstMateMentionLinker.link(source, catalog: Self.catalog) == source)
    }

    @Test("The catalog lists features by title and label, and the open feature's crew")
    func catalogEntries() throws {
        let snapshot = try #require(FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-release" })
        let conversations = FirstMateConversationList.build(
            hosts: [FirstMateChatDemoProjection.host(fleet: FirstMateDemo.chatWindowFleet(), snapshots: [:], lastUpdated: .now, machineID: "demo", machineName: "This Mac")],
            readState: FirstMateReadState()
        )
        let catalog = FirstMateMentionCatalog(conversations: conversations, snapshot: snapshot)
        let names = catalog.entries.map(\.name)
        #expect(names.contains("Release checklist refresh"))
        #expect(names.contains("Release checklist"))
        #expect(names.contains("Usability pass"))
        #expect(catalog.entry(for: .agent(featureID: "demo-release", assignmentID: "demo-release-crew-2"))?.status == .turn)
    }

    // MARK: Readout


}
