import Testing
@testable import herdr_harness_ios

@Suite("Pane drafts")
struct PaneDraftStoreTests {
    @MainActor
    @Test("Drafts preserve every nonempty character verbatim")
    func preservesWhitespaceVerbatim() {
        let store = PaneDraftStore()
        let indented = "\n\n    let value = 1\n  "

        store.setText(indented, for: "desktop|w1:p1")
        store.setText("   \n", for: "desktop|w1:p2")

        #expect(store.text(for: "desktop|w1:p1") == indented)
        #expect(store.text(for: "desktop|w1:p2") == "   \n")

        store.setText("", for: "desktop|w1:p2")
        #expect(store.text(for: "desktop|w1:p2").isEmpty)
    }

    @MainActor
    @Test("Async completion clears only an unchanged origin-pane submission")
    func compareAndClearProtectsLaterEditsAndOtherPanes() {
        let store = PaneDraftStore()
        let submitted = "  keep my indentation\n"
        store.setText(submitted, for: "desktop|w1:p1")
        store.setText("other pane", for: "desktop|w1:p2")

        store.setText("edited while sending", for: "desktop|w1:p1")
        #expect(!store.clearText(for: "desktop|w1:p1", ifUnchanged: submitted))
        #expect(store.text(for: "desktop|w1:p1") == "edited while sending")
        #expect(store.text(for: "desktop|w1:p2") == "other pane")

        #expect(store.clearText(for: "desktop|w1:p1", ifUnchanged: "edited while sending"))
        #expect(store.text(for: "desktop|w1:p1").isEmpty)
        #expect(store.text(for: "desktop|w1:p2") == "other pane")
    }

    @MainActor
    @Test("Empty refreshes preserve drafts and real snapshots prune only their machine")
    func reconciliationIsMachineScopedAndEmptySafe() {
        let store = PaneDraftStore()
        store.setText("keep", for: "desktop|w1:p1")
        store.setText("remove", for: "desktop|w1:p2")
        store.setText("other machine", for: "laptop|w1:p1")

        store.reconcile(machineID: "desktop", validPaneIDs: [])
        #expect(store.text(for: "desktop|w1:p2") == "remove")

        store.reconcile(machineID: "desktop", validPaneIDs: ["desktop|w1:p1"])
        #expect(store.text(for: "desktop|w1:p1") == "keep")
        #expect(store.text(for: "desktop|w1:p2").isEmpty)
        #expect(store.text(for: "laptop|w1:p1") == "other machine")

        store.removeAll(forMachineID: "laptop")
        #expect(store.text(for: "laptop|w1:p1").isEmpty)
    }
}
