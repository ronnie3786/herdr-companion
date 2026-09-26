import Testing
@testable import herdr_harness_mac

@Suite("HUD workspace choice presentation")
struct HerdrHudWorkspaceChoiceTextTests {
    @Test("Identically labeled workspaces stay distinguishable by raw workspace ID")
    func duplicateLabelsIncludeWorkspaceID() {
        let first = workspace(id: "w-main", label: "Main")
        let second = workspace(id: "w-other", label: "Main")
        let firstTitle = HerdrHudWorkspaceChoiceText.title(for: first)
        let secondTitle = HerdrHudWorkspaceChoiceText.title(for: second)

        #expect(firstTitle != secondTitle)
        #expect(firstTitle.contains("Main"))
        #expect(secondTitle.contains("Main"))
        #expect(firstTitle.contains("w-main"))
        #expect(secondTitle.contains("w-other"))
    }

    @Test("An empty, identical, or missing label falls back safely to the raw workspace ID")
    func emptyOrIdenticalLabelFallsBackToID() {
        #expect(HerdrHudWorkspaceChoiceText.title(label: "", workspaceID: "w-main") == "w-main")
        #expect(HerdrHudWorkspaceChoiceText.title(label: "   ", workspaceID: "w-main") == "w-main")
        #expect(HerdrHudWorkspaceChoiceText.title(label: "w-main", workspaceID: "w-main") == "w-main")
        #expect(HerdrHudWorkspaceChoiceText.title(label: " Main ", workspaceID: " w-main ") == "Main — w-main")
    }

    private func workspace(id: String, label: String) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceID: id,
            number: 1,
            label: label,
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "\(id):t1",
            agentStatus: .idle
        )
    }
}
