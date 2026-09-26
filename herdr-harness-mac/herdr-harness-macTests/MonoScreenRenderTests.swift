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

    @Test("Chat: sidebar, pane header, transcript and composer")
    func chat() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.openPane(id: "demo1|w1:p2")
        let modelFavorites = ModelFavoritesStore()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let pane = try HerdrRenderFixtures.piCapablePane()
        let store = try await HerdrRenderFixtures.populatedPiStore()

        let result = try await HerdrRenderHarness.render("mono-chat.png", size: Self.window) {
            MonoWindowFrame(model: model) {
                VStack(spacing: 0) {
                    PaneSessionHeader(model: model, pane: pane, store: store)
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
                }
            }
        }
        result.expectSubstantial()
    }

    @Test("Git: sidebar and the workspace source-control view")
    func git() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let workspace = try #require(model.workspace(id: "demo1|w1"))

        let result = try await HerdrRenderHarness.render("mono-git.png", size: Self.window) {
            MonoWindowFrame(model: model) {
                WorkspaceGitView(
                    workspace: workspace,
                    loadStatus: { try await model.fetchGitStatus(for: workspace) },
                    loadDiff: { file, section in
                        try await model.fetchGitDiff(for: workspace, file: file, section: section)
                    },
                    stageFile: { file in try await model.stageGitFile(file, in: workspace) },
                    unstageFile: { file in try await model.unstageGitFile(file, in: workspace) }
                )
            }
        }
        result.expectSubstantial()
    }

    @Test("Dashboard and Agent view beside the sidebar")
    func dashboardAndAgents() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: UserDefaults(suiteName: "MonoRender.\(UUID())")!)
        shell.firstMate.configure(client: nil, demo: true)
        shell.prReview.configure(client: nil, machineID: "demo", demo: true)
        await shell.prReview.refresh()
        let entries = MonoRenderFixtures.seedFeatures(shell: shell)

        let dashboard = try await HerdrRenderHarness.render("mono-dashboard.png", size: Self.window) {
            MonoWindowFrame(model: model) { DashboardView(model: model, shell: shell) }
        }
        dashboard.expectSubstantial()

        for (index, entry) in entries.enumerated() {
            let column = shell.agentBoard.column(for: entry)
            column.configure(configuration: nil, generation: 0, demo: true, client: nil,
                             demoSnapshot: shell.firstMate.snapshots[entry.feature.id])
            if index == 2 { column.tab = .overview }
        }
        let agents = try await HerdrRenderHarness.render("mono-agents.png", size: Self.window) {
            MonoWindowFrame(model: model) { AgentBoardView(model: model, shell: shell) }
        }
        agents.expectSubstantial()
    }

    @Test("First Mate workspace in dark and light", arguments: [ColorScheme.dark, .light])
    func firstMate(scheme: ColorScheme) async throws {
        let model = HerdrRenderFixtures.demoModel()
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        store.advanceDemo()
        store.isDark = scheme == .dark
        _ = try #require(store.snapshot)
        let palette = FirstMatePalette(scheme: scheme)
        let name = scheme == .dark ? "dark" : "light"

        let result = try await HerdrRenderHarness.render("mono-first-mate-\(name).png", size: Self.window) {
            HStack(spacing: 0) {
                FirstMateSidebarView(store: store, back: {}, canControl: true)
                    .frame(width: HerdrTheme.sidebarWidth)
                Rectangle().fill(palette.hairline).frame(width: 1)
                FirstMateWorkspaceView(
                    model: model,
                    store: store,
                    modelFavorites: ModelFavoritesStore(),
                    canControl: true,
                    owningMachineID: "demo",
                    gitOwnerIsReady: false,
                    configuration: nil,
                    configurationRevision: 0,
                    owningMachineName: "Demo Mac"
                )
            }
            .background(palette.background)
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
                    .padding(.top, 60)
                    .padding(.trailing, 40)
            }
        }
        result.expectSubstantial()
    }
}

/// The main window's shell as `WorkspaceNavigationView` lays it out, minus
/// the split view and window chrome that offscreen snapshots cannot draw.
private struct MonoWindowFrame<Detail: View>: View {
    let model: HerdrAppModel
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            HerdrSidebarView(model: model, openPane: { _ in }, openWorkspace: { _ in })
                .frame(width: HerdrTheme.sidebarWidth)
                .background(HerdrTheme.railBackground)
            Rectangle()
                .fill(HerdrTheme.hairline)
                .frame(width: 1)
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HerdrTheme.windowBackground)
        }
    }
}

@MainActor
enum MonoRenderFixtures {
    /// A Herdr-owned dusk gradient standing in for a desktop picture.
    static var desktop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.11, blue: 0.29), Color(red: 0.06, green: 0.07, blue: 0.15)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.52, green: 0.38, blue: 0.87).opacity(0.9), .clear],
                           center: UnitPoint(x: 0.12, y: 0.08), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.84, green: 0.47, blue: 0.70).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.88, y: 0.06), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.66).opacity(0.75), .clear],
                           center: UnitPoint(x: 0.7, y: 1), startRadius: 0, endRadius: 560)
        }
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
