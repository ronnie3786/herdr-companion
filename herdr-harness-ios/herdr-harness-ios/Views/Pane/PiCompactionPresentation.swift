import Foundation

/// Render-free description of the composer's compaction status area: either the
/// existing in-progress spinner or the confirmed "Context compacted" cue.
///
/// Kept free of SwiftUI so the reducer, composer configuration, and hosted
/// render tests can assert exact copy and symbol choices without instantiating
/// a view.
struct PiCompactionStatusPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case progress
        case completed
    }

    let kind: Kind
    let title: String
    let detail: String?
    let systemImage: String

    var accessibilityLabel: String {
        [title, detail].compactMap { $0 }.joined(separator: ". ")
    }

    var accessibilityIdentifier: String {
        switch kind {
        case .progress: "pi-chat-compacting"
        case .completed: "pi-chat-compacted"
        }
    }
}

/// The control state the completion cue uses for its readiness detail.
///
/// Draft and attachment validity stay with the composer: this only describes
/// whether Pi itself can accept a message, which prompt modes are currently
/// available, and whether the session is offline or still recovering. It never
/// claims readiness that the existing submission guard would refuse.
struct PiCompactionReadiness: Equatable, Sendable {
    let isConnected: Bool
    let phase: PiConversationPhase
    let availableDispositions: [PiPromptDisposition]

    var detail: String {
        guard isConnected else {
            return "Pi is offline. Reconnect before sending a message."
        }
        switch phase {
        case .working:
            return Self.workingDetail(for: availableDispositions)
        case .idle, .failed:
            return availableDispositions.contains(.prompt)
                ? "Ready for your next message."
                : "Sending isn't available in this session."
        }
    }

    private static func workingDetail(for dispositions: [PiPromptDisposition]) -> String {
        let steer = dispositions.contains(.steer)
        let followUp = dispositions.contains(.followUp)
        switch (steer, followUp) {
        case (true, true):
            return "Pi is still working. Steer this turn or queue a follow-up."
        case (true, false):
            return "Pi is still working. You can steer this turn."
        case (false, true):
            return "Pi is still working. You can queue a follow-up."
        case (false, false):
            return dispositions.contains(.prompt)
                ? "Pi is still working. You can send a message."
                : "Pi is still working. Sending isn't available in this session."
        }
    }
}

extension PiCompactionStatusPresentation {
    /// Progress always wins over completion. The reducer keeps them exclusive,
    /// but a stale progress record must never hide behind a success cue, and an
    /// acknowledged cue is already dismissed.
    static func resolve(
        activity: PiCompactionActivity?,
        completion: PiCompactionCompletion?,
        readiness: PiCompactionReadiness
    ) -> PiCompactionStatusPresentation? {
        if let activity {
            return PiCompactionStatusPresentation(
                kind: .progress,
                title: activity.statusMessage,
                detail: nil,
                systemImage: "arrow.triangle.2.circlepath"
            )
        }
        guard let completion, !completion.isAcknowledged else { return nil }
        return PiCompactionStatusPresentation(
            kind: .completed,
            title: completion.statusMessage,
            detail: readiness.detail,
            systemImage: "checkmark.circle.fill"
        )
    }
}
