import Observation
import SwiftUI

/// Skim state that outlives a message row: which replies the reader switched
/// to Full reply, which blocks "Show in reply" highlights, and the scroll the
/// chat's `ScrollViewReader` performs. The chat view owns one, so a choice
/// lasts as long as that chat stays open. Every reply starts as its skim.
@MainActor
@Observable
final class SkimReadingState {
    private(set) var fullReplyIDs: Set<String> = []
    private(set) var highlightedRefs: [String: Set<String>] = [:]
    private(set) var scrollRequest: SkimScrollRequest?

    func showsFullReply(_ messageID: String) -> Bool {
        fullReplyIDs.contains(messageID)
    }

    func highlights(for messageID: String) -> Set<String> {
        highlightedRefs[messageID] ?? []
    }

    /// The footer toggle. Switching either way drops a "Show in reply" highlight.
    func toggleFullReply(_ messageID: String) {
        if fullReplyIDs.remove(messageID) == nil {
            fullReplyIDs.insert(messageID)
        }
        highlightedRefs[messageID] = nil
    }

    /// Opens the full reply with `refs` highlighted and asks the chat to
    /// scroll to the first of them in reading order.
    func showInReply(messageID: String, refs: [String], reader: FirstMateSkimReader) {
        let ordered = refs.compactMap(reader.segment).sorted { $0.n < $1.n }
        guard let first = ordered.first else { return }
        fullReplyIDs.insert(messageID)
        highlightedRefs[messageID] = Set(ordered.map(\.id))
        scrollRequest = SkimScrollRequest(
            targetID: SkimScrollID.segment(messageID: messageID, segmentID: first.id),
            serial: (scrollRequest?.serial ?? 0) + 1
        )
    }
}

/// One "Show in reply" scroll. The serial makes a repeat of the same target
/// a new change for `onChange`.
struct SkimScrollRequest: Equatable, Sendable {
    let targetID: String
    let serial: Int
}

enum SkimScrollID {
    static func segment(messageID: String, segmentID: String) -> String {
        "skim-\(messageID)-\(segmentID)"
    }
}

extension ScrollViewProxy {
    /// Scrolls a "Show in reply" target to the top once the full reply has
    /// laid out, then once more after lazy rows settle. No animation: skims
    /// never move on their own.
    @MainActor
    func revealSkimTarget(_ request: SkimScrollRequest) {
        let proxy = self
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(request.targetID, anchor: .top)
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(request.targetID, anchor: .top)
        }
    }
}
