import Foundation

/// An independent, host-pinned transport for one document window.
///
/// A document window outlives the presentation store it was opened from: the
/// main window can switch review hosts, and a pop-out session invalidates its
/// store when it closes. `PRReviewStore.documentTransport(for:)` captures the
/// configured machine, the review that owns the document, and the client at
/// open time, so a later Try Again downloads from that host instead of
/// whichever host the originating presentation store now points at.
struct PRReviewDocumentTransport {
    let machineID: String
    let reviewID: String
    let isDemo: Bool
    let client: (any PRReviewClient)?
    let documentCache: PRReviewDocumentCache

    /// The immutable machine/review pair this window is pinned to. Titles,
    /// display labels, and pull request numbers are presentation, not identity.
    var target: PRReviewWindowTarget {
        PRReviewWindowTarget(machineID: machineID, reviewID: reviewID)
    }

    /// Builds the store the window's views own. It is configured exactly once
    /// for the captured host and is never reconnected to another machine.
    @MainActor
    func makeStore() -> PRReviewStore {
        let store = PRReviewStore(documentCache: documentCache)
        store.configure(client: client, machineID: machineID, demo: isDemo)
        store.select(reviewID)
        return store
    }
}
