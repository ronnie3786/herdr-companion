import Foundation

/// A popover is a retained view, not navigation authority.
@MainActor
struct FirstMateMobileReadoutRequest: Identifiable {
    let id = UUID()
    let conversation: FirstMateConversation
    let store: FirstMateStore
    let context: FirstMateStore.OperationContext
    let intent: UUID
    var target: FirstMateFeatureTarget { FirstMateMobileListPresentation.target(conversation) }

    static func capture(_ conversation: FirstMateConversation, fleet: FirstMateMobileFleetStore) -> Self? {
        let target = FirstMateMobileListPresentation.target(conversation)
        guard let store = fleet.store(for: target) else { return nil }
        let intent = fleet.chat.beginNavigation()
        return .init(conversation: conversation, store: store, context: store.operationContext, intent: intent)
    }
    func isCurrent(in fleet: FirstMateMobileFleetStore) -> Bool {
        fleet.chat.isCurrentNavigation(intent) && fleet.store(for: target) === store && store.lifecycle == context.lifecycleIdentity
    }
}
