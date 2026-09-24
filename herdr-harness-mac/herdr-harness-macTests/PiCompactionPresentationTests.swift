import Testing
@testable import herdr_harness_mac

@Suite("Pi compaction presentation")
struct PiCompactionPresentationTests {
    @Test("Progress keeps the existing reason-aware spinner copy")
    func progressPresentation() {
        let presentation = PiCompactionStatusPresentation.resolve(
            activity: PiCompactionActivity(reason: .overflow, willRetry: true),
            completion: nil,
            readiness: readiness(phase: .idle)
        )

        #expect(presentation?.kind == .progress)
        #expect(presentation?.title == "Compacting context after overflow, then retrying…")
        #expect(presentation?.detail == nil)
        #expect(presentation?.accessibilityIdentifier == "pi-chat-compacting")
        #expect(presentation?.accessibilityLabel == "Compacting context after overflow, then retrying…")
    }

    @Test("Confirmed completion shows a checkmark, title, and readiness detail")
    func completedPresentation() {
        let presentation = PiCompactionStatusPresentation.resolve(
            activity: nil,
            completion: completion(),
            readiness: readiness(phase: .idle)
        )

        #expect(presentation?.kind == .completed)
        #expect(presentation?.title == "Context compacted")
        #expect(presentation?.detail == "Ready for your next message.")
        #expect(presentation?.systemImage == "checkmark.circle.fill")
        #expect(presentation?.accessibilityIdentifier == "pi-chat-compacted")
        #expect(presentation?.accessibilityLabel == "Context compacted. Ready for your next message.")
    }

    @Test("An acknowledged completion is dismissed and does not replace progress")
    func acknowledgedAndProgressPrecedence() {
        #expect(PiCompactionStatusPresentation.resolve(
            activity: nil,
            completion: completion(isAcknowledged: true),
            readiness: readiness(phase: .idle)
        ) == nil)

        let progressWins = PiCompactionStatusPresentation.resolve(
            activity: PiCompactionActivity(reason: .manual, willRetry: false),
            completion: completion(),
            readiness: readiness(phase: .idle)
        )
        #expect(progressWins?.kind == .progress)
    }

    @Test("Readiness copy describes working prompt modes instead of claiming idle")
    func workingReadiness() {
        let steerAndFollowUp = PiCompactionReadiness(
            isConnected: true,
            phase: .working,
            availableDispositions: [.steer, .followUp]
        )
        #expect(steerAndFollowUp.detail == "Pi is still working. Steer this turn or queue a follow-up.")

        let steerOnly = PiCompactionReadiness(isConnected: true, phase: .working, availableDispositions: [.steer])
        #expect(steerOnly.detail == "Pi is still working. You can steer this turn.")

        let followUpOnly = PiCompactionReadiness(isConnected: true, phase: .working, availableDispositions: [.followUp])
        #expect(followUpOnly.detail == "Pi is still working. You can queue a follow-up.")

        let promptFallback = PiCompactionReadiness(isConnected: true, phase: .working, availableDispositions: [.prompt])
        #expect(promptFallback.detail == "Pi is still working. You can send a message.")

        let noneAvailable = PiCompactionReadiness(isConnected: true, phase: .working, availableDispositions: [])
        #expect(noneAvailable.detail == "Pi is still working. Sending isn't available in this session.")
    }

    @Test("Offline and unavailable sessions never claim readiness")
    func offlineReadiness() {
        let offline = PiCompactionReadiness(isConnected: false, phase: .idle, availableDispositions: [.prompt])
        #expect(offline.detail == "Pi is offline. Reconnect before sending a message.")

        let offlineWorking = PiCompactionReadiness(isConnected: false, phase: .working, availableDispositions: [.steer])
        #expect(offlineWorking.detail == "Pi is offline. Reconnect before sending a message.")
    }

    @Test("An idle session without prompt support does not claim readiness")
    func idleWithoutPromptSupport() {
        let unsupported = PiCompactionReadiness(isConnected: true, phase: .idle, availableDispositions: [])
        #expect(unsupported.detail == "Sending isn't available in this session.")
    }

    private func readiness(phase: PiConversationPhase) -> PiCompactionReadiness {
        PiCompactionReadiness(isConnected: true, phase: phase, availableDispositions: [.prompt])
    }

    private func completion(isAcknowledged: Bool = false) -> PiCompactionCompletion {
        PiCompactionCompletion(
            evidence: .entry("compact-1"),
            reason: .threshold,
            sessionID: "s1",
            timestamp: nil,
            isAcknowledged: isAcknowledged
        )
    }
}
