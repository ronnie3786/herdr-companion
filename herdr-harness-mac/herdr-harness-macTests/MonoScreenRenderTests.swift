import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Whole-window renders at the Mono × Herdr study's frame (1280×800), one per
/// target screen: chat, Git, Dashboard, Agent view, First Mate (dark and
/// light) and the HUD. Offscreen snapshots cannot draw a `NavigationSplitView`
/// sidebar or window chrome (see `DemoScreenshotRenderTests.rendersRootShell`),
/// so each screen is composed the way `WorkspaceNavigationView` composes it:
/// the production sidebar, a hairline, and the production detail view.
/// All data is the app's synthetic demo fleet.
@Suite("Mono screen renders", .serialized)
@MainActor
struct MonoScreenRenderTests {
    static let window = CGSize(width: 1280, height: 800)

    @Test("Chat: sidebar, title bar, transcript and composer")
    func chat() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.openPane(id: "demo1|w1:p2")
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.showSession()
        let modelFavorites = ModelFavoritesStore()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let pane = try HerdrRenderFixtures.piCapablePane()
        let store = try await HerdrRenderFixtures.populatedPiStore()

        let result = try await HerdrRenderHarness.renderWindow("mono-chat.png", size: Self.window) {
            // Mirrors `PaneSessionView`: the pane's title and ⋯ menu go to the
            // window title bar; the chat fills the detail column.
            MonoRenderFixtures.window(model: model, shell: shell, detail: AnyView(
                PiChatView(
                    model: model,
                    store: store,
                    paneID: pane.id,
                    interactionResponseAvailable: true,
                    composerPane: pane,
                    workspace: workspace,
                    draft: .constant(""),
                    attachments: .constant([]),
                    focusRequest: 0,
                    interactionResponder: PiInteractionResponder(),
                    modelFavorites: modelFavorites
                )
                .herdrTitleBar(hostsShellMenu: true) {
                    PaneSessionTitle(model: model, pane: pane, store: store)
                } trailing: {
                    PaneActionsMenu(model: model, pane: pane, selectedMode: .constant(.chat), summarizeSession: {})
                }
            ))
        }
        result.expectSubstantial()
    }

    @Test("Git: sidebar and the workspace source-control view")
    func git() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.openPane(id: "demo1|w1:p2")
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.showSession()
        let workspace = try #require(model.workspace(id: "demo1|w1"))

        let result = try await HerdrRenderHarness.renderWindow("mono-git.png", size: Self.window) {
            MonoRenderFixtures.window(model: model, shell: shell, detail: AnyView(
                WorkspaceGitView(
                    workspace: workspace,
                    loadStatus: { try await model.fetchGitStatus(for: workspace) },
                    loadDiff: { file, section in
                        try await model.fetchGitDiff(for: workspace, file: file, section: section)
                    },
                    stageFile: { file in try await model.stageGitFile(file, in: workspace) },
                    unstageFile: { file in try await model.unstageGitFile(file, in: workspace) }
                )
            ))
        }
        result.expectSubstantial()
    }

    @Test("The largest text size keeps every screen's bars and cards intact")
    func largestText() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.openPane(id: "demo1|w1:p2")
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.firstMate.configure(client: nil, demo: true)
        shell.prReview.configure(client: nil, machineID: "demo", demo: true)
        await shell.prReview.refresh()
        MonoRenderFixtures.seedFeatures(shell: shell)
        shell.show(.dashboard, model: model)
        let size = CGSize(width: 1440, height: 900)
        let dashboard = try await HerdrRenderHarness.renderWindow("mono-dashboard-160.png", size: size) {
            MonoRenderFixtures.window(model: model, shell: shell, scale: .xxxLarge)
        }
        dashboard.expectSubstantial()

        let chatShell = MonoRenderFixtures.shell(sidebarOnHome: true)
        chatShell.showSession()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let pane = try HerdrRenderFixtures.piCapablePane()
        let store = try await HerdrRenderFixtures.populatedPiStore()
        let chat = try await HerdrRenderHarness.renderWindow("mono-chat-160.png", size: size) {
            MonoRenderFixtures.window(model: model, shell: chatShell, detail: AnyView(
                PiChatView(
                    model: model, store: store, paneID: pane.id, interactionResponseAvailable: true,
                    composerPane: pane, workspace: workspace, draft: .constant(""), attachments: .constant([]),
                    focusRequest: 0, interactionResponder: PiInteractionResponder(),
                    modelFavorites: ModelFavoritesStore()
                )
                .herdrTitleBar(hostsShellMenu: true) {
                    PaneSessionTitle(model: model, pane: pane, store: store)
                } trailing: {
                    PaneActionsMenu(model: model, pane: pane, selectedMode: .constant(.chat), summarizeSession: {})
                }
            ), scale: .xxxLarge)
        }
        chat.expectSubstantial()

        let firstMateShell = MonoRenderFixtures.shell(sidebarOnHome: true)
        firstMateShell.show(.firstMate, model: model)
        firstMateShell.configureFirstMateIfNeeded(machineID: "demo", configuration: nil,
                                                  connectionGeneration: model.connectionGeneration, isDemo: true)
        await firstMateShell.firstMate.refresh()
        firstMateShell.firstMate.advanceDemo()
        let firstMate = try await HerdrRenderHarness.renderWindow("mono-first-mate-160.png", size: size) {
            MonoRenderFixtures.window(model: model, shell: firstMateShell, scale: .xxxLarge)
        }
        firstMate.expectSubstantial()
    }

    @Test("Dashboard and Agent view beside the sidebar")
    func dashboardAndAgents() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.firstMate.configure(client: nil, demo: true)
        shell.prReview.configure(client: nil, machineID: "demo", demo: true)
        await shell.prReview.refresh()
        let entries = MonoRenderFixtures.seedFeatures(shell: shell)
        shell.show(.dashboard, model: model)

        let dashboard = try await HerdrRenderHarness.renderWindow("mono-dashboard.png", size: Self.window) {
            MonoRenderFixtures.window(model: model, shell: shell)
        }
        dashboard.expectSubstantial()

        // The Dashboard's default: no rail, so the title bar starts after the
        // traffic lights with the sidebar toggle.
        let hiddenShell = MonoRenderFixtures.shell(sidebarOnHome: false)
        hiddenShell.firstMate.configure(client: nil, demo: true)
        MonoRenderFixtures.seedFeatures(shell: hiddenShell)
        hiddenShell.show(.dashboard, model: model)
        let collapsed = try await HerdrRenderHarness.renderWindow("mono-dashboard-no-sidebar.png", size: Self.window) {
            MonoRenderFixtures.window(model: model, shell: hiddenShell)
        }
        collapsed.expectSubstantial()

        for (index, entry) in entries.enumerated() {
            let column = shell.agentBoard.column(for: entry)
            column.configure(configuration: nil, generation: 0, demo: true, client: nil,
                             demoSnapshot: shell.firstMate.snapshots[entry.feature.id])
            if index == 2 { column.tab = .overview }
        }
        shell.show(.agentBoard, model: model)
        let agents = try await HerdrRenderHarness.renderWindow("mono-agents.png", size: Self.window) {
            MonoRenderFixtures.window(model: model, shell: shell)
        }
        agents.expectSubstantial()
    }

    @Test("First Mate workspace in dark and light", arguments: [ColorScheme.dark, .light])
    func firstMate(scheme: ColorScheme) async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.show(.firstMate, model: model)
        shell.configureFirstMateIfNeeded(machineID: "demo", configuration: nil, connectionGeneration: model.connectionGeneration, isDemo: true)
        await shell.firstMate.refresh()
        shell.firstMate.advanceDemo()
        shell.firstMate.isDark = scheme == .dark
        _ = try #require(shell.firstMate.snapshot)
        let name = scheme == .dark ? "dark" : "light"

        let result = try await HerdrRenderHarness.renderWindow("mono-first-mate-\(name).png", size: Self.window) {
            // First Mate's light appearance stays opaque.
            MonoRenderFixtures.window(model: model, shell: shell, glass: scheme == .dark)
                .background(FirstMatePalette(scheme: scheme).background)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
        result.expectSubstantial()
    }

    @Test("HUD quick panel over a desktop")
    func hud() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let suite = "MonoHudRender.\(UUID().uuidString)"
        let session = HerdrHudSession(
            userDefaults: try #require(UserDefaults(suiteName: suite)),
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MonoHudRender-\(UUID().uuidString)-hud-thread.json")
        )
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "hud-fleet-status", machineID: "demo1",
                prompt: "What is the current status of the demo fleet?",
                sentPrompt: "What is the current status of the demo fleet?",
                response: "The fleet is healthy. Two alerts need attention, and one pane is waiting for review.",
                error: nil, status: .completed, costUSD: nil, createdAt: .now,
                promotedPaneID: nil, attachmentFilenames: []
            ),
            HerdrHudExchange(
                id: "hud-resolve-alert", machineID: "demo1",
                prompt: "Resolve the stale attention alert and summarize the change.",
                sentPrompt: "Resolve the stale attention alert and summarize the change.",
                response: "Resolved the stale alert, refreshed its status, and left the active pane open for review.",
                error: nil, status: .completed, costUSD: 0.0042, createdAt: .now,
                promotedPaneID: nil, attachmentFilenames: ["alert-screenshot.png"]
            ),
        ])

        let result = try await HerdrRenderHarness.render("mono-hud.png", size: CGSize(width: 980, height: 700)) {
            ZStack(alignment: .topTrailing) {
                MonoRenderFixtures.desktop
                HerdrHudCardView(model: model, controller: HerdrHudController(), session: session)
                    .frame(width: 420, height: 580)
                    .environment(\.herdrGlassActive, true)
                    .padding(.top, 60)
                    .padding(.trailing, 40)
            }
        }
        result.expectSubstantial()
    }
}

@MainActor
enum MonoRenderFixtures {
    /// A shell with its own defaults; the Dashboard and Agent view show the
    /// sidebar, as they do in the study's frames.
    static func shell(sidebarOnHome: Bool) -> HerdrShellState {
        let defaults = UserDefaults(suiteName: "MonoRender.\(UUID().uuidString)")!
        let shell = HerdrShellState(userDefaults: defaults)
        shell.rememberSidebarVisibility(sidebarOnHome ? .all : .detailOnly, home: true)
        shell.rememberSidebarVisibility(.all, home: false)
        return shell
    }

    /// The production window shell: `WorkspaceNavigationView` with its rail,
    /// title bar and routed (or injected) detail. With `glass`, the app's own
    /// dusk backdrop sits behind both columns exactly as the main window
    /// draws it, so these renders show the real glass.
    static func window(model: HerdrAppModel, shell: HerdrShellState, detail: AnyView? = nil, glass: Bool = true,
                       scale: HerdrFontScale = .medium) -> some View {
        ZStack {
            if glass { HerdrDuskBackdrop() }
            WorkspaceNavigationView(
                model: model,
                shell: shell,
                activeWorkStore: ActiveWorkStore(),
                modelFavorites: ModelFavoritesStore(),
                updates: HerdrUpdateController(defaults: UserDefaults(suiteName: "MonoRender.updates.\(UUID().uuidString)")!),
                detailOverride: detail
            )
        }
        .environment(\.herdrGlassActive, glass)
        .environment(\.herdrHazeActive, glass)
        .environment(HerdPulseCoordinator(defaults: UserDefaults(suiteName: "MonoRender.pulse")!))
        .environment(\.herdrFontScale, scale)
    }

    /// A desktop picture behind the floating HUD. The HUD draws its own dusk,
    /// so a plain blue-gray wallpaper shows it does not depend on this one.
    static var desktop: some View {
        LinearGradient(colors: [Color(red: 0.36, green: 0.45, blue: 0.55), Color(red: 0.13, green: 0.17, blue: 0.23)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Five synthetic First Mate features with the Dashboard's status mix.
    @discardableResult
    static func seedFeatures(shell: HerdrShellState) -> [DashboardFeatureEntry] {
        let titles = ["Offline garden notes", "Keep agent sessions connected", "Settings screen refresh",
                      "Weather readout", "Seed catalog sync"]
        let statuses = ["awaiting_direction", "awaiting_direction", "blocked", "running", "paused"]
        let base = Date.now.addingTimeInterval(-3_600)
        for (index, title) in titles.enumerated() {
            var snapshot = FirstMateDemo.features(step: index % 4)[0]
            let id = "demo-mono-\(index)"
            snapshot.feature.id = id
            snapshot.feature.title = title
            snapshot.feature.status = statuses[index]
            snapshot.feature.updatedAt = HerdrTimestamp.string(from: Date.now.addingTimeInterval(Double(-index * 60)))
            for i in snapshot.visits.indices { snapshot.visits[i].featureID = id }
            for i in snapshot.assignments.indices { snapshot.assignments[i].featureID = id }
            for i in snapshot.messages.indices { snapshot.messages[i].featureID = id }
            snapshot.messages.append(.init(
                id: "\(id)-markdown", featureID: id, role: "assistant",
                text: "The second review is in — **PR #12032 is now approved**.\n\n- Two approvals\n- `ios_core` still pending",
                status: "done", createdAt: HerdrTimestamp.string(from: base.addingTimeInterval(3_000))))
            snapshot.events = snapshot.events.map { event in
                var event = event
                event.featureID = id
                return event
            }
            var summary = FirstMateDashboardSummary.from(snapshot)
            summary.activityAt = snapshot.feature.updatedAt
            if statuses[index] == "awaiting_direction" || statuses[index] == "blocked" {
                summary.needsUserPrompt = "Choose **A** (merge now) or **B** (wait for `ios_core`)."
            }
            snapshot.feature.dashboardSummary = summary
            shell.firstMate.receive(snapshot)
        }
        return shell.dashboard.entries(shell: shell, isDemo: true)
    }
}
