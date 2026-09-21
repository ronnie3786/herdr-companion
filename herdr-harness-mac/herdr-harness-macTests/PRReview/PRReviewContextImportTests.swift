import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review context import")
struct PRReviewContextImportTests {
    @Test("Folders apply the extension, count, and size limits")
    func filtersFolderContentsBeforeUpload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pr-review-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<55 {
            try Data("notes".utf8).write(to: directory.appending(path: "note-\(index).md"))
        }
        try Data("ignored".utf8).write(to: directory.appending(path: "ignored.exe"))
        let large = directory.appending(path: "large.md")
        try Data(repeating: 0, count: Int(AttachmentPolicy.maximumFileBytes) + 1).write(to: large)

        let store = PRReviewStore()
        let files = store.contextImportableURLs(from: [large, directory])

        #expect(files.count == 50)
        #expect(files.allSatisfy { $0.pathExtension == "md" })
        #expect(store.contextImportError?.contains("add it as a link instead") == true)
    }
}
