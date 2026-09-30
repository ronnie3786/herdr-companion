import Foundation
import Observation

/// File-card matching follows content changes, independently of scrolling,
/// resizing, typing, or fleet updates. The first scan also stays off the UI
/// thread. A cancelled scan never publishes into another conversation.
@MainActor @Observable
final class FirstMateTranscriptFileCards {
    struct Input: Equatable, Sendable {
        let messages: [FirstMateMessage]
        let documents: [FirstMateDocument]
    }

    private(set) var cards: [String: [FirstMateDocument]] = [:]
    @ObservationIgnored private var acceptedInput: Input?
    @ObservationIgnored private var requestID = UUID()

    func update(_ input: Input) async {
        let request = UUID()
        requestID = request
        guard input != acceptedInput else { return }
        let scan = Task.detached(priority: .userInitiated) {
            FirstMateTranscriptLayout.fileCards(messages: input.messages, documents: input.documents,
                                                isCancelled: { Task.isCancelled })
        }
        let value = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        guard !Task.isCancelled, request == requestID else { return }
        acceptedInput = input
        if cards != value { cards = value }
    }
}
