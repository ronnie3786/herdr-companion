import Foundation
import Observation

/// A local index into the assistant's durable transcripts. Revision anchors never
/// move when a pull request is refreshed; old questions remain explicitly old.
@MainActor @Observable
final class PRReviewQuestionHistory {
    struct Question: Codable, Equatable, Identifiable {
        var id: String
        var machineID: String
        var reviewID: String
        var path: String
        var baseSHA: String
        var headSHA: String
        var prompt: String
        var title: String
        var checkoutPath: String
        var context: AssistantContext
        var createdAt: Date
    }

    private(set) var questions: [Question] = []
    private(set) var loadError: String?
    private let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Herdr/Assistant/pr-review-questions.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            questions = try JSONDecoder().decode([Question].self, from: Data(contentsOf: url))
        } catch {
            loadError = "Saved review questions could not be loaded. The original file has been preserved."
        }
    }

    func questions(machineID: String, reviewID: String, path: String? = nil) -> [Question] {
        questions.filter { $0.machineID == machineID && $0.reviewID == reviewID && (path == nil || $0.path == path) }
    }

    func append(_ question: Question) throws {
        // Never overwrite a history file we could not decode.
        guard loadError == nil else { throw CocoaError(.fileReadCorruptFile) }
        let updated = questions + [question]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        questions = updated
    }
}
