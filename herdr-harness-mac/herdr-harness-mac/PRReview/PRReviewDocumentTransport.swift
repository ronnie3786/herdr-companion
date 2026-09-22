import Foundation
import Observation

/// An independent, host-pinned transport for one document window.
///
/// A document window outlives the presentation store it was opened from: the
/// main window can switch review hosts, and a pop-out session invalidates its
/// store when it closes. `PRReviewStore.documentTransport(for:)` captures the
/// configured machine, the review that owns the document, the client at open
/// time, and the shared document resources, so a later Try Again downloads
/// from that host instead of whichever host the originating presentation
/// store now points at, while download state still reaches the rail that
/// offered the document.
struct PRReviewDocumentTransport {
    let machineID: String
    let reviewID: String
    let isDemo: Bool
    let client: (any PRReviewClient)?
    let resources: PRReviewDocumentResources

    /// The immutable machine/review pair this window is pinned to. Titles,
    /// display labels, and pull request numbers are presentation, not identity.
    var target: PRReviewWindowTarget {
        PRReviewWindowTarget(machineID: machineID, reviewID: reviewID)
    }

    /// Builds the store the window's views own. It starts on the captured host
    /// and is replaced only through `PRReviewDocumentWindowSession`, which
    /// observes later configuration for the same machine.
    @MainActor
    func makeStore() -> PRReviewStore {
        let store = PRReviewStore(documentResources: resources)
        store.configure(client: client, machineID: machineID, demo: isDemo)
        store.select(reviewID)
        return store
    }
}

/// Owns the pinned-host lifecycle of one retained document window.
///
/// A document window outlives the presentation store that opened it, so it
/// cannot inherit that store's reconnect lifecycle. `PRReviewDocumentWindowRoot`
/// feeds this session each configuration probe it observes from the app model:
/// a credential or URL edit for the pinned machine swaps in a new client,
/// removing the machine invalidates the transport and shows an unavailable
/// state, and re-adding the machine configures it again. None of that depends
/// on the originating review window remaining open.
@MainActor
@Observable
final class PRReviewDocumentWindowSession {
    let document: PRReviewDocument
    let store: PRReviewStore
    /// The pinned machine. `invalidateConnection` deliberately keeps it, so a
    /// re-added host is resolved by the same identity and never by whichever
    /// machine is currently the main review host.
    let machineID: String?

    private(set) var hostState: PRReviewWindowHostState = .checking

    /// Increments once per accepted activation. Credentials are not part of
    /// this value; it exists so the window rebuilds its content and retries a
    /// document that the previous transport could not fetch.
    private(set) var revision = 0

    @ObservationIgnored private var activationIdentity: String?

    init(document: PRReviewDocument, store: PRReviewStore) {
        self.document = document
        self.store = store
        self.machineID = store.currentMachineID
    }

    /// Activates the window for one host identity. Re-activations for the same
    /// identity never reseed or rebuild; a different identity reconnects the
    /// pinned store, and an unavailable host drops the authenticated transport.
    func activate(
        identity: String,
        hostState: PRReviewWindowHostState,
        client: (any PRReviewClient)?
    ) async {
        guard activationIdentity != identity else { return }
        activationIdentity = identity
        self.hostState = hostState
        revision &+= 1

        guard hostState.isUsable else {
            store.invalidateConnection()
            return
        }
        store.reconnect(client: client, machineID: machineID, demo: hostState == .demo)
    }

    /// Closing the window releases its transport and every cache protection it
    /// still holds. The downloaded file itself is untouched.
    func stop() {
        activationIdentity = nil
        store.invalidateConnection()
    }
}
