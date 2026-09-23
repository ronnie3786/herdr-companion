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
        // Compute the call outside the macro so the injected opener stays a
        // MainActor closure; the `#expect` rewrite requires a Sendable one.
        let didOpen = FirstMateLinkActions.open(link, opener: { opened = $0; return true })
        #expect(didOpen)
        #expect(opened?.absoluteString == link.url)
        #expect(link.hostLabel == "share.example.test:8443")

        let pasteboard = NSPasteboard.withUniqueName()
        #expect(FirstMateLinkActions.copy(link, pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == link.url)
    }

    @Test("Bracketed IPv6 share URLs Open and Copy their exact saved destination")
    func ipv6Destinations() {
        let url = "https://[2001:db8::42]:8443/review?tab=links#evidence"
        let link = FirstMateLink(
            id: "link-ipv6",
            featureID: "feature-a",
            url: url,
            kind: "link",
            title: "Synthetic IPv6 share",
            source: "user",
            createdAt: "2030-01-01T12:00:00Z",
            updatedAt: "2030-01-01T12:00:00Z"
        )
        #expect(link.destination?.absoluteString == url)
        #expect(link.hostLabel == "[2001:db8::42]:8443")
        var opened: URL?
        let didOpen = FirstMateLinkActions.open(link, opener: { opened = $0; return true })
        #expect(didOpen)
        #expect(opened?.absoluteString == url)
        let pasteboard = NSPasteboard.withUniqueName()
        #expect(FirstMateLinkActions.copy(link, pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == url)

        // Credentialed and malformed IPv6 destinations never reach the system.
        for rejected in [
            "https://user:secret@[2001:db8::42]/review",
            "https://[2001:db8::42]:0/review",
            "https://[2001:db8::42]:70000/review",
            "https://[fe80::1%25en0]:8443/review",
        ] {
            let unsafe = FirstMateLink(
                id: "link-ipv6-unsafe",
                featureID: "feature-a",
                url: rejected,
                kind: "link",
                title: "Unsafe IPv6",
                source: "user",
                createdAt: "",
                updatedAt: ""
            )
            #expect(unsafe.destination == nil)
            var rejectedOpen = false
            // Compute the call outside the macro so the injected opener stays a
            // MainActor closure; the `#expect` rewrite requires a Sendable one.
            let didOpen = FirstMateLinkActions.open(unsafe, opener: { _ in rejectedOpen = true; return true })
            #expect(!didOpen)
            #expect(!rejectedOpen)
        }
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
            let didOpen = FirstMateLinkActions.open(link, opener: { _ in opened = true; return true })
            let didCopy = FirstMateLinkActions.copy(link, pasteboard: pasteboard)
            #expect(!didOpen)
            #expect(!opened)
            #expect(!didCopy)
        }
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("Pull requests lead the snapshot while general links stay secondary")
    func pullRequestProminence() {
        let snapshot = FirstMateDemo.features(step: 0)[0]
        #expect(snapshot.pullRequestLinks.map(\.id) == ["demo-link-pr-101", "demo-link-pr-7"])
        // An explicit closure keeps the `#expect` rewrite from treating the
        // `rethrows` call as throwing; a key path would not compile here.
        #expect(snapshot.pullRequestLinks.allSatisfy { $0.isPullRequest })
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
