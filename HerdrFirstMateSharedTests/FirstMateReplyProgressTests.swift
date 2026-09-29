import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate reply progress")
@MainActor
struct FirstMateReplyProgressTests {
    private func outgoing(
        state: FirstMateOutgoingMessage.State = .acceptedAwaitingSnapshot(messageID: nil),
        baseline: Set<String> = []
    ) -> FirstMateOutgoingMessage {
        FirstMateOutgoingMessage(
            id: "local-outgoing-test", featureID: "demo-session-continuity", requestID: "request-test",
            text: "Continue with the plan", createdAt: FirstMateDemo.timestamp,
            baselineMessageIDs: baseline, leadContext: nil, submission: nil,
            state: state, acceptedStatus: nil
        )
    }

    private func snapshot(echoID: String = "new-echo", role: String = "user", status: String = "queued",
                          visibility: String? = nil) -> FirstMateSnapshot {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.messages.append(FirstMateMessage(
            id: echoID, featureID: snapshot.feature.id, role: role, text: "Continue with the plan",
            status: status, createdAt: FirstMateDemo.timestamp, visibility: visibility
        ))
        return snapshot
    }

    private func pending(
        _ outgoing: [FirstMateOutgoingMessage], snapshot: FirstMateSnapshot?,
        hostUpdatedAt: String? = nil, fleetLatest: String? = nil
    ) -> Bool {
        FirstMateReplyProgress.isLocalReplyPending(
            outgoing: outgoing, snapshot: snapshot,
            hostFeatureUpdatedAt: hostUpdatedAt, fleetLatestFirstMateMessageID: fleetLatest
        )
    }

    @Test("All live statuses project to working without losing the underlying row data")
    func projectedRows() {
        for status: FirstMateHudStatus in [.blocked, .turn, .ready, .idle, .unknown, .working] {
            let original = ChatFixtures.conversation("Receipt export", hud: status, unread: true)
            let projected = FirstMateReplyProgress.presenting(original, workingOnReply: true)
            #expect(projected.hudStatus == .working)
            #expect(projected.isWorkingOnReply)
            #expect(!projected.showsDot)
            var restored = projected
            restored.hudStatus = original.hudStatus
            restored.isWorkingOnReply = original.isWorkingOnReply
            #expect(restored == original)
        }
    }

    @Test("Done and no-progress rows remain unchanged")
    func unchangedRows() {
        let done = ChatFixtures.conversation("Done", hud: .done, unread: true)
        #expect(FirstMateReplyProgress.presenting(done, workingOnReply: true) == done)
        let blocked = ChatFixtures.conversation("Receipt export", hud: .blocked, unread: true)
        #expect(FirstMateReplyProgress.presenting(blocked, workingOnReply: false) == blocked)
        #expect(blocked.showsDot)
    }

    #if os(macOS)
    @Test("Projected row uses the working word or its step's doing word, never the old badge")
    func workingWords() {
        let blocked = FirstMateReplyProgress.presenting(
            ChatFixtures.conversation("Receipt export", hud: .blocked, unread: true), workingOnReply: true
        )
        #expect(FirstMateChatStatusStyle.word(for: blocked) == "Working")
        #expect(FirstMateConversationRow.accessibilityLabel(for: blocked) == "Receipt export, Working")

        let inReview = FirstMateReplyProgress.presenting(
            ChatFixtures.conversation("Receipt export", hud: .turn, step: 2, unread: true), workingOnReply: true
        )
        #expect(inReview.stepIndex == 2)
        #expect(FirstMateChatStatusStyle.word(for: inReview) == "In review")
    }

    #endif

    @Test("An unresolved send projects immediately, even without a snapshot")
    func unresolvedSend() {
        #expect(pending([outgoing(state: .pending)], snapshot: nil))
        #expect(!pending([outgoing()], snapshot: nil))
    }

    @Test("Unobserved receipts and post-baseline queued or processing conversation user echoes bridge the send")
    func echoedSend() {
        let baseline: Set<String> = ["demo-user-0", "demo-mate-0"]
        let entry = outgoing(baseline: baseline)
        #expect(pending([entry], snapshot: snapshot()))
        #expect(pending([entry], snapshot: snapshot(role: "human", status: "processing")))
        #expect(pending([outgoing(state: .pending, baseline: baseline)], snapshot: snapshot(status: "processing")))
        #expect(pending([entry], snapshot: snapshot(echoID: "demo-user-0")), "The receipt has not appeared beyond the baseline")
        #expect(!pending([entry], snapshot: snapshot(status: "done")))
        #expect(!pending([entry], snapshot: snapshot(role: "assistant")))
        #expect(pending([entry], snapshot: snapshot(visibility: "background")),
                "A background-only message does not confirm the user echo arrived")
    }

    @Test("A receipt without an observed echo bridges only until the fleet moves past its baseline")
    func receiptWithoutSnapshotMessages() {
        let cached = FirstMateDemo.features(step: 0)[0]
        let entry = outgoing(state: .acceptedAwaitingSnapshot(messageID: "user-receipt"),
                             baseline: ["demo-user-0", "demo-mate-0", "old-first-mate"])
        #expect(pending([entry], snapshot: cached, hostUpdatedAt: cached.feature.updatedAt,
                        fleetLatest: "old-first-mate"))
        #expect(!pending([entry], snapshot: cached, hostUpdatedAt: "2030-01-01T00:00:00Z",
                         fleetLatest: "old-first-mate"))
        #expect(!pending([entry], snapshot: cached, hostUpdatedAt: cached.feature.updatedAt,
                         fleetLatest: "new-first-mate"))
    }

    @Test("Fractional and whole-second timestamps compare chronologically, not lexically")
    func mixedTimestampFormats() {
        var cached = snapshot()
        cached.feature.updatedAt = "2030-01-01T10:00:00.500Z"
        let entry = outgoing(baseline: ["demo-user-0", "demo-mate-0", "old-first-mate"])
        #expect(pending([entry], snapshot: cached, hostUpdatedAt: "2030-01-01T10:00:00Z"))
        cached.feature.updatedAt = "2030-01-01T10:00:00Z"
        #expect(!pending([entry], snapshot: cached, hostUpdatedAt: "2030-01-01T10:00:00.500Z"))
    }

    @Test("A rejected or unconfirmed submission cannot bridge a queued echo")
    func failedSend() {
        let echo = snapshot()
        #expect(!pending([outgoing(state: .failed(message: "Rejected"))], snapshot: echo))
        #expect(!pending([outgoing(state: .deliveryUnconfirmed(message: "Unknown delivery"))], snapshot: echo))
    }

    @Test("New fleet activity retires the local bridge; baseline fleet activity does not")
    func staleBridge() {
        let echo = snapshot()
        let entry = outgoing(baseline: ["demo-user-0", "demo-mate-0", "old-first-mate"])
        #expect(pending([entry], snapshot: echo, hostUpdatedAt: echo.feature.updatedAt))
        #expect(!pending([entry], snapshot: echo, hostUpdatedAt: "2030-01-01T00:00:00Z"))
        #expect(!pending([entry], snapshot: echo, fleetLatest: "new-first-mate"))
        #expect(pending([entry], snapshot: echo, fleetLatest: "old-first-mate"))
    }
}
