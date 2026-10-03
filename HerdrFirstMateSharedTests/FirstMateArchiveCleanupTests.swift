import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate archive cleanup")
@MainActor
struct FirstMateArchiveCleanupTests {
    @Test("Old companions remain decodable without implying cleanup support")
    func legacyPayload() throws {
        let capabilities = try JSONDecoder().decode(FirstMateCapabilities.self, from: Data(#"{"ok":true,"capabilities":["first-mate-archive-v1"]}"#.utf8))
        #expect(capabilities.supportsArchive)
        #expect(!capabilities.supportsArchiveCleanup)
        let feature = FirstMateDemo.features(step: 0)[0].feature
        #expect(try JSONDecoder().decode(FirstMateFeature.self, from: JSONEncoder().encode(feature)).archiveCleanup == nil)
    }

    @Test("Cleanup progress survives decoding")
    func cleanupPayload() throws {
        let cleanup = try JSONDecoder().decode(FirstMateArchiveCleanup.self, from: Data(#"{"id":"archive_synthetic","status":"failed","attempt":2,"message":"Retained dirty workspace","history_available":true,"bytes_reclaimed":1024,"removed":1,"retained":2,"failed":1,"updated_at":"2026-10-01T12:00:00Z"}"#.utf8))
        #expect(cleanup.canRetry)
        #expect(!cleanup.isRunning)
        #expect(cleanup.bytesReclaimed == 1024)
        var original = FirstMateDemo.features(step: 0)[0].feature
        var changed = original
        changed.archiveCleanup = cleanup
        #expect(original != changed)
        original.archiveCleanup = cleanup
        #expect(original == changed)
    }

    @Test("Full report pagination keeps its fingerprint and exact host")
    func reportPagination() async throws {
        let client = ArchiveTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(store.archiveCleanupSupported)
        #expect(try await store.archiveReport(featureID: "feature") == "First page\nSecond page\n")
        #expect(await client.offsets == [0, 11])
        #expect(await client.fingerprints == [nil, "synthetic-fingerprint"])
        store.configure(client: nil, demo: false)
        #expect(!store.archiveCleanupSupported)
    }
    @Test("Reports reject changed fingerprints, endless cursors and excessive data")
    func invalidReportPages() async {
        for mode in [ArchiveTestClient.Mode.changedFingerprint, .endless, .oversized] {
            let client = ArchiveTestClient(mode: mode)
            let store = FirstMateStore()
            store.configure(client: client, demo: false)
            await store.refresh()
            do {
                _ = try await store.archiveReport(featureID: "feature")
                Issue.record("An invalid report was accepted")
            } catch { }
            let count = await client.offsets.count
            #expect(count == (mode == .endless ? 100 : mode == .oversized ? 1 : 2))
        }
    }

    @Test("A retry captured on an old connection cannot reach its replacement")
    func retryConnectionFence() async {
        let original = ArchiveTestClient()
        let replacement = ArchiveTestClient()
        let store = FirstMateStore()
        store.configure(client: original, demo: false)
        await store.refresh()
        let captured = store.lifecycle
        store.configure(client: replacement, demo: false)
        await store.refresh()
        do {
            try await store.retryCleanup(featureID: "same-id", requestID: "synthetic-request", lifecycle: captured)
            Issue.record("A stale retry was accepted")
        } catch is CancellationError { }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(await original.retries == 0)
        #expect(await replacement.retries == 0)
    }

}

private actor ArchiveTestClient: FirstMateClient {
    enum Mode { case valid, changedFingerprint, endless, oversized }
    let mode: Mode
    init(mode: Mode = .valid) { self.mode = mode }
    private(set) var retries = 0
    func retryFirstMateCleanup(featureID: String, requestID: String) async throws -> FirstMateCleanupResponse {
        retries += 1
        throw APIError.invalidResponse
    }
    private(set) var offsets: [Int] = []
    private(set) var fingerprints: [String?] = []
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-archive-cleanup-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: []) }
    func fetchFirstMateArchivePage(featureID: String, archiveID: String?, offset: Int, sha256: String?) async throws -> FirstMateArchivePage {
        offsets.append(offset)
        fingerprints.append(sha256)
        if mode == .oversized {
            return .init(ok: true, cleanup: nil, report: String(repeating: "x", count: 8_000_001), sha256: "synthetic-fingerprint", nextOffset: nil)
        }
        return .init(ok: true, cleanup: nil, report: offset == 0 ? "First page\n" : "Second page\n",
                     sha256: mode == .changedFingerprint && offset > 0 ? "changed" : "synthetic-fingerprint",
                     nextOffset: mode == .endless ? offset + 11 : offset == 0 ? 11 : nil)
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
