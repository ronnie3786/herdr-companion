import AppKit
import SwiftUI

struct HomeShellView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let modelFavorites: ModelFavoritesStore
    let updates: HerdrUpdateController
    let utilities: AnyView
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var hasScrolled = false

    private var tab: HomeTab { HomeTab(scope: shell.detailScope) }

    var body: some View {
        Group {
            if let controller = shell.homeChat {
                surface.modifier(HomeChatPresentation(
                    controller: controller, model: model, modelFavorites: modelFavorites,
                    snapshot: shell.home.snapshot, isHomeVisible: shell.detailScope == .home,
                    isActive: shell.mainWindowAllowsPresentation,
                    query: Binding(get: { shell.home.search }, set: { shell.home.search = $0 }),
                    searchPresented: $shell.homeSearchPresented, askRequest: shell.homeAskRequest,
                    openWindow: { NSApp.activate(); openWindow(id: HerdrWindowID.firstMateChat) }))
            } else {
                surface
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var surface: some View {
        ZStack(alignment: .top) {
            HomePalette.base.ignoresSafeArea()
            if shell.detailScope == .home {
                HomeHostView(model: model, shell: shell, home: shell.home,
                             onScroll: { hasScrolled = $0 },
                             openWindow: { NSApp.activate(); openWindow(id: $0) }, openSettings: { openSettings() })
            } else {
                WorkspaceNavigationView(model: model, shell: shell, modelFavorites: modelFavorites, updates: updates)
                    .padding(.top, 86)
            }
            HomeTabStrip(selection: tab, snapshot: shell.home.snapshot,
                         query: Binding(get: { shell.home.search }, set: { shell.home.search = $0 }), isSearching: $shell.homeSearchPresented,
                         searchFocusRequest: shell.homeSearchFocusRequest,
                         hasScrolled: shell.detailScope != .home || hasScrolled,
                         isActive: shell.mainWindowAllowsPresentation,
                         onSelect: { shell.show($0.scope, model: model) },
                         onSearch: search, chatsTools: utilities)
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: shell.mainWindowAllowsPresentation) {
            if let moment = HomeFixtures.requestedMoment {
                shell.home.receive(HomeFixtures.snapshot(moment))
            } else {
                guard shell.mainWindowAllowsPresentation else { return }
                await shell.homeProjection.run(model: model, shell: shell, home: shell.home)
            }
        }
        .onChange(of: shell.detailScope, initial: true) { _, scope in
            if scope == .home { shell.home.beginVisit() } else { shell.home.endVisit() }
        }
        .background {
            if [.home, .reviews, .watchers, .chats].contains(tab) {
                Button("Find", action: search).keyboardShortcut("f", modifiers: .command).hidden()
            }
        }
        .sheet(isPresented: $shell.isInboxPresented) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Work inbox").font(.title2.bold())
                    Spacer()
                    Button("Done") { shell.isInboxPresented = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    SidebarWorkInboxView(store: shell.workInbox, refreshID: model.connectionGeneration,
                                         automaticallyRefresh: false,
                                         refresh: { await shell.refreshCoordinator.refreshSummaries(model: model, shell: shell, force: true) })
                }
            }
            .padding(24).frame(width: 620, height: 560)
        }
        .sheet(item: $shell.homeReviewPreparation, onDismiss: {
            HomeRouting.finishReviewPreparation(model: model, shell: shell)
        }) { request in
            HomeReviewHostPicker(request: request, model: model, shell: shell)
        }
    }

    private func search() {
        if tab == .home {
            shell.homeSearchPresented = true
            shell.homeSearchFocusRequest &+= 1
        } else if shell.detailScope == .watchers || shell.detailScope == .prReview || shell.detailScope == .session || shell.detailScope == .git {
            if tab == .chats { shell.requestSidebarShow() }
            shell.surfaceSearchFocusRequest &+= 1
        } else {
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
        }
    }
}
