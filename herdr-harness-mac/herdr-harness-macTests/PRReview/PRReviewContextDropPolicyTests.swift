import AppKit
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review context drop policy")
struct PRReviewContextDropPolicyTests {
    @Test("Files, folders, and browser links are accepted")
    func acceptsSupportedPasteboardTypes() {
        #expect(PRReviewContextDropPolicy.accepts(pasteboardTypes: [.fileURL]))
        #expect(PRReviewContextDropPolicy.accepts(pasteboardTypes: [.URL]))
        #expect(PRReviewContextDropPolicy.accepts(pasteboardTypes: [
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
        ]))
    }
}
