import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review renders", .serialized)
struct PRReviewRenderTests {
    @Test("Sidebar renders demo review data")
    func rendersSidebar() async throws {
        let store = demoStore()
        let result = try await HerdrRenderHarness.render(
            "pr-review-sidebar.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewSidebarView(store: store, back: {}, canControl: true)
        }

        result.expectSubstantial()
    }

    @Test("Files tab renders demo review data")
    func rendersFilesContainer() async throws {
        let store = demoStore()
        let result = try await HerdrRenderHarness.render(
            "pr-review-files.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }

        result.expectSubstantial()
    }

    @Test("Context tab renders demo review data")
    func rendersContextContainer() async throws {
        let store = demoStore()
        store.tab = .context
        let result = try await HerdrRenderHarness.render(
            "pr-review-context.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()
    }

    @Test("Agents tab renders demo review data")
    func rendersAgentsContainer() async throws {
        let store = demoStore()
        store.tab = .agents
        let result = try await HerdrRenderHarness.render(
            "pr-review-agents.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()
    }

    @Test("Skills tab renders demo review data")
    func rendersSkillsContainer() async throws {
        let store = demoStore()
        store.tab = .skills
        let result = try await HerdrRenderHarness.render(
            "pr-review-skills.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewContainerView(store: store, canControl: true)
        }
        result.expectSubstantial()
    }

    @Test("Diff renders a highlighted review range")
    func rendersHighlightedDiff() async throws {
        let file = PRReviewDemo.diff().files[0]
        let result = try await HerdrRenderHarness.render(
            "pr-review-highlight.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewDiffText(file: file, highlight: (start: 2, end: 2, side: .after))
        }

        result.expectSubstantial()
    }

    @Test("Large text scale changes the diff render")
    func rendersLargeTextScaleDifferently() async throws {
        let file = PRReviewDemo.diff().files[0]
        let defaultResult = try await HerdrRenderHarness.render(
            "pr-review-diff-default.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewDiffText(file: file)
        }
        let largeResult = try await HerdrRenderHarness.render(
            "pr-review-diff-xxlarge.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            PRReviewDiffText(file: file)
                .environment(\.herdrFontScale, .xxLarge)
        }

        defaultResult.expectSubstantial()
        largeResult.expectSubstantial()
        #expect(defaultResult.byteCount != largeResult.byteCount)
    }

    private func demoStore() -> PRReviewStore {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "demo", demo: true)
        store.receive(PRReviewDemo.snapshot())
        store.selectedPath = PRReviewDemo.snapshot().files[0].path
        store.diff = PRReviewDemo.diff()
        return store
    }
}
