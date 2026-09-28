import Foundation

/// The chat window's demo, shared by the window, the Dock badge, and the Dock
/// menu so all three count the same conversations.
///
/// One store for the process: a send in the window's demo adds a synthetic
/// First Mate reply here, and the badge sees that reply (and the read that
/// follows it) instead of the demo's original newest message. The clock is
/// fixed for the process so the demo's times do not drift.
@MainActor
final class FirstMateChatDemoSource {
    let now: Date
    let fleet: [FirstMateFleetEntry]
    let store: FirstMateStore

    init(now: Date = Date()) {
        self.now = now
        fleet = FirstMateDemo.chatWindowFleet(now: now)
        store = FirstMateStore()
        store.configure(client: nil, demo: true, demoFeatures: FirstMateDemo.chatWindowFeatures(now: now))
    }

    /// The demo's one host, with each chat's newest message taken from the
    /// store so local sends show up.
    var host: FirstMateFleetHost {
        FirstMateChatWindowSession.demoHost(fleet: fleet, snapshots: store.snapshots, lastUpdated: now)
    }
}
