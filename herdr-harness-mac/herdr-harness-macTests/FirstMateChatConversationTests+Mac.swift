import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

extension FirstMateChatConversationTests {
    @Test("Letting go of the mic sends while listening and hints only after a quick tap")
    func micRelease() {
        #expect(FirstMateChatComposer.micRelease(isListening: true, isIdle: false, listenedThisPress: true) == .finish)
        #expect(FirstMateChatComposer.micRelease(isListening: false, isIdle: true, listenedThisPress: false) == .tapHint)
        // Held, then Esc cancelled before letting go.
        #expect(FirstMateChatComposer.micRelease(isListening: false, isIdle: true, listenedThisPress: true) == FirstMateChatComposer.MicRelease.none)
        // Still transcribing an earlier recording.
        #expect(FirstMateChatComposer.micRelease(isListening: false, isIdle: false, listenedThisPress: false) == FirstMateChatComposer.MicRelease.none)
    }
    @Test("Step bars fill through the current step's fraction; done fills all six")
    func readoutBars() {
        var conversation = ChatFixtures.conversation("Synthetic", hud: .blocked, step: 3)
        conversation = FirstMateConversation(
            id: conversation.id, machineID: conversation.machineID, machineName: conversation.machineName,
            featureID: conversation.featureID, title: conversation.title, label: conversation.label, emoji: conversation.emoji,
            hudStatus: .blocked, featureStatus: "blocked", stepIndex: 3, stepFraction: 0.45, now: nil, previewText: "",
            previewIsFromUser: false, isWorkingOnReply: false, activityAt: nil, latestFirstMateMessageID: nil,
            isUnread: true, isArchived: false
        )
        let progress = FirstMateCapsuleReadout.progress(for: conversation)
        let fills = (0..<6).map { FirstMateCapsuleReadout.fill(bar: $0, progress: progress) }
        #expect(zip(fills, [1, 1, 1, 0.45, 0, 0]).allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(FirstMateCapsuleReadout.progress(for: ChatFixtures.conversation("Done", hud: .done)) == 6)
        #expect(FirstMateCapsuleReadout.progress(for: ChatFixtures.conversation("Unknown", hud: .working)) == nil)
        #expect(FirstMateCapsuleReadout.fill(bar: 0, progress: nil) == 0)
    }
    @Test("Briefing words hug a pill when punctuation follows it")
    func briefingItems() {
        let receipts = ChatFixtures.conversation("Receipt export", hud: .blocked, step: 3)
        let items = FirstMateBriefingFlow.items(for: [.text("Hi. "), .mention(receipts), .text(", and more.")])
        let gaps: [CGFloat?] = items.map {
            switch $0 {
            case .word(_, let gap, _), .mention(_, let gap, _): gap
            }
        }
        #expect(items.count == 5)
        #expect(gaps == [nil, nil, 0, nil, nil])
    }
}
