import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

/// Mac-only presentation checks for the saved-link surfaces. Open and Copy are
/// exercised through injected collaborators so no destination is contacted and
/// no shared pasteboard is touched.
@Suite("First Mate link presentation", .serialized)
@MainActor
struct FirstMateLinksPresentationTests {
    @Test("Open and Copy use the exact saved HTTP(S) destination")
    func exactDestinations() throws {
        let link = FirstMateLink(
            id: "link-share",
            featureID: "feature-a",
            url: "https://share.example.test:8443/review/session-continuity?tab=links#evidence",
            kind: "link",
            title: "Synthetic review share",
            source: "user",
            createdAt: "2030-01-01T12:00:00Z",
            updatedAt: "2030-01-01T12:00:00Z"
        )
        var opened: URL?
        #expect(FirstMateLinkActions.open(link, opener: { opened = $0; return true }))
        #expect(opened?.absoluteString == link.url)
        #expect(link.hostLabel == "share.example.test:8443")

        let pasteboard = NSPasteboard.withUniqueName()
        #expect(FirstMateLinkActions.copy(link, pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == link.url)
    }

    @Test("A rejected destination never reaches the injected opener or pasteboard")
    func rejectsUnsafeDestinations() {
        let pasteboard = NSPasteboard.withUniqueName()
        for value in [
            "",
            "javascript:alert(1)",
            "file:///tmp/review",
            "https://user:secret@example.test/review",
            "https://example.test/has space",
        ] {
            let link = FirstMateLink(
                id: "link-unsafe",
                featureID: "feature-a",
                url: value,
                kind: "link",
                title: "Unsafe",
                source: "user",
                createdAt: "",
                updatedAt: ""
            )
            var opened = false
            #expect(!FirstMateLinkActions.open(link, opener: { _ in opened = true; return true }))
            #expect(!opened)
            #expect(!FirstMateLinkActions.copy(link, pasteboard: pasteboard))
        }
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("Pull requests lead the snapshot while general links stay secondary")
    func pullRequestProminence() {
        let snapshot = FirstMateDemo.features(step: 0)[0]
        #expect(snapshot.pullRequestLinks.map(\.id) == ["demo-link-pr-101", "demo-link-pr-7"])
        #expect(snapshot.pullRequestLinks.allSatisfy(\.isPullRequest))
        #expect(snapshot.otherLinks.map(\.id) == ["demo-link-share"])
        #expect(snapshot.otherLinks.allSatisfy { !$0.isPullRequest })
        #expect(Set(snapshot.visibleLinks.map(\.id)).count == 3)
        #expect(snapshot.pullRequestLinks.first?.provenanceSummary == "Detected from saved evidence")
        #expect(snapshot.otherLinks.first?.provenanceSummary == nil)
    }

    @Test("Adding links leaves document presentation unchanged")
    func documentsRemainIndependent() {
        let snapshot = FirstMateDemo.features(step: 0)[0]
        #expect(snapshot.documents.count == 3)
        #expect(snapshot.documents.allSatisfy { $0.mediaType == "text/markdown" })
        #expect(!snapshot.documents.contains { document in
            snapshot.links.contains { $0.id == document.id }
        })
        let second = FirstMateDemo.features(step: 0)[1]
        #expect(second.links.isEmpty)
        #expect(second.pullRequestLinks.isEmpty)
    }
}
