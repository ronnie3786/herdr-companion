import Foundation

/// Synthetic, network-free guide for the existing demo review. Narration uses
/// an optional local DEBUG fixture; the ordinary demo stays text-only.
enum PRReviewGuideDemo {
    /// Local recordings of synthetic scripts allow actual native audio and
    /// drawing verification without embedding service addresses or audio blobs.
    static var narrationFixtureDirectory: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HerdrGuideNarrationFixture"),
              arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        #else
        return nil
        #endif
    }

    static func narrationFixture(text: String, voice: String) throws -> PRReviewNarrationManifest {
        guard let directory = narrationFixtureDirectory else { throw APIError.invalidResponse }
        let hash = PRReviewNarrationManifest.sha256(Data(text.utf8))
        let filename = "\(hash)-\(voice).json"
        return try JSONDecoder().decode(PRReviewNarrationManifest.self, from: Data(contentsOf: directory.appendingPathComponent(filename)))
    }

    static func make(scope: PRReviewGuideScope, question: String? = nil) -> PRReviewGuide {
        let catalog = "Sources/Catalog/SeedCatalog.swift"
        let legacy = "Sources/Legacy/SeedCatalogMigration.swift"
        let source = PRReviewGuideSource(id: "demo-finding", documentID: "prdoc_findings", title: "Review findings", reviewer: "Catalog reviewer", excerpt: "Check that deleting the legacy migration leaves no callers. This is an inspection question, not a reproduced failure.", freshness: "current", provenance: "Synthetic review fixture", headSHA: scope.headSHA, runID: "prun_finished", disposition: "reported", url: nil)
        func chapter(_ id: String, _ title: String, _ objective: String, _ text: String, _ path: String, _ line: Int, _ side: PRReviewSide = .after, sourceRefs: [String] = []) -> PRReviewGuideChapter {
            let target = PRReviewGuideTarget(path: path, side: side, startLine: line, endLine: line)
            let shape = id == "evidence" ? "circle" : id == "recap" ? "arrow" : "underline"
            let targets = id == "recap"
                ? [target, PRReviewGuideTarget(path: catalog, side: .after, startLine: 12, endLine: 12)]
                : [target]
            return .init(id: id, title: title, objective: objective, displayText: text, spokenText: text, segments: [.init(id: id + "-passage", path: path, side: side, startLine: line, endLine: line, spokenText: text, drawings: [.init(id: id + "-mark", shape: shape, targets: targets, onPhrase: "this change", drawSeconds: 0.7)], sourceRefs: sourceRefs)], suggestedQuestions: ["What should I check next?", "What evidence would make this safe?"])
        }
        let chapters: [PRReviewGuideChapter]
        if let question {
            chapters = [chapter("answer", "Let's examine that", "Follow the code, then compare the review report.", "You asked: \(question)\n\nThe Catalog reviewer flagged the removal of the migration as something to inspect. Looking at this change, the type is deleted. That supports checking its callers, but does not by itself prove a bug. Search for uses of SeedCatalogMigration and check the migration tests before deciding whether to raise a concern. This synthetic example has not run those tests.", legacy, 3, .before, sourceRefs: [source.id])]
        } else {
            chapters = [
                chapter("intent", "Start with the behavior", "Identify the intended change before looking for defects.", "This PR introduces the seed catalog. Start by asking what behavior the author intends to change. Looking at this change, the new type is the entry point. Trace how callers will use it, then compare that behavior with the PR description. Reading a file does not mark it viewed, and finishing this explanation will wait for your Next.", catalog, 2),
                chapter("evidence", "Check the removed path", "Turn a reviewer's concern into a concrete inspection.", "The Catalog reviewer asked whether the old migration still has callers. In this change, the migration type is removed. The report gives us a useful question, not a confirmed defect. Inspect references and tests. If no callers remain and the new path covers the behavior, the concern may be resolved.", legacy, 3, .before, sourceRefs: [source.id]),
                chapter("recap", "Decide what needs a comment", "Separate observations, evidence, and unanswered questions.", "For this change, you have identified the new catalog entry point and the removed migration. Keep comments tied to an observable behavior and a concrete code location. The reviewer report is a source to investigate. It is not a test result. You decide whether the available evidence is enough to approve, ask a question, or request a fix.", catalog, 2)
            ]
        }
        return .init(id: "demo-" + UUID().uuidString, state: "finished", reviewID: scope.reviewID, baseSHA: scope.baseSHA, headSHA: scope.headSHA, contextSnapshotID: "synthetic-context", chapters: chapters, sources: [source], coverage: .init(limitations: ["Synthetic demo. No GitHub connection or real code execution."]), error: nil, comparison: scope.comparison)
    }
}
