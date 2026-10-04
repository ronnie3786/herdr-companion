import SwiftUI

/// Binds the stable presentation store to the native surface. Source work is
/// observed by the shell coordinator, never fetched while this view renders.
struct HomeHostView: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    @Bindable var home: HomeStore
    var onScroll: (Bool) -> Void
    var openWindow: (String) -> Void
    var openSettings: () -> Void
    @State private var visibleChatIDs = Set<String>()

    var body: some View {
        let request = hydrationRequest
        let outcomes = shell.homeQuickReply?.unresolvedOutcomes ?? []
        HomeContentView(snapshot: HomeActionPresentation.snapshot(home.snapshot, snoozedCount: home.snoozedCount,
                                                                 unresolvedReplyCount: outcomes.count),
                        selectedFocusID: home.selectedFocusID,
                        recapExpanded: $home.recapExpanded, onSelectFocus: home.selectFocus,
                        onCommand: command, onScroll: onScroll,
                        isVisible: shell.mainWindowAllowsPresentation,
                        onChatVisibilityChange: chatVisibilityChanged)
            .environment(\.homeActionsEnabled, true)
            .environment(\.homeQuickReplyController, shell.homeQuickReply)
            .task(id: request) {
                await shell.homeQuickReply?.hydrate(focus: request.focus, chats: request.chats,
                                                    enabled: request.enabled)
            }
            .onDisappear { shell.homeQuickReply?.pauseHydration() }
            .task(id: home.statusRevision) {
                // A status is a confirmation, not a banner: it leaves on its own,
                // keeping Undo long enough to reach.
                let revision = home.statusRevision
                guard home.status != nil else { return }
                do { try await Task.sleep(for: .seconds(home.canUndoSnooze ? 8 : 5)) } catch { return }
                home.dismissStatus(revision: revision)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !outcomes.isEmpty || home.status != nil || searchStatus != nil {
                    VStack(spacing: 10) {
                        if let controller = shell.homeQuickReply, !outcomes.isEmpty {
                            HomeReplyOutcomesView(controller: controller, outcomes: outcomes, onOpen: openOutcome)
                        }
                        if let text = home.status ?? searchStatus {
                            HStack(spacing: 12) {
                                Text(text).herdrFont(size: 13).foregroundStyle(HomePalette.secondary)
                                if home.canUndoSnooze {
                                    Button("Undo snooze", action: home.undoLastSnooze)
                                        .herdrFont(size: 13, weight: .semibold).foregroundStyle(HomePalette.accent)
                                        .buttonStyle(HomeButtonStyle())
                                        .accessibilityIdentifier("home-snooze-undo")
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(HomePalette.color(0x282631), in: .capsule)
                            .accessibilityIdentifier("home-status")
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 84)
                }
            }
    }

    private struct HydrationRequest: Equatable {
        var controllerID: ObjectIdentifier?
        var enabled: Bool
        var focus: HomeFocusItem?
        var chats: [HomeChatItem]
        var connectionGeneration: Int
        var isDemo: Bool
        var controllable: [Bool]
    }

    private var hydrationRequest: HydrationRequest {
        let focus = home.selectedFocus
        let chats = Array(home.snapshot.chats.filter { visibleChatIDs.contains($0.id) && $0.isWaiting && !$0.isStale }.prefix(3))
        let routes = focus.map { [$0.route] } ?? []
        return .init(controllerID: shell.homeQuickReply.map(ObjectIdentifier.init),
                     enabled: shell.mainWindowAllowsPresentation && shell.detailScope == .home
                        && shell.homeChat?.isPresented != true && HomeFixtures.requestedMoment == nil,
                     focus: focus, chats: chats, connectionGeneration: model.connectionGeneration,
                     isDemo: model.isDemoMode, controllable: (routes + chats.map(\.route)).map { route in
                         switch route {
                         case .firstMate(let machineID, _): model.canControl(machineID: machineID)
                         case .chat(let paneID): MachineScopedID.split(paneID).map { model.canControl(machineID: $0.machineID) } ?? false
                         default: false
                         }
                     })
    }

    private func chatVisibilityChanged(_ id: String, _ visible: Bool) {
        if visible { visibleChatIDs.insert(id) } else { visibleChatIDs.remove(id) }
    }

    private func openOutcome(_ outcome: HomeQuickReplyOutcome) {
        guard shell.homeQuickReply?.canOpenOutcome(outcome) == true else {
            home.showStatus("The original conversation is unavailable. Its reply status is kept here.")
            return
        }
        HomeRouting.open(outcome.id, model: model, shell: shell, openWindow: openWindow, openSettings: openSettings)
    }

    private var searchStatus: String? {
        guard !home.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              home.snapshot.focus.isEmpty, home.snapshot.radar.isEmpty,
              home.snapshot.chats.isEmpty, home.snapshot.recap.isEmpty else { return nil }
        return "No matching work. Try another search."
    }

    private func command(_ command: HomeCommand) {
        switch command {
        case .open(let route):
            HomeRouting.open(route, model: model, shell: shell, openWindow: openWindow, openSettings: openSettings)
        case .ask(let draft, let route):
            let context = HomeActionContext.make(route: route, snapshot: home.snapshot)
            guard route == nil || context != nil else {
                home.showStatus("That item is no longer on Home. Open its conversation to ask about the latest state.")
                return
            }
            guard let chat = shell.homeChat else {
                home.showStatus("First Mate is getting ready. Try again in a moment.")
                return
            }
            chat.open(context: context, draft: draft)
        case .skip: home.skip()
        case .snooze(let id): home.snooze(id)
        case .dismiss(let id): home.dismissRadar(id)
        }
    }
}
