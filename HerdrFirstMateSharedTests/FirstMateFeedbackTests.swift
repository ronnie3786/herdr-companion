import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate response feedback", .serialized)
@MainActor
struct FirstMateFeedbackTests {
    @Test("The requested starting reasons and eligibility policy stay exact")
    func defaultsAndEligibility() {
        let categories = FirstMateFeedbackDefaults.categories
        #expect(categories.map(\.id) == ["too_long", "unnecessary_message", "incorrect_assumption"])
        #expect(categories.map(\.label) == [
            "Longer than it needed to be",
            "Unnecessary message",
            "Incorrect assumption",
        ])

        for status in ["done", "delivered", "completed", "complete"] {
            #expect(FirstMateFeedbackEligibility.isEligible(role: "assistant", status: status, text: "A response"))
        }
        let ineligible: [(String, String, String)] = [
            ("assistant", "pending", "A response"),
            ("assistant", "queued", "A response"),
            ("assistant", "processing", "A response"),
            ("human", "done", "A response"),
            ("user", "done", "A response"),
            ("system", "done", "A response"),
            ("assistant", "done", "  \n\t "),
        ]
        for (role, status, text) in ineligible {
            #expect(!FirstMateFeedbackEligibility.isEligible(role: role, status: status, text: text))
        }

        var messages = [
            FirstMateMessage(id: "pending", featureID: "f", role: "assistant", text: "Pending", status: "pending", createdAt: "now"),
            FirstMateMessage(id: "done", featureID: "f", role: "assistant", text: "Done", status: "done", createdAt: "now"),
            FirstMateMessage(id: "human", featureID: "f", role: "human", text: "Human", status: "done", createdAt: "now"),
            FirstMateMessage(id: "empty", featureID: "f", role: "assistant", text: "", status: "complete", createdAt: "now"),
        ]
        messages.append(FirstMateMessage(id: "delivered", featureID: "f", role: "assistant", text: "Delivered", status: "delivered", createdAt: "now"))
        #expect(FirstMateFeedbackEligibility.eligibleMessageIDs(in: messages) == ["done", "delivered"])
    }

    @Test("The capability is additive and a legacy server receives no feedback calls")
    func legacyCapabilityReceivesNothing() async throws {
        let absent = try JSONDecoder().decode(
            FirstMateCapabilities.self,
            from: Data(#"{"ok":true,"capabilities":["first-mate-v1","first-mate-archive-v1"]}"#.utf8)
        )
        #expect(!absent.supportsFeedback)
        let present = try JSONDecoder().decode(
            FirstMateCapabilities.self,
            from: Data(#"{"ok":true,"capabilities":["first-mate-v1","first-mate-feedback-v1"]}"#.utf8)
        )
        #expect(present.supportsFeedback)

        let client = FirstMateFeedbackTestClient(supported: false)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        #expect(!store.feedbackSupported)
        let context = store.operationContext
        await store.loadFeedbackCategories(expectedContext: context)
        await store.loadFeedback(expectedContext: context)
        let saved = await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down),
            messageID: "demo-mate-0",
            expectedContext: context
        )
        let added = await store.addFeedbackCategory(label: "Synthetic reason", expectedContext: context)
        #expect(!saved)
        #expect(added == nil)
        #expect(await client.categoryCallCount == 0)
        #expect(await client.categoryRequests.isEmpty)
        #expect(await client.feedbackCallCount == 0)
        #expect(await client.saveCallCount == 0)
        // Ordinary chat state stays healthy; only the feedback surface upgrades.
        #expect(store.error == nil)
        #expect(store.features.count == 2)
        #expect(store.feedbackSaveError(featureID: "demo-session-continuity", messageID: "demo-mate-0") != nil)
    }

    @Test("Synthetic demo feedback reuses the server's defaults and mutations without a client")
    func syntheticDemo() async throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        #expect(store.feedbackSupported)
        #expect(store.feedbackCategoriesLoaded)
        #expect(store.feedbackCategories.map(\.id) == FirstMateFeedbackDefaults.categories.map(\.id))
        #expect(store.feedbackCategories.map(\.label) == FirstMateFeedbackDefaults.categories.map(\.label))
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext

        let firstDraft = FirstMateFeedbackDraft(
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.tooLongID, FirstMateFeedbackDefaults.incorrectAssumptionID],
            comment: "Long.\nTrim it — synthetic ✓"
        )
        #expect(await store.saveFeedback(firstDraft, messageID: "demo-mate-0", expectedContext: context))
        let first = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(first.rating == .down)
        #expect(first.categoryIDs == firstDraft.categoryIDs)
        #expect(first.comment == "Long.\nTrim it — synthetic ✓")
        #expect(first.revision == 1)
        let messageText = try #require(store.snapshot?.messages.first { $0.id == "demo-mate-0" }?.text)
        #expect(first.provenance.responseText == messageText)
        #expect(first.provenance.sessionProvenance == "unavailable")

        // Changing the rating sends no reasons, and the saved revision advances.
        #expect(await store.rateFeedback(.up, messageID: "demo-mate-0", expectedContext: context))
        let second = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(second.rating == .up)
        #expect(second.categoryIDs.isEmpty)
        #expect(second.comment.isEmpty)
        #expect(second.revision == 2)
        #expect(second.createdAt == first.createdAt)

        // Removing the rating keeps the record as an explicit cleared revision.
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: nil),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.rating == nil)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.revision == 3)
    }

    @Test("Custom demo reasons deduplicate case-insensitively and stay in memory")
    func syntheticCustomCategories() async throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let context = store.operationContext

        let created = try #require(await store.addFeedbackCategory(
            label: "  Needs   more evidence ",
            expectedContext: context
        ))
        #expect(created.label == "Needs more evidence")
        let reused = try #require(await store.addFeedbackCategory(
            label: "NEEDS MORE EVIDENCE",
            expectedContext: context
        ))
        #expect(reused.id == created.id)
        #expect(store.feedbackCategories.filter { $0.id == created.id }.count == 1)

        let featureID = try #require(store.selectedFeatureID)
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down, categoryIDs: [created.id]),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.categoryIDs == [created.id])
    }

    @Test("Reconfiguration clears host feedback and rejects stale host identities")
    func hostIsolation() async throws {
        let first = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: first, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let firstContext = store.operationContext
        await store.loadFeedbackCategories(expectedContext: firstContext)
        #expect(store.feedbackCategoriesLoaded)
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down, categoryIDs: [FirstMateFeedbackDefaults.unnecessaryMessageID], comment: "First host"),
            messageID: "demo-mate-0",
            expectedContext: firstContext
        ))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "First host")

        let second = FirstMateFeedbackTestClient()
        store.configure(client: second, demo: false)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0") == nil)
        #expect(store.feedbackCategories.isEmpty)
        #expect(!store.feedbackCategoriesLoaded)
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0") == FirstMateFeedbackDraft())

        await store.refresh()
        _ = store.acquireControlLease(available: true)
        // The previous host's captured context cannot write to this replacement.
        #expect(!(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .up),
            messageID: "demo-mate-0",
            expectedContext: firstContext
        )))
        #expect(await second.saveCallCount == 0)
        #expect(await first.saveCallCount == 1)

        let secondContext = store.operationContext
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .up),
            messageID: "demo-mate-0",
            expectedContext: secondContext
        ))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.rating == .up)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment.isEmpty == true)
    }

    @Test("A delayed load updates only its original feature's cache")
    func delayedFeatureLoadIsolation() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let firstFeatureID = try #require(store.selectedFeatureID)
        let firstContext = store.operationContext
        let secondFeatureID = try #require(store.features.first { $0.id != firstFeatureID }?.id)

        await client.seedRecord(syntheticFeedbackRecord(featureID: firstFeatureID, messageID: "demo-mate-0", comment: "First feature"))
        await client.holdNextLoad()
        let loading = Task { await store.loadFeedback(expectedContext: firstContext) }
        while !(await client.isWaitingForLoad) { await Task.yield() }

        store.select(secondFeatureID)
        await client.releaseLoad()
        await loading.value

        #expect(store.feedback(for: firstFeatureID, messageID: "demo-mate-0")?.comment == "First feature")
        #expect(store.feedback(for: secondFeatureID, messageID: "demo-search-welcome") == nil)
        #expect(store.feedbackError(for: firstFeatureID) == nil)
        #expect(store.selectedFeatureID == secondFeatureID)
    }

    @Test("A delayed lower revision cannot replace a newer accepted save")
    func delayedLowerRevisionCannotWin() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext

        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            comment: "Delayed old revision",
            revision: 1
        ))
        await client.holdNextLoad()
        let loading = Task { await store.loadFeedback(expectedContext: context) }
        while !(await client.isWaitingForLoad) { await Task.yield() }

        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down, comment: "Newer saved revision"),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        await client.releaseLoad()
        await loading.value

        let record = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(record.revision == 2)
        #expect(record.comment == "Newer saved revision")
    }

    @Test("A transient capability outage preserves a failed save's draft and retry path")
    func transientCapabilityOutagePreservesDraft() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.failSaves(count: 1)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        #expect(store.feedbackCapability == .supported)
        #expect(await store.loadFeedback(expectedContext: context))

        let draft = FirstMateFeedbackDraft(
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.tooLongID],
            comment: "Synthetic outage draft"
        )
        #expect(!(await store.saveFeedback(draft, messageID: "demo-mate-0", expectedContext: context)))
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0").comment == "Synthetic outage draft")

        // The workspace's periodic refresh now fails at the capability route.
        // That is temporary unavailability, never a confirmed old server, so
        // the editor keeps the failed draft, the save error, and a retry path
        // and does not swap in server-upgrade guidance.
        await client.failCapabilities(count: 1)
        await store.refresh()
        #expect(store.feedbackCapability == .unknown)
        #expect(!store.feedbackSupported)
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)
        let preserved = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(preserved.comment == "Synthetic outage draft")
        #expect(preserved.categoryIDs == [FirstMateFeedbackDefaults.tooLongID])
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0") == nil)
        #expect(store.error == nil)

#if os(macOS)
        let target = FirstMateFeedbackEditorTarget(
            featureID: featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic answer",
            expectedContext: context
        )
        var state = FirstMateFeedbackEditorState.make(store: store, target: target)
        #expect(state.isTargetAlive)
        #expect(state.showsConnectionNotice)
        #expect(!state.showsUpgradeNotice)
        #expect(!state.canSave)
        // Local refinement stays possible while the server write is unavailable.
        #expect(state.isEditable)
        #expect(state.saveErrorMessage != nil)
        #expect(state.draft.comment == "Synthetic outage draft")
#endif

        // The connection recovers; the same draft retries under its original
        // request identity and the editor becomes writable again.
        await store.refresh()
        #expect(store.feedbackCapability == .supported)
        let recovered = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(recovered.comment == "Synthetic outage draft")
#if os(macOS)
        state = FirstMateFeedbackEditorState.make(store: store, target: target)
        #expect(!state.showsConnectionNotice)
        #expect(state.canSave)
        #expect(state.draft.comment == "Synthetic outage draft")
#endif
        #expect(await store.saveFeedback(recovered, messageID: "demo-mate-0", expectedContext: context))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "Synthetic outage draft")
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") == nil)
        let requests = await client.saveRequests
        #expect(requests.count == 2)
        #expect(requests[0].requestID == requests[1].requestID)
    }

    @Test("A stale server revision keeps the known rating and typed draft")
    func staleRevisionKeepsKnownState() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.setEnforceRevisions(true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext

        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.tooLongID],
            comment: "Original",
            revision: 1
        ))
        await store.loadFeedback(expectedContext: context)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.revision == 1)

        // Another authorized client advances the companion to revision 2.
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.unnecessaryMessageID],
            comment: "Changed elsewhere",
            revision: 2
        ))
        let draft = FirstMateFeedbackDraft(
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.incorrectAssumptionID],
            comment: "My retry"
        )
        #expect(!(await store.saveFeedback(draft, messageID: "demo-mate-0", expectedContext: context)))
        let known = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(known.revision == 1)
        #expect(known.comment == "Original")
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0") == draft.withBaseRevision(1))
        #expect(store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)

        // Reloading the newer revision makes an explicit retry safe and distinct.
        await store.loadFeedback(expectedContext: context)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.revision == 2)
        #expect(await store.resolveFeedbackConflict(messageID: "demo-mate-0", expectedContext: context))
        #expect(!store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        #expect(await store.saveFeedback(
            store.feedbackDraft(for: featureID, messageID: "demo-mate-0"),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        let saved = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(saved.revision == 3)
        #expect(saved.comment == "My retry")
        let requests = await client.saveRequests
        #expect(requests.count == 2)
        #expect(requests[0].expectedRevision == 1)
        #expect(requests[1].expectedRevision == 2)
        #expect(requests[0].requestID != requests[1].requestID)
    }

    @Test("A failed save reuses its request identity and preserves the draft")
    func failedSaveRetryIdentity() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.failSaves(count: 1)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        let draft = FirstMateFeedbackDraft(
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.unnecessaryMessageID],
            comment: "Synthetic retry"
        )

        #expect(!(await store.saveFeedback(draft, messageID: "demo-mate-0", expectedContext: context)))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0") == nil)
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0") == draft.withBaseRevision(0))
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)
        #expect(store.error == nil)

        #expect(await store.saveFeedback(draft, messageID: "demo-mate-0", expectedContext: context))
        let requests = await client.saveRequests
        #expect(requests.count == 2)
        #expect(requests[0].requestID == requests[1].requestID)
        #expect(requests[0].expectedRevision == 0)
        #expect(requests[1].expectedRevision == 0)
        let saved = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(saved.comment == "Synthetic retry")
        #expect(saved.revision == 1)
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") == nil)
    }

    @Test("An edited draft after a failure never replays the old request identity")
    func editedRetryUsesFreshIdentity() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.failSaves(count: 1)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let context = store.operationContext

        #expect(!(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down, comment: "First attempt"),
            messageID: "demo-mate-0",
            expectedContext: context
        )))
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down, comment: "Edited attempt"),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        let requests = await client.saveRequests
        #expect(requests.count == 2)
        #expect(requests[0].requestID != requests[1].requestID)
        #expect(requests[1].comment == "Edited attempt")
    }

    @Test("Writes revalidate control availability while reads remain available")
    func controlRevalidation() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext

        #expect(!store.controlAvailable)
        let readOnlyDraft = FirstMateFeedbackDraft(rating: .up)
        #expect(!(await store.saveFeedback(
            readOnlyDraft,
            messageID: "demo-mate-0",
            expectedContext: context
        )))
        #expect(await client.saveCallCount == 0)
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0") == readOnlyDraft.withBaseRevision(0))

        await store.loadFeedback(expectedContext: context)
        #expect(await client.feedbackCallCount == 1)
        #expect(store.feedbackError(for: featureID) == nil)

        let lease = store.acquireControlLease(available: true)
        #expect(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .up),
            messageID: "demo-mate-0",
            expectedContext: context
        ))
        #expect(await client.saveCallCount == 1)
        store.releaseControlLease(lease)
        #expect(!store.controlAvailable)
    }

    @Test("Mismatched feedback identities are rejected without changing the cache")
    func mismatchedIdentities() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext

        await client.setMismatchedFeedbackFeature(true)
        await store.loadFeedback(expectedContext: context)
        #expect(store.feedbackError(for: featureID) != nil)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0") == nil)

        await client.setMismatchedFeedbackFeature(false)
        await client.setMismatchedSaveIdentity(true)
        #expect(!(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: .down),
            messageID: "demo-mate-0",
            expectedContext: context
        )))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0") == nil)
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)
    }

    @Test("A failed feedback load keeps known ratings and never breaks chat refresh")
    func failedLoadKeepsKnownState() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            comment: "Known rating",
            revision: 1
        ))
        await store.loadFeedback(expectedContext: context)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "Known rating")
        let snapshotBefore = store.snapshot

        await client.failLoads(count: 1)
        await store.loadFeedback(expectedContext: context)
        #expect(store.feedbackError(for: featureID) != nil)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "Known rating")

        await store.refresh()
        #expect(store.error == nil)
        #expect(store.snapshot?.feature.id == snapshotBefore?.feature.id)
        #expect(store.snapshot?.messages == snapshotBefore?.messages)
    }

    @Test("Category creation deduplicates labels and a failure keeps the catalog")
    func categoryCreation() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let context = store.operationContext
        // The chat surface and editor load the companion's catalog before a
        // custom reason can be added; the local cache then reflects defaults
        // plus additions instead of only the response's created category.
        await store.loadFeedbackCategories(expectedContext: context)
        #expect(store.feedbackCategoriesLoaded)
        #expect(store.feedbackCategories.map(\.id) == FirstMateFeedbackDefaults.categories.map(\.id))

        let created = try #require(await store.addFeedbackCategory(
            label: "  Needs   more evidence ",
            expectedContext: context
        ))
        #expect(created.label == "Needs more evidence")
        let reused = try #require(await store.addFeedbackCategory(
            label: "NEEDS MORE EVIDENCE",
            expectedContext: context
        ))
        #expect(reused.id == created.id)
        #expect(store.feedbackCategories.filter { $0.id == created.id }.count == 1)
        #expect(store.feedbackCategories.count == FirstMateFeedbackDefaults.categories.count + 1)

        await client.failCategories(count: 1)
        let failed = await store.addFeedbackCategory(label: "Needs proof", expectedContext: context)
        #expect(failed == nil)
        #expect(store.feedbackCategoriesError != nil)
        #expect(!store.feedbackCategories.contains { $0.label == "Needs proof" })
        #expect(store.feedbackCategories.count == FirstMateFeedbackDefaults.categories.count + 1)

        #expect(await store.addFeedbackCategory(label: "line\nbreak", expectedContext: context) == nil)
        #expect(store.feedbackCategories.count == FirstMateFeedbackDefaults.categories.count + 1)
    }

    @Test("An editor draft is never seeded before the record loads and prefills from its revision")
    func editorDraftWaitsForLoadedRecord() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.tooLongID],
            comment: "Saved explanation",
            revision: 1
        ))
        await client.holdNextLoad()
        let loading = Task { await store.loadFeedback(expectedContext: context) }
        while !(await client.isWaitingForLoad) { await Task.yield() }

        #expect(!store.hasLoadedFeedback(for: featureID))
        // The empty cache must not seed a blank draft that would later win over
        // the loaded record and silently clear its reasons and note.
        store.setFeedbackDraft(
            FirstMateFeedbackDraft(rating: .down),
            for: featureID,
            messageID: "demo-mate-0",
            expectedContext: context
        )
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0") == FirstMateFeedbackDraft())

        await client.releaseLoad()
        #expect(await loading.value)
        #expect(store.hasLoadedFeedback(for: featureID))
        let prefilled = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(prefilled.categoryIDs == [FirstMateFeedbackDefaults.tooLongID])
        #expect(prefilled.comment == "Saved explanation")
        #expect(prefilled.baseRevision == 1)

        var edited = prefilled
        edited.comment = "Saved explanation, edited"
        #expect(await store.saveFeedback(edited, messageID: "demo-mate-0", expectedContext: context))
        let saved = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(saved.categoryIDs == [FirstMateFeedbackDefaults.tooLongID])
        #expect(saved.comment == "Saved explanation, edited")
        #expect(saved.revision == 2)
    }

    @Test("A refresh during an edit keeps the pinned revision until an explicit conflict resolution")
    func refreshDuringEditCannotSilentlyRebase() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.setEnforceRevisions(true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.tooLongID],
            comment: "Original",
            revision: 1
        ))
        #expect(await store.loadFeedback(expectedContext: context))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.revision == 1)

        var draft = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(draft.baseRevision == 1)
        draft.comment = "My in-progress edit"
        store.setFeedbackDraft(draft, for: featureID, messageID: "demo-mate-0", expectedContext: context)

        // Another client advances the record; a delayed refresh delivers it
        // while the editor is still open.
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.unnecessaryMessageID],
            comment: "Changed elsewhere",
            revision: 2
        ))
        await client.holdNextLoad()
        let loading = Task { await store.loadFeedback(expectedContext: context) }
        while !(await client.isWaitingForLoad) { await Task.yield() }
        await client.releaseLoad()
        #expect(await loading.value)

        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "Changed elsewhere")
        let pinned = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(pinned.baseRevision == 1)
        #expect(pinned.comment == "My in-progress edit")

        // Saving from the pinned draft is rejected instead of silently clearing
        // the newer reasons, and the conflict is recorded for recovery.
        #expect(!(await store.saveFeedback(pinned, messageID: "demo-mate-0", expectedContext: context)))
        #expect(store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "Changed elsewhere")

        #expect(await store.resolveFeedbackConflict(messageID: "demo-mate-0", expectedContext: context))
        #expect(!store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        let rebased = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(rebased.baseRevision == 2)
        #expect(rebased.comment == "My in-progress edit")
        #expect(await store.saveFeedback(rebased, messageID: "demo-mate-0", expectedContext: context))
        let saved = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(saved.revision == 3)
        #expect(saved.comment == "My in-progress edit")
        #expect(saved.categoryIDs == [FirstMateFeedbackDefaults.tooLongID])

        let requests = await client.saveRequests
        #expect(requests.map(\.expectedRevision) == [1, 2])
        #expect(requests[0].requestID != requests[1].requestID)
    }

    @Test("An empty loaded record pins revision zero so a delayed first rating conflicts")
    func emptyLoadedRecordPinsRevisionZero() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.setEnforceRevisions(true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext

        // A successful fetch that found no record pins the editor at zero, so
        // an emptied cache is never mistaken for "no revision yet".
        #expect(await store.loadFeedback(expectedContext: context))
        #expect(store.hasLoadedFeedback(for: featureID))
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0").baseRevision == 0)

        // A caller that supplies a fresh untyped struct inherits the zero pin
        // instead of silently losing it while the user edits.
        store.setFeedbackDraft(
            FirstMateFeedbackDraft(rating: .down, comment: "My in-progress edit"),
            for: featureID,
            messageID: "demo-mate-0",
            expectedContext: context
        )
        let typed = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(typed.baseRevision == 0)
        #expect(typed.comment == "My in-progress edit")

        // Another client creates the first rating while a delayed refresh is
        // in flight. The typed draft keeps its original zero pin.
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            comment: "Changed elsewhere",
            revision: 1
        ))
        await client.holdNextLoad()
        let loading = Task { await store.loadFeedback(expectedContext: context) }
        while !(await client.isWaitingForLoad) { await Task.yield() }
        await client.releaseLoad()
        #expect(await loading.value)

        let pinned = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(pinned.baseRevision == 0)
        #expect(pinned.comment == "My in-progress edit")
        #expect(!(await store.saveFeedback(pinned, messageID: "demo-mate-0", expectedContext: context)))
        #expect(store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "Changed elsewhere")
        var requests = await client.saveRequests
        #expect(requests.map(\.expectedRevision) == [0])

        // Only the explicit reload rebases the preserved draft for retry.
        #expect(await store.resolveFeedbackConflict(messageID: "demo-mate-0", expectedContext: context))
        let rebased = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(rebased.baseRevision == 1)
        #expect(rebased.comment == "My in-progress edit")
        #expect(await store.saveFeedback(rebased, messageID: "demo-mate-0", expectedContext: context))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.comment == "My in-progress edit")
        requests = await client.saveRequests
        #expect(requests.map(\.expectedRevision) == [0, 1])
    }

    @Test("Thumbs-up and Remove rating conflicts recover only through an explicit reload")
    func quickRatingConflictRecovery() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.setEnforceRevisions(true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            comment: "Original",
            revision: 1
        ))
        #expect(await store.loadFeedback(expectedContext: context))

        // Thumbs up while another client advanced the revision: the known
        // rating is unchanged and the attempted payload is preserved.
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .down,
            comment: "Changed elsewhere",
            revision: 2
        ))
        #expect(!(await store.rateFeedback(.up, messageID: "demo-mate-0", expectedContext: context)))
        #expect(store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.rating == .down)
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)

        #expect(await store.resolveFeedbackConflict(messageID: "demo-mate-0", expectedContext: context))
        let upDraft = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(upDraft.rating == .up)
        #expect(upDraft.baseRevision == 2)
        #expect(await store.saveFeedback(upDraft, messageID: "demo-mate-0", expectedContext: context))
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0")?.rating == .up)

        // Remove rating repeats the same recovery path with a nil rating.
        await client.seedRecord(syntheticFeedbackRecord(
            featureID: featureID,
            messageID: "demo-mate-0",
            rating: .up,
            comment: "",
            revision: 4
        ))
        #expect(!(await store.saveFeedback(
            FirstMateFeedbackDraft(rating: nil),
            messageID: "demo-mate-0",
            expectedContext: context
        )))
        #expect(store.feedbackConflict(featureID: featureID, messageID: "demo-mate-0"))
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0").rating == nil)

        #expect(await store.resolveFeedbackConflict(messageID: "demo-mate-0", expectedContext: context))
        let clearedDraft = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(clearedDraft.rating == nil)
        #expect(clearedDraft.baseRevision == 4)
        #expect(await store.saveFeedback(clearedDraft, messageID: "demo-mate-0", expectedContext: context))
        let cleared = try #require(store.feedback(for: featureID, messageID: "demo-mate-0"))
        #expect(cleared.rating == nil)
        #expect(cleared.revision == 5)
    }

    @Test("A save in flight freezes the draft and a failed held save preserves the submission")
    func saveInFlightFreezesEditsAndPreservesFailure() async throws {
        let client = FirstMateFeedbackTestClient()
        await client.holdNextSave(failingAfterRelease: true)
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        #expect(await store.loadFeedback(expectedContext: context))
        let submitted = FirstMateFeedbackDraft(
            rating: .down,
            categoryIDs: [FirstMateFeedbackDefaults.tooLongID],
            comment: "Submitted note\nline two"
        )
        let saving = Task { await store.saveFeedback(submitted, messageID: "demo-mate-0", expectedContext: context) }
        while !(await client.isWaitingForSave) { await Task.yield() }
        #expect(store.isSavingFeedback(featureID: featureID, messageID: "demo-mate-0"))
        #if os(macOS)
        let target = FirstMateFeedbackEditorTarget(
            featureID: featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic answer",
            expectedContext: context
        )
        let state = FirstMateFeedbackEditorState.make(store: store, target: target)
        #expect(state.isSaving)
        #expect(!state.isEditable)
        #expect(!state.canSave)
        #endif

        // A view task racing the submission cannot change the in-flight
        // payload or lose post-submit input silently.
        store.setFeedbackDraft(
            FirstMateFeedbackDraft(rating: .down, comment: "Late input"),
            for: featureID,
            messageID: "demo-mate-0",
            expectedContext: context
        )
        #expect(store.feedbackDraft(for: featureID, messageID: "demo-mate-0").comment == "Submitted note\nline two")

        await client.releaseSave()
        #expect(!(await saving.value))
        #expect(!store.isSavingFeedback(featureID: featureID, messageID: "demo-mate-0"))
        let preserved = store.feedbackDraft(for: featureID, messageID: "demo-mate-0")
        #expect(preserved.comment == "Submitted note\nline two")
        #expect(preserved.categoryIDs == [FirstMateFeedbackDefaults.tooLongID])
        #expect(preserved.baseRevision == 0)
        #expect(store.feedbackSaveError(featureID: featureID, messageID: "demo-mate-0") != nil)
        #expect(store.feedback(for: featureID, messageID: "demo-mate-0") == nil)
    }

    @Test("A delayed category read merges newer additions instead of replacing them")
    func delayedCategoryLoadMergesAdditions() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let context = store.operationContext

        await client.holdNextCategoryLoad()
        let loading = Task { await store.loadFeedbackCategories(expectedContext: context) }
        while !(await client.isWaitingForCategoryLoad) { await Task.yield() }
        #expect(store.isLoadingFeedbackCategories)
        #expect(!store.feedbackCategoriesLoaded)

        // Add completes before the older full fetch and must survive it.
        let created = try #require(await store.addFeedbackCategory(
            label: "Needs more evidence",
            expectedContext: context
        ))
        #expect(!store.feedbackCategoriesLoaded)
        #expect(store.feedbackCategories.contains { $0.id == created.id })

        await client.releaseCategoryLoad()
        #expect(await loading.value)
        #expect(store.feedbackCategoriesLoaded)
        #expect(Set(store.feedbackCategories.map(\.id)) == Set(FirstMateFeedbackDefaults.categories.map(\.id) + [created.id]))
        #expect(store.feedbackCategories.filter { $0.id == created.id }.count == 1)
    }

    @Test("A failed initial category load stays partial until a full fetch succeeds")
    func failedCategoryLoadStaysPartial() async throws {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let context = store.operationContext

        await client.failCategories(count: 1)
        #expect(!(await store.loadFeedbackCategories(expectedContext: context)))
        #expect(!store.feedbackCategoriesLoaded)
        #expect(store.feedbackCategoriesError != nil)

        // Receiving one created category is not a full catalog load.
        let created = try #require(await store.addFeedbackCategory(
            label: "Needs proof",
            expectedContext: context
        ))
        #expect(store.feedbackCategories.contains { $0.id == created.id })
        #expect(!store.feedbackCategoriesLoaded)

        #expect(await store.loadFeedbackCategories(expectedContext: context))
        #expect(store.feedbackCategoriesLoaded)
        #expect(store.feedbackCategoriesError == nil)
        #expect(Set(store.feedbackCategories.map(\.id)) == Set(FirstMateFeedbackDefaults.categories.map(\.id) + [created.id]))
    }

#if os(macOS)
    @Test("A held category completion cannot recreate a cancelled editor draft")
    func cancelledCategoryAddCannotResurrectDraft() async throws {
        let setup = try await heldCategorySetup()
        let target = FirstMateFeedbackEditorTarget(
            featureID: setup.featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic answer",
            expectedContext: setup.context
        )
        let session = FirstMateFeedbackEditorSession()
        let token = session.currentToken
        await setup.client.holdNextCategoryCreate()
        let adding = Task {
            await session.addCategory(
                label: "Needs more evidence",
                token: token,
                store: setup.store,
                target: target
            )
        }
        while !(await setup.client.isWaitingForCategoryCreate) { await Task.yield() }

        // Cancel discards and invalidates the editor while the write is held.
        session.invalidate()
        setup.store.discardFeedbackDraft(for: setup.featureID, messageID: "demo-mate-0")
        await setup.client.releaseCategoryCreate()
        #expect(!(await adding.value))

        // The confirmed reason stays in the companion catalog, but the
        // cancelled draft is not resurrected or preselected.
        #expect(setup.store.feedbackCategories.contains { $0.label == "Needs more evidence" })
        let draft = setup.store.feedbackDraft(for: setup.featureID, messageID: "demo-mate-0")
        #expect(draft.rating == .down)
        #expect(draft.categoryIDs.isEmpty)
        #expect(draft.comment.isEmpty)
        #expect(setup.store.feedback(for: setup.featureID, messageID: "demo-mate-0") == nil)
    }

    @Test("Switching features fences a held category completion from the previous feature")
    func featureSwitchFencesCategoryCompletion() async throws {
        let setup = try await heldCategorySetup()
        let target = FirstMateFeedbackEditorTarget(
            featureID: setup.featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic answer",
            expectedContext: setup.context
        )
        let session = FirstMateFeedbackEditorSession()
        let token = session.currentToken
        await setup.client.holdNextCategoryCreate()
        let adding = Task {
            await session.addCategory(
                label: "Needs more evidence",
                token: token,
                store: setup.store,
                target: target
            )
        }
        while !(await setup.client.isWaitingForCategoryCreate) { await Task.yield() }

        // The target feature is replaced before the held request completes.
        let otherFeatureID = try #require(setup.store.features.first { $0.id != setup.featureID }?.id)
        setup.store.select(otherFeatureID)
        setup.store.discardFeedbackDraft(for: setup.featureID, messageID: "demo-mate-0")
        await setup.client.releaseCategoryCreate()
        #expect(!(await adding.value))

        #expect(setup.store.selectedFeatureID == otherFeatureID)
        #expect(setup.store.feedbackCategories.contains { $0.label == "Needs more evidence" })
        #expect(setup.store.feedbackDraft(for: setup.featureID, messageID: "demo-mate-0").categoryIDs.isEmpty)
        #expect(setup.store.feedback(for: otherFeatureID, messageID: "demo-search-welcome") == nil)
    }

    @Test("A stale completion cannot mutate a reopened editor for the same response")
    func reopenedEditorIgnoresStaleCategoryCompletion() async throws {
        let setup = try await heldCategorySetup()
        let target = FirstMateFeedbackEditorTarget(
            featureID: setup.featureID,
            messageID: "demo-mate-0",
            responseText: "Synthetic answer",
            expectedContext: setup.context
        )

        let closed = FirstMateFeedbackEditorSession()
        let closedToken = closed.currentToken
        await setup.client.holdNextCategoryCreate()
        let staleAdd = Task {
            await closed.addCategory(
                label: "Needs more evidence",
                token: closedToken,
                store: setup.store,
                target: target
            )
        }
        while !(await setup.client.isWaitingForCategoryCreate) { await Task.yield() }
        closed.invalidate()
        setup.store.discardFeedbackDraft(for: setup.featureID, messageID: "demo-mate-0")

        // Reopen the same response before the held request resumes. The stale
        // completion stays in the catalog but never selects itself on the
        // reopened draft.
        let reopened = FirstMateFeedbackEditorSession()
        await setup.client.releaseCategoryCreate()
        #expect(!(await staleAdd.value))
        #expect(setup.store.feedbackCategories.contains { $0.label == "Needs more evidence" })
        #expect(setup.store.feedbackDraft(for: setup.featureID, messageID: "demo-mate-0").categoryIDs.isEmpty)

        // The reopened editor can still deliberately add and select its own
        // reason through the same fence.
        let freshToken = reopened.currentToken
        await setup.client.holdNextCategoryCreate()
        let freshAdd = Task {
            await reopened.addCategory(
                label: "Second reason",
                token: freshToken,
                store: setup.store,
                target: target
            )
        }
        while !(await setup.client.isWaitingForCategoryCreate) { await Task.yield() }
        await setup.client.releaseCategoryCreate()
        #expect(await freshAdd.value)
        let second = try #require(setup.store.feedbackCategories.first { $0.label == "Second reason" })
        #expect(setup.store.feedbackDraft(for: setup.featureID, messageID: "demo-mate-0").categoryIDs == [second.id])
    }

    /// A writable store with a loaded, empty record cache and reason catalog
    /// for the first synthetic feature.
    private func heldCategorySetup() async throws -> (
        store: FirstMateStore,
        client: FirstMateFeedbackTestClient,
        featureID: String,
        context: FirstMateStore.OperationContext
    ) {
        let client = FirstMateFeedbackTestClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let featureID = try #require(store.selectedFeatureID)
        let context = store.operationContext
        #expect(await store.loadFeedback(expectedContext: context))
        #expect(await store.loadFeedbackCategories(expectedContext: context))
        return (store, client, featureID, context)
    }
#endif
}

private extension FirstMateFeedbackDraft {
    /// Test helper for the revision pinned once a save is submitted.
    func withBaseRevision(_ revision: Int) -> FirstMateFeedbackDraft {
        var copy = self
        copy.baseRevision = revision
        return copy
    }
}

private func syntheticFeedbackRecord(
    featureID: String,
    messageID: String,
    rating: FirstMateFeedbackRating? = .down,
    categoryIDs: [String] = [],
    comment: String = "",
    revision: Int = 1
) -> FirstMateFeedback {
    FirstMateFeedback(
        messageID: messageID,
        featureID: featureID,
        rating: rating,
        categoryIDs: categoryIDs,
        comment: comment,
        revision: revision,
        createdAt: FirstMateDemo.timestamp,
        updatedAt: FirstMateDemo.timestamp,
        provenance: FirstMateFeedbackProvenance(
            responseText: "Synthetic completed response.",
            responseCreatedAt: FirstMateDemo.timestamp,
            sourceKind: "reply",
            inReplyTo: nil,
            visitID: nil,
            featureRevision: 1,
            coordinatorSessionID: "synthetic-coordinator",
            sessionProvenance: "verified"
        )
    )
}

private actor FirstMateFeedbackTestClient: FirstMateClient {
    private let supported: Bool
    private let snapshots: [FirstMateSnapshot]
    private var categories = FirstMateFeedbackDefaults.categories
    private var feedbackRecords: [String: [String: FirstMateFeedback]] = [:]
    private var loadFailuresRemaining = 0
    private var saveFailuresRemaining = 0
    private var capabilityFailuresRemaining = 0
    private var categoryFailuresRemaining = 0
    private var enforceRevisions = false
    private var holdLoads = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var heldLoadRecords: [FirstMateFeedback] = []
    private var holdSaves = false
    private var heldSaveFails = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var holdCategoryLoads = false
    private var categoryLoadContinuation: CheckedContinuation<Void, Never>?
    private var heldCategorySnapshot: [FirstMateFeedbackCategory] = []
    private var holdCategoryCreates = false
    private var categoryCreateContinuation: CheckedContinuation<Void, Never>?
    private var mismatchedFeedbackFeature = false
    private var mismatchedSaveIdentity = false
    private(set) var categoryCallCount = 0
    private(set) var categoryRequests: [FirstMateFeedbackCategoryCreateRequest] = []
    private(set) var feedbackCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var saveRequests: [FirstMateFeedbackSaveRequest] = []

    init(supported: Bool = true) {
        self.supported = supported
        snapshots = FirstMateDemo.features(step: 0)
    }

    var isWaitingForLoad: Bool { loadContinuation != nil }
    var isWaitingForSave: Bool { saveContinuation != nil }
    var isWaitingForCategoryLoad: Bool { categoryLoadContinuation != nil }
    var isWaitingForCategoryCreate: Bool { categoryCreateContinuation != nil }

    func seedRecord(_ record: FirstMateFeedback) {
        var records = feedbackRecords[record.featureID] ?? [:]
        records[record.messageID] = record
        feedbackRecords[record.featureID] = records
    }

    func setEnforceRevisions(_ value: Bool) { enforceRevisions = value }
    func setMismatchedFeedbackFeature(_ value: Bool) { mismatchedFeedbackFeature = value }
    func setMismatchedSaveIdentity(_ value: Bool) { mismatchedSaveIdentity = value }
    func failLoads(count: Int) { loadFailuresRemaining += count }
    func failSaves(count: Int) { saveFailuresRemaining += count }
    func failCapabilities(count: Int) { capabilityFailuresRemaining += count }
    func failCategories(count: Int) { categoryFailuresRemaining += count }
    func holdNextLoad() { holdLoads = true }
    func releaseLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
    func holdNextSave(failingAfterRelease: Bool = false) {
        holdSaves = true
        heldSaveFails = failingAfterRelease
    }
    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
    func holdNextCategoryLoad() { holdCategoryLoads = true }
    func releaseCategoryLoad() {
        categoryLoadContinuation?.resume()
        categoryLoadContinuation = nil
    }
    func holdNextCategoryCreate() { holdCategoryCreates = true }
    func releaseCategoryCreate() {
        categoryCreateContinuation?.resume()
        categoryCreateContinuation = nil
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        if capabilityFailuresRemaining > 0 {
            capabilityFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        return .init(ok: true, capabilities: supported
            ? ["first-mate-v1", "first-mate-archive-v1", "first-mate-feedback-v1"]
            : ["first-mate-v1", "first-mate-archive-v1"])
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        try await fetchFirstMateFeatures(scope: .active)
    }

    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        .init(ok: true, features: snapshots.map(\.feature))
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard let snapshot = snapshots.first(where: { $0.feature.id == id }) else {
            throw APIError.server(status: 404, message: "Not found")
        }
        return snapshot
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd, id: "synthetic-created")
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        snapshots[0]
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        snapshots[0]
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        .init(ok: true, document: snapshots[0].documents[0])
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        .init(ok: true, nativeSessionID: id, messages: [])
    }

    func fetchFirstMateFeedbackCategories() async throws -> FirstMateFeedbackCategoriesResponse {
        categoryCallCount += 1
        if categoryFailuresRemaining > 0 {
            categoryFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        if holdCategoryLoads {
            holdCategoryLoads = false
            heldCategorySnapshot = categories
            await withCheckedContinuation { categoryLoadContinuation = $0 }
            return .init(ok: true, categories: heldCategorySnapshot)
        }
        return .init(ok: true, categories: categories)
    }

    func createFirstMateFeedbackCategory(label: String, requestID: String) async throws -> FirstMateFeedbackCategoryResponse {
        categoryRequests.append(.init(label: label, requestID: requestID))
        if categoryFailuresRemaining > 0 {
            categoryFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        if holdCategoryCreates {
            holdCategoryCreates = false
            await withCheckedContinuation { categoryCreateContinuation = $0 }
        }
        let collapsed = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let normalized = collapsed.lowercased()
        if let existing = categories.first(where: {
            $0.label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() == normalized
        }) {
            return .init(ok: true, category: existing)
        }
        let category = FirstMateFeedbackCategory(
            id: "fmc-custom-\(categories.count)",
            label: collapsed,
            createdAt: FirstMateDemo.timestamp
        )
        categories.append(category)
        return .init(ok: true, category: category)
    }

    func fetchFirstMateFeedback(featureID: String) async throws -> FirstMateFeatureFeedbackResponse {
        feedbackCallCount += 1
        if loadFailuresRemaining > 0 {
            loadFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        let current = records(for: featureID)
        if holdLoads {
            holdLoads = false
            heldLoadRecords = current
            await withCheckedContinuation { loadContinuation = $0 }
            return .init(
                ok: true,
                featureID: mismatchedFeedbackFeature ? "other-feature" : featureID,
                records: mismatchedFeedbackFeature ? current : heldLoadRecords
            )
        }
        return .init(
            ok: true,
            featureID: mismatchedFeedbackFeature ? "other-feature" : featureID,
            records: current
        )
    }

    func saveFirstMateFeedback(
        featureID: String,
        messageID: String,
        request: FirstMateFeedbackSaveRequest
    ) async throws -> FirstMateFeedbackMutationResponse {
        saveCallCount += 1
        saveRequests.append(request)
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw URLError(.networkConnectionLost)
        }
        if holdSaves {
            holdSaves = false
            await withCheckedContinuation { saveContinuation = $0 }
            if heldSaveFails {
                heldSaveFails = false
                throw URLError(.networkConnectionLost)
            }
        }
        var records = feedbackRecords[featureID] ?? [:]
        let existing = records[messageID]
        if enforceRevisions, request.expectedRevision != (existing?.revision ?? 0) {
            throw APIError.server(status: 409, message: "Feedback changed. Reload it before saving.")
        }
        let record = FirstMateFeedback(
            messageID: mismatchedSaveIdentity ? "other-message" : messageID,
            featureID: featureID,
            rating: request.rating,
            categoryIDs: request.categoryIDs,
            comment: request.comment,
            revision: (existing?.revision ?? 0) + 1,
            createdAt: existing?.createdAt ?? FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp,
            provenance: .init(
                responseText: "Synthetic completed response.",
                responseCreatedAt: FirstMateDemo.timestamp,
                sourceKind: "reply",
                inReplyTo: nil,
                visitID: nil,
                featureRevision: 1,
                coordinatorSessionID: "synthetic-coordinator",
                sessionProvenance: "verified"
            )
        )
        records[messageID] = record
        feedbackRecords[featureID] = records
        return .init(ok: true, featureID: featureID, feedback: record)
    }

    private func records(for featureID: String) -> [FirstMateFeedback] {
        (feedbackRecords[featureID] ?? [:]).values.sorted { $0.messageID < $1.messageID }
    }
}
