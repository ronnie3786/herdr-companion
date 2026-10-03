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

    var body: some View {
        HomeContentView(snapshot: readOnlySnapshot, selectedFocusID: home.selectedFocusID,
                        recapExpanded: $home.recapExpanded, onSelectFocus: home.selectFocus,
                        onCommand: command, onScroll: onScroll,
                        isVisible: shell.mainWindowAllowsPresentation)
            .overlay(alignment: .bottom) {
                if let text = home.status ?? searchStatus {
                    Text(text).font(.system(size: 13)).foregroundStyle(HomePalette.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(HomePalette.color(0x282631), in: .capsule)
                        .padding(.bottom, 24)
                        .accessibilityIdentifier("home-status")
                }
            }
    }

    private var readOnlySnapshot: HomeSnapshot {
        var snapshot = home.snapshot
        snapshot.focus = snapshot.focus.map { item in
            var item = item; item.actions = item.actions.filter { $0.command.isNavigation }; return item
        }
        snapshot.radar = snapshot.radar.map { item in
            var item = item; item.actions = item.actions.filter { $0.command.isNavigation }; return item
        }
        snapshot.chats = snapshot.chats.map { item in
            var item = item; item.actions = item.actions.filter { $0.command.isNavigation }; return item
        }
        return snapshot
    }

    private var searchStatus: String? {
        guard !home.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              home.snapshot.focus.isEmpty, home.snapshot.radar.isEmpty,
              home.snapshot.chats.isEmpty, home.snapshot.recap.isEmpty else { return nil }
        return "No matching work. Try another search."
    }

    private func command(_ command: HomeCommand) {
        guard case let .open(route) = command else { return }
        HomeRouting.open(route, model: model, shell: shell, openWindow: openWindow, openSettings: openSettings)
    }
}
