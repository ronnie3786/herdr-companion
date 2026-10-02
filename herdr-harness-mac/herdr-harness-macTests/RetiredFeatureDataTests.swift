import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Retired feature data")
struct RetiredFeatureDataTests {
    @Test("Launch cleanup removes the retired response brief settings and saved file")
    func purgesRetiredBriefData() throws {
        let suiteName = "RetiredFeatureDataTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        for key in RetiredFeatureData.defaultsKeys { defaults.set("synthetic", forKey: key) }
        defaults.set("kept", forKey: "herdr.navigation.history")
        let saved = root.appending(path: "Herdr/response-briefs-v1.json", directoryHint: .notDirectory)
        let kept = root.appending(path: "Herdr/pr-review-comments-v1.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: saved)
        try Data("{}".utf8).write(to: kept)

        RetiredFeatureData.purge(defaults: defaults, applicationSupport: root)
        // Idempotent: a second launch finds nothing left to remove.
        RetiredFeatureData.purge(defaults: defaults, applicationSupport: root)

        for key in RetiredFeatureData.defaultsKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.string(forKey: "herdr.navigation.history") == "kept")
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}
