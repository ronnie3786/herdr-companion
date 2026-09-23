import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate links", .serialized)
@MainActor
struct FirstMateLinksTests {
    @Test("Link snapshots round-trip exact feature, visibility, and provenance")
    func decodeLinks() throws {
        let original = FirstMateDemo.features(step: 0)[0]
        let data = try JSONEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("feature_id"))
        #expect(json.contains("title_source"))
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: data)
        #expect(decoded.links == original.links)
        let detected = try #require(decoded.links.first { $0.id == "demo-link-pr-101" })
        #expect(detected.url == "https://github.com/example-org/sample-app/pull/101")
        #expect(detected.featureID == "demo-session-continuity")
        #expect(detected.provenance.nativeSessionID == "demo-session-builder")
        #expect(detected.provenance.assignmentID == "demo-builder")
        #expect(detected.provenanceSummary == "Detected from saved evidence")
        #expect(detected.isPullRequest)
        #expect(!detected.hidden)
        #expect(decoded.pullRequestLinks.map(\.id) == ["demo-link-pr-101", "demo-link-pr-7"])
        #expect(decoded.otherLinks.map(\.id) == ["demo-link-share"])
        #expect(decoded.otherLinks.first?.hostLabel == "share.example.test:8443")
    }

    @Test("A server that omits links decodes safely without inventing rows")
    func omittedLinksDecodeEmpty() throws {
        let original = FirstMateDemo.features(step: 0)[0]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "links")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: data)
        #expect(decoded.links.isEmpty)
        #expect(!decoded.includesLinks)
        #expect(decoded.documents == original.documents)
    }

    @Test("Absolute HTTP(S) validation rejects unsafe values and preserves meaningful components")
    func urlValidation() {
        #expect(FirstMateLinkURL.validated("https://github.com/example-org/sample-app/pull/101") != nil)
        #expect(FirstMateLinkURL.validated("http://127.0.0.1:8443/review?tab=links#top") != nil)
        let share = "https://share.example.test:8443/review/session?tab=links#evidence"
        #expect(FirstMateLinkURL.validated(share)?.absoluteString == share)
        for invalid in [
            "",
            "ftp://example.test/file",
            "file:///tmp/review",
            "javascript:alert(1)",
            "https://user:secret@example.test/review",
            "https://example.test/has space",
            "https://example.test:0/review",
            "https://example.test:70000/review",
            String(repeating: "a", count: 5000),
        ] {
            #expect(FirstMateLinkURL.validated(invalid) == nil)
        }
    }

    @Test("Pull request canonicalization deduplicates draft and ready references")
    func pullRequestCanonicalization() throws {
        let files = try #require(FirstMateLinkClassifier.normalize(url: "https://github.com/example-org/sample-app/pull/101/files#diff-1"))
        #expect(files.url == "https://github.com/example-org/sample-app/pull/101")
        #expect(files.kind == "pull_request")
        #expect(files.pullRequest?.owner == "example-org")
        #expect(files.pullRequest?.repo == "sample-app")
        #expect(files.pullRequest?.number == 101)
        let draft = try #require(FirstMateLinkClassifier.normalize(url: "http://github.com/example-org/sample-app/pull/101"))
        #expect(draft.url == files.url)
        let conversation = try #require(FirstMateLinkClassifier.normalize(url: "https://github.com/example-org/sample-app/pull/101?notification_referrer_id=1"))
        #expect(conversation.url == files.url)
        #expect(files.title == "example-org/sample-app #101")
    }

    @Test("General and explicitly classified links preserve their exact destination")
    func generalAndEnterpriseLinks() throws {
        let share = try #require(FirstMateLinkClassifier.normalize(url: "https://share.example.test:8443/review/session-continuity?tab=links#evidence"))
        #expect(share.kind == "link")
        #expect(share.url == "https://share.example.test:8443/review/session-continuity?tab=links#evidence")
        #expect(share.title == "share.example.test")
        let enterprise = try #require(FirstMateLinkClassifier.normalize(url: "https://github.example.test/acme/widget/pull/9", kind: "pull_request"))
        #expect(enterprise.kind == "pull_request")
        #expect(enterprise.url == "https://github.example.test/acme/widget/pull/9")
        #expect(enterprise.title == "github.example.test")
        #expect(FirstMateLinkClassifier.normalize(url: "not a url") == nil)
        #expect(FirstMateLinkClassifier.normalize(url: "https://example.test/x", kind: "unknown") == nil)
        #expect(FirstMateLinkClassifier.normalize(url: "https://example.test/x", title: String(repeating: "t", count: 301)) == nil)
    }

    @Test("Saving retries with the same request identity and hides reversibly")
    func saveRetryAndVisibility() async throws {
        let client = FirstMateLinksTestClient(features: FirstMateDemo.features(step: 0))
        await client.failNextSave(1)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        _ = store.acquireControlLease(available: true)
        await store.refresh()
        let first = FirstMateDemo.features(step: 0)[0]
        store.receive(first)
        store.select(first.feature.id)
        #expect(store.linksSupported)
        #expect(store.canManageLinks)
        #expect(store.snapshot?.links.count == 3)

        let context = store.operationContext
        let draft = FirstMateLinkDraft(url: "https://share.example.test:9443/check?tab=links#top", title: "Review share")
        #expect(await store.saveLink(draft, expectedContext: context) == false)
        #expect(store.linkMutationError != nil)
        #expect(store.snapshot?.links.count == 3)
        #expect(await store.saveLink(draft, expectedContext: context) == true)
        #expect(store.linkMutationError == nil)
        let saved = try #require(store.snapshot?.links.first { $0.url == "https://share.example.test:9443/check?tab=links#top" })
        #expect(saved.kind == "link")
        #expect(saved.title == "Review share")
        #expect(saved.titleSource == "user")

        #expect(await store.saveLink(FirstMateLinkDraft(url: "ftp://example.test/review"), expectedContext: context) == false)
        #expect(store.linkMutationError?.contains("http") == true)
        #expect(store.linkMutationError?.contains("first-mate-links-v1") == false)

        let requests = await client.saveRequests
        #expect(requests.count == 2)
        #expect(requests[0].requestID == requests[1].requestID)
        #expect(requests[0].featureID == "demo-session-continuity")
        #expect(requests[0].kind == nil)

        let pullRequest = try #require(store.snapshot?.pullRequestLinks.first)
        #expect(await store.setLinkHidden(pullRequest.id, hidden: true, expectedContext: store.operationContext))
        #expect(!(store.snapshot?.pullRequestLinks.contains { $0.id == pullRequest.id } ?? true))
        #expect(store.snapshot?.hiddenLinks.map(\.id) == [pullRequest.id])
        #expect(await store.setLinkHidden(pullRequest.id, hidden: false, expectedContext: store.operationContext))
        let visibleAfterRestore = store.snapshot?.pullRequestLinks.contains { $0.id == pullRequest.id } ?? false
        #expect(visibleAfterRestore)
        let visibilityRequests = await client.visibilityRequests
        #expect(visibilityRequests.count == 2)
        #expect(visibilityRequests[0].hidden)
        #expect(visibilityRequests[1].hidden == false)
    }

    @Test("A companion without the links capability rejects saves with upgrade guidance")
    func capabilityGating() async throws {
        let client = FirstMateLinksTestClient(features: FirstMateDemo.features(step: 0), supportsLinks: false)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        _ = store.acquireControlLease(available: true)
        await store.refresh()
        #expect(!store.linksSupported)
        #expect(!store.canManageLinks)
        let context = store.operationContext
        #expect(await store.saveLink(FirstMateLinkDraft(url: "https://share.example.test/review"), expectedContext: context) == false)
        #expect(store.linkMutationError?.contains("first-mate-links-v1") == true)
        #expect(await client.saveRequests.isEmpty)
        #expect(await client.visibilityRequests.isEmpty)
    }

    @Test("Link mutations require the workspace control lease")
    func controlLeaseGating() async throws {
        let client = FirstMateLinksTestClient(features: FirstMateDemo.features(step: 0))
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        store.receive(FirstMateDemo.features(step: 0)[0])
        store.select("demo-session-continuity")
        #expect(store.linksSupported)
        #expect(!store.canMutateLinks)
        #expect(await store.saveLink(FirstMateLinkDraft(url: "https://share.example.test/review"), expectedContext: store.operationContext) == false)
        #expect(store.linkMutationError?.contains("control") == true)
        #expect(await client.saveRequests.isEmpty)
        _ = store.acquireControlLease(available: true)
        #expect(store.canMutateLinks)
        #expect(await store.saveLink(FirstMateLinkDraft(url: "https://share.example.test/review"), expectedContext: store.operationContext))
    }

    @Test("Delayed link responses cannot reach another feature or host")
    func delayedResponseFencing() async throws {
        let client = FirstMateLinksTestClient(features: FirstMateDemo.features(step: 0))
        await client.holdSave()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        _ = store.acquireControlLease(available: true)
        await store.refresh()
        let firstID = "demo-session-continuity"
        let secondID = "demo-search"
        store.receive(FirstMateDemo.features(step: 0)[0])
        store.select(firstID)
        let context = store.operationContext
        let draft = FirstMateLinkDraft(url: "https://share.example.test:9443/late?tab=links#top", title: "Late share")
        let saving = Task { await store.saveLink(draft, expectedContext: context) }
        while !(await client.isWaitingForSave) { await Task.yield() }
        store.select(secondID)
        await client.releaseSave()
        #expect(await saving.value == true)
        #expect(store.snapshot?.feature.id == secondID)
        #expect(store.snapshot?.links.isEmpty == true)
        #expect(store.snapshots[secondID]?.links.isEmpty == true)
        #expect(store.snapshots[firstID]?.links.map(\.url).contains("https://share.example.test:9443/late?tab=links#top") == true)
        #expect(store.linkMutationError == nil)

        // A captured context from this store never reaches a replacement host,
        // even when both stores have the same feature ID.
        let replacement = FirstMateLinksTestClient(features: FirstMateDemo.features(step: 0))
        let otherStore = FirstMateStore()
        otherStore.configure(client: replacement, demo: false)
        _ = otherStore.acquireControlLease(available: true)
        await otherStore.refresh()
        otherStore.select(firstID)
        #expect(await otherStore.saveLink(draft, expectedContext: context) == false)
        #expect(await replacement.saveRequests.isEmpty)
    }

    @Test("Partial acknowledgements and old-server responses preserve cached links")
    func partialAcknowledgementsPreserveLinks() throws {
        let store = FirstMateStore()
        let original = FirstMateDemo.features(step: 0)[0]
        store.receive(original)
        store.select(original.feature.id)

        var feature = original.feature
        feature.status = "paused"
        let featureObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feature))
        let acknowledgmentData = try JSONSerialization.data(withJSONObject: ["ok": true, "feature": featureObject])
        let acknowledgment = try JSONDecoder().decode(FirstMateSnapshot.self, from: acknowledgmentData)
        #expect(!acknowledgment.hasDetails)
        store.receive(acknowledgment)
        #expect(store.snapshot?.links == original.links)
        #expect(store.snapshot?.feature.status == "paused")

        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacyObject.removeValue(forKey: "links")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(FirstMateSnapshot.self, from: legacyData)
        #expect(!legacy.includesLinks)
        store.receive(legacy)
        #expect(store.snapshot?.links == original.links)
    }

    @Test("Saving a link never changes documents, workflow identity, or archive state")
    func savingPreservesRecords() async throws {
        let client = FirstMateLinksTestClient(features: FirstMateDemo.features(step: 0))
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        _ = store.acquireControlLease(available: true)
        await store.refresh()
        let first = FirstMateDemo.features(step: 0)[0]
        store.receive(first)
        store.select(first.feature.id)
        let before = try #require(store.snapshot)
        let draft = FirstMateLinkDraft(url: "https://github.com/example-org/herdr-tools/pull/12", title: "Second PR")
        #expect(await store.saveLink(draft, expectedContext: store.operationContext))
        let after = try #require(store.snapshot)
        #expect(after.documents == before.documents)
        #expect(after.assignments == before.assignments)
        #expect(after.visits == before.visits)
        #expect(after.feature.status == before.feature.status)
        #expect(after.feature.revision == before.feature.revision)
        #expect(after.pullRequestLinks.contains { $0.url == "https://github.com/example-org/herdr-tools/pull/12" })
        #expect(!after.documents.contains { $0.id.hasPrefix("example-org") })
    }

    @Test("A feature with no links presents an empty, saveable collection")
    func emptyFeature() {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let second = FirstMateDemo.features(step: 0)[1]
        store.receive(second)
        store.select(second.feature.id)
        #expect(store.snapshot?.links.isEmpty == true)
        #expect(store.snapshot?.pullRequestLinks.isEmpty == true)
        #expect(store.snapshot?.otherLinks.isEmpty == true)
        #expect(store.canManageLinks)
    }

    @Test("Capability decoding recognizes first-mate-links-v1")
    func capabilityDecoding() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "capabilities": ["first-mate-v1", "first-mate-links-v1"],
        ])
        let capabilities = try JSONDecoder().decode(FirstMateCapabilities.self, from: data)
        #expect(capabilities.supportsLinks)
        let old = try JSONDecoder().decode(FirstMateCapabilities.self, from: JSONSerialization.data(withJSONObject: ["ok": true, "capabilities": ["first-mate-v1"]]))
        #expect(!old.supportsLinks)
    }
}

private actor FirstMateLinksTestClient: FirstMateClient {
    private var features: [String: FirstMateSnapshot]
    private let supportsLinksCapability: Bool
    var saveFailuresRemaining = 0
    var holdNextSave = false
    private(set) var saveRequests: [(featureID: String, url: String, title: String?, kind: String?, requestID: String)] = []
    private(set) var visibilityRequests: [(featureID: String, linkID: String, hidden: Bool, requestID: String)] = []
    private var saveContinuation: CheckedContinuation<Void, Never>?
    var isWaitingForSave: Bool { saveContinuation != nil }

    init(features: [FirstMateSnapshot], supportsLinks: Bool = true) {
        self.features = Dictionary(uniqueKeysWithValues: features.map { ($0.feature.id, $0) })
        supportsLinksCapability = supportsLinks
    }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func holdSave() { holdNextSave = true }

    func failNextSave(_ count: Int) { saveFailuresRemaining = count }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: supportsLinksCapability ? ["first-mate-v1", "first-mate-links-v1"] : ["first-mate-v1"])
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        .init(ok: true, features: features.values.map(\.feature).sorted { $0.id < $1.id })
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard let snapshot = features[id] else { throw APIError.invalidResponse }
        return snapshot
    }

    func saveFirstMateLink(featureID: String, url: String, title: String?, kind: String?, requestID: String) async throws -> FirstMateLinkMutationResponse {
        saveRequests.append((featureID, url, title, kind, requestID))
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        if holdNextSave {
            holdNextSave = false
            await withCheckedContinuation { saveContinuation = $0 }
        }
        guard var snapshot = features[featureID] else { throw APIError.invalidResponse }
        let normalized = FirstMateLinkClassifier.normalize(url: url, title: title ?? "", kind: kind)
        let canonical = normalized?.url ?? url
        var savedLink: FirstMateLink?
        if let existing = snapshot.links.first(where: { $0.url == canonical }) {
            savedLink = existing
        } else {
            let link = FirstMateLink(
                id: "saved-\(snapshot.links.count + 1)",
                featureID: featureID,
                url: canonical,
                kind: normalized?.kind ?? "link",
                title: normalized?.title ?? url,
                titleSource: title?.isEmpty == false ? "user" : "",
                source: "user",
                provenance: .init(),
                hidden: false,
                createdAt: "2030-01-01T13:00:00Z",
                updatedAt: "2030-01-01T13:00:00Z"
            )
            snapshot.links.append(link)
            features[featureID] = snapshot
            savedLink = link
        }
        return .init(ok: true, link: savedLink, snapshot: snapshot)
    }

    func setFirstMateLinkVisibility(featureID: String, linkID: String, hidden: Bool, requestID: String) async throws -> FirstMateLinkMutationResponse {
        visibilityRequests.append((featureID, linkID, hidden, requestID))
        guard var snapshot = features[featureID],
              let index = snapshot.links.firstIndex(where: { $0.id == linkID && $0.featureID == featureID }) else {
            throw APIError.server(status: 404, message: "First Mate record not found")
        }
        snapshot.links[index].hidden = hidden
        features[featureID] = snapshot
        return .init(ok: true, link: snapshot.links[index], snapshot: snapshot)
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        throw APIError.invalidResponse
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        throw APIError.invalidResponse
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        throw APIError.invalidResponse
    }
}
