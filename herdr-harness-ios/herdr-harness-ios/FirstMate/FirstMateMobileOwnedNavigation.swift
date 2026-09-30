import Foundation

/// UI boundary for links in a retained chat. Preserve the captured owner and
/// publish errors only while this exact navigation intent still owns the result.
@MainActor
enum FirstMateMobileOwnedNavigation {
    @discardableResult
    static func open(_ url: URL, owner: FirstMateFeatureTarget, store: FirstMateStore,
                     model: HerdrAppModel) -> Task<Void, Never>? {
        let fleet = model.firstMateFleet
        guard fleet.store(for: owner) === store, fleet.selectedTarget == owner,
              store.selectedFeatureID == owner.featureID else { return nil }
        let context = store.operationContext
        let intent = fleet.chat.beginRouting()
        model.toastMessage = nil
        guard let request = FirstMateMobileOpenRequest(url: url) else {
            fleet.chat.finishRouting(intent)
            model.toastMessage = "This First Mate link is invalid."
            return nil
        }
        return Task {
            defer { fleet.chat.finishRouting(intent) }
            guard !Task.isCancelled, fleet.store(for: owner) === store, store.lifecycle == context.lifecycleIdentity,
                  fleet.chat.isCurrentNavigation(intent) else { return }
            let opened = await fleet.chat.navigate(request, owner: owner, intent: intent, fleet: fleet,
                                                   canControl: { model.firstMateCanControl(machineID: $0) })
            guard !Task.isCancelled, fleet.chat.isCurrentNavigation(intent), fleet.store(for: owner) === store,
                  store.lifecycle == context.lifecycleIdentity else { return }
            if !opened { model.toastMessage = fleet.chat.routingError ?? "The feature could not be opened on its owning machine." }
        }
    }
}
