import Foundation

struct HomeReviewPreparation: Equatable, Identifiable {
    var id = UUID()
    let pullRequest: HomePullRequestIdentity
    let generation: Int
    let isDemo: Bool
}

/// In-memory identity captured when the person chooses a host. Never log or
/// persist this value; the configuration can contain a credential.
struct HomeReviewPreparationSelection: Equatable {
    let request: HomeReviewPreparation
    let machineID: String
    let configuration: ServerConfiguration?
}

@MainActor
enum HomeRouting {
    enum Outcome: Equatable {
        case opened, choosingReviewHost, unavailable(String)
    }

    @discardableResult
    static func open(_ route: HomeRoute, model: HerdrAppModel, shell: HerdrShellState,
                     openWindow: (String) -> Void, openSettings: () -> Void) -> Outcome {
        switch route {
        case .firstMate(let machineID, let featureID):
            shell.firstMateChatOpenRequest = nil
            shell.firstMateChatExactOpenRequest = .init(
                target: .init(machineID: machineID, featureID: featureID), model: model)
            openWindow(HerdrWindowID.firstMateChat)
        case .firstMateLead:
            shell.firstMateChatOpenRequest = nil
            shell.firstMateChatExactOpenRequest = nil
            shell.firstMateChatOpenLeadRequest &+= 1
            openWindow(HerdrWindowID.firstMateChat)
        case .review(let machineID, let reviewID):
            let request = HomeRevealRequest(target: .review(machineID: machineID, reviewID: reviewID),
                                            ownerName: name(machineID, model: model))
            shell.homeReviewRevealRequest = request
            let configuration = model.prReviewConfiguration(pinnedMachineID: machineID)
            let isDemo = model.isDemoMode && machineID == "demo"
            // Configure before selecting, so another host's same review ID
            // cannot remain visible while this exact detail loads.
            shell.configurePRReviewIfNeeded(configuration: configuration, machineID: machineID,
                                              connectionGeneration: model.connectionGeneration, isDemo: isDemo)
            shell.prReview.select(reviewID)
            shell.showPRReview(machineID: machineID, reviewID: reviewID, model: model)
            if !isDemo && configuration == nil { return unavailable(request.missingMessage, model: model) }
        case .reviewRequest(let url):
            guard let identity = canonicalReviewRequest(url, requests: shell.workInbox.response.reviewRequests.items) else {
                return unavailable("This review request is no longer available with a verified pull request link. Refresh Home and open the current request.", model: model)
            }
            let request = HomeReviewPreparation(pullRequest: identity, generation: model.connectionGeneration,
                                                isDemo: model.isDemoMode)
            shell.show(.prReview, model: model)
            if let machineID = defaultReviewMachine(model: model) {
                guard let selection = reviewSelection(request, machineID: machineID, model: model) else {
                    return unavailable("The configured review machine is unavailable. Choose a review host in Machines, then try again.", model: model)
                }
                return presentReviewPreparation(selection, model: model, shell: shell)
            }
            shell.homeReviewPreparationSelection = nil
            shell.homeReviewPreparation = request
            return .choosingReviewHost
        case .watcher(let machineID, let watcherID):
            shell.homeWatcherRevealRequest = .init(target: .watcher(machineID: machineID, watcherID: watcherID),
                                                    ownerName: name(machineID, model: model))
            shell.show(.watchers, model: model)
        case .chat(let paneID):
            guard let scope = MachineScopedID.split(paneID), model.pane(id: paneID) != nil else {
                let owner = MachineScopedID.split(paneID).map { name($0.machineID, model: model) + " (" + $0.machineID + ")" }
                    ?? "the requested machine"
                return unavailable("Chat \(paneID) is unavailable on \(owner). Refresh that companion to check whether the chat is still open.", model: model)
            }
            guard model.pane(id: paneID)?.machineID == scope.machineID else {
                return unavailable("That chat no longer belongs to its requested machine. Refresh Home before opening it.", model: model)
            }
            shell.openPane(id: paneID, model: model)
        case .machine(let machineID):
            shell.homeMachineRevealRequest = .init(target: .machine(machineID: machineID), ownerName: name(machineID, model: model))
            openSettings()
        case .watchers: shell.show(.watchers, model: model)
        case .reviews: shell.show(.prReview, model: model)
        case .chats: shell.show(.session, model: model)
        }
        return .opened
    }

    /// Revalidate provider metadata as well as the URL. A URL-shaped string
    /// or a colliding repository/number on a different enterprise host is not
    /// enough to prepare a review.
    static func canonicalReviewRequest(_ url: String, requests: [GitHubReviewRequest]) -> HomePullRequestIdentity? {
        for request in requests where request.state.lowercased() == "open" && !request.isDraft {
            guard let source = HomePullRequestIdentity(url: request.url, repository: request.repository, number: request.number),
                  let requested = HomePullRequestIdentity(url: url, repository: request.repository, number: request.number),
                  source == requested else { continue }
            return source
        }
        return nil
    }

    static func defaultReviewMachine(model: HerdrAppModel) -> String? {
        model.isDemoMode ? "demo" : model.prReviewMachine?.id
    }

    static func availableReviewMachines(model: HerdrAppModel) -> [HerdrMachine] {
        model.machines.filter { model.prReviewConfiguration(pinnedMachineID: $0.id) != nil }
    }

    /// Called by the host chooser. The first sheet dismisses before the
    /// existing review preparation sheet is presented from onDismiss.
    @discardableResult
    static func chooseReviewHost(_ machineID: String, request: HomeReviewPreparation,
                                 model: HerdrAppModel, shell: HerdrShellState) -> Bool {
        guard shell.homeReviewPreparation?.id == request.id,
              let selection = reviewSelection(request, machineID: machineID, model: model) else {
            model.toastMessage = "That review host changed or is no longer available. Choose an available machine."
            return false
        }
        shell.homeReviewPreparationSelection = selection
        shell.homeReviewPreparation = nil
        return true
    }

    @discardableResult
    static func finishReviewPreparation(model: HerdrAppModel, shell: HerdrShellState) -> Outcome? {
        guard let selection = shell.homeReviewPreparationSelection else { return nil }
        shell.homeReviewPreparationSelection = nil
        return presentReviewPreparation(selection, model: model, shell: shell)
    }

    private static func reviewSelection(_ request: HomeReviewPreparation, machineID: String,
                                        model: HerdrAppModel) -> HomeReviewPreparationSelection? {
        guard request.generation == model.connectionGeneration, request.isDemo == model.isDemoMode else { return nil }
        if request.isDemo {
            guard machineID == "demo" else { return nil }
            return .init(request: request, machineID: machineID, configuration: nil)
        }
        guard model.machines.contains(where: { $0.id == machineID }),
              let configuration = model.prReviewConfiguration(pinnedMachineID: machineID) else { return nil }
        return .init(request: request, machineID: machineID, configuration: configuration)
    }

    private static func presentReviewPreparation(_ selection: HomeReviewPreparationSelection,
                                                 model: HerdrAppModel, shell: HerdrShellState) -> Outcome {
        guard reviewSelection(selection.request, machineID: selection.machineID, model: model) == selection else {
            return unavailable("The chosen review machine or connection changed. Open the request again to choose its host.", model: model)
        }
        guard canonicalReviewRequest(selection.request.pullRequest.url,
                                     requests: shell.workInbox.response.reviewRequests.items) == selection.request.pullRequest else {
            return unavailable("This review request changed while choosing a host. Refresh Home before preparing it.", model: model)
        }
        shell.show(.prReview, model: model)
        shell.prReviewOpenRequest = nil
        shell.selectPRReviewScope(.machine(selection.machineID))
        shell.configurePRReviewIfNeeded(configuration: selection.configuration, machineID: selection.machineID,
                                          connectionGeneration: selection.request.generation, isDemo: selection.request.isDemo)
        // Configuration may reset presentation state. The exact URL is set
        // afterwards, and opening the form never creates or starts a review.
        shell.prReview.pendingURL = selection.request.pullRequest.url
        shell.prReview.isPresentingStartSheet = true
        return .opened
    }

    private static func name(_ machineID: String, model: HerdrAppModel) -> String {
        model.machines.first { $0.id == machineID }?.name ?? machineID
    }

    private static func unavailable(_ message: String, model: HerdrAppModel) -> Outcome {
        model.toastMessage = message
        return .unavailable(message)
    }
}
