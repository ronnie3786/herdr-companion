import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("External Pi launch delivery")
@MainActor
struct ExternalPiLauncherTests {
    private func request(prompt: String = "Summarize") throws -> ExternalPiRequest {
        var url = URLComponents(string: "herdr://pi/new")!
        url.queryItems = [.init(name: "prompt", value: prompt), .init(name: "request_id", value: "slack-123")]
        return try ExternalPiRequest(url: #require(url.url))
    }

    @Test("Retry after restart opens the original session without resending")
    func persistedReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "receipts.json")
        var creates = 0
        var prompts: [String] = []
        var opened: [String] = []
        for _ in 0..<2 {
            let launcher = ExternalPiLauncher(storeURL: path)
            try await launcher.start(request()) {
                creates += 1
                return "mac|w1:p2"
            } send: { _, prompt in prompts.append(prompt) } openPane: { opened.append($0) }
        }
        #expect(creates == 1)
        #expect(prompts == ["Summarize"])
        #expect(opened == ["mac|w1:p2", "mac|w1:p2"])
        let saved = try String(contentsOf: path, encoding: .utf8)
        #expect(!saved.contains("Summarize"))
    }

    @Test("A lost send acknowledgement never sends a second prompt")
    func ambiguousSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "receipts.json")
        var sends = 0
        var creates = 0
        var opened: [String] = []
        let first = ExternalPiLauncher(storeURL: path)
        await #expect(throws: URLError.self) {
            try await first.start(request()) {
                creates += 1
                return "mac|w1:p2"
            } send: { _, _ in sends += 1; throw URLError(.timedOut) } openPane: { opened.append($0) }
        }
        let restarted = ExternalPiLauncher(storeURL: path)
        await #expect(throws: ExternalPiLauncher.LaunchError.self) {
            try await restarted.start(request()) {
                creates += 1
                return "mac|w1:p3"
            } send: { _, _ in sends += 1 } openPane: { opened.append($0) }
        }
        #expect(creates == 1)
        #expect(sends == 1)
        #expect(opened == ["mac|w1:p2", "mac|w1:p2"])
    }

    @Test("A reused request ID with changed content is rejected")
    func conflictingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = ExternalPiLauncher(storeURL: directory.appending(path: "receipts.json"))
        try await launcher.start(request()) { "mac|w1:p2" } send: { _, _ in } openPane: { _ in }
        await #expect(throws: ExternalPiLauncher.LaunchError.self) {
            try await launcher.start(request(prompt: "Do something else")) {
                Issue.record("Must not create a second session")
                return "mac|w1:p3"
            } send: { _, _ in Issue.record("Must not send") } openPane: { _ in }
        }
    }

    @Test("An unwritable journal prevents session creation")
    func persistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = ExternalPiLauncher(storeURL: directory.appending(path: "receipts.json"))
        await #expect(throws: (any Error).self) {
            try await launcher.start(request()) {
                Issue.record("Must persist the receipt before creating")
                return "mac|w1:p2"
            } send: { _, _ in } openPane: { _ in }
        }
    }

    @Test("A corrupt receipt file fails closed instead of repeating unknown work")
    func corruptJournal() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("corrupt".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let launcher = ExternalPiLauncher(storeURL: file)
        await #expect(throws: (any Error).self) {
            try await launcher.start(request()) {
                Issue.record("Do not repeat work when its receipt could not be read")
                return "mac|w1:p2"
            } send: { _, _ in } openPane: { _ in }
        }
    }
}
