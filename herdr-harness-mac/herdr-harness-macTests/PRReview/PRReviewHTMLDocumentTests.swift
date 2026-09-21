import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review HTML document access")
struct PRReviewHTMLDocumentTests {
    @Test("Only the document directory is readable")
    func limitsReadAccessToDocumentDirectory() {
        let root = URL(fileURLWithPath: "/tmp/pr-review-html-tests", isDirectory: true)
        let file = root.appending(path: "document/report.html")
        let document = PRReviewHTMLDocument(cachedFileURL: file)

        #expect(document.allows(file))
        #expect(document.allows(root.appending(path: "document/chart.svg")))
        #expect(!document.allows(root.appending(path: "sibling/secret.html")))
        #expect(!document.allows(URL(string: "https://example.com/report")!))
        #expect(document.allows(URL(string: "about:blank")!))
    }
}
