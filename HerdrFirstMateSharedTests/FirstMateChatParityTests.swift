import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate chat parity contract")
struct FirstMateChatParityTests {
    @Test("Coordinator context preserves explicit zero and rejects malformed measurements")
    func contextDecoding() throws {
        let measured = try JSONDecoder().decode(
            FirstMateCoordinatorContext.self,
            from: Data(#"{"native_session_id":"session-1","status":"measured","tokens":0,"context_window":200000,"handoff_target_tokens":160000,"observed_at":"2030-01-01T12:00:00Z"}"#.utf8)
        )
        #expect(measured.tokens == 0)
        #expect(measured.measuredFraction == 0)
        #expect(measured.managedHandoffPressure == .belowTarget)
        #expect(!measured.isNearManagedHandoff)

        let approaching = FirstMateCoordinatorContext(
            status: .measured,
            tokens: 144_000,
            contextWindow: nil,
            handoffTargetTokens: 160_000
        )
        #expect(approaching.managedHandoffPressure == .approaching)
        #expect(approaching.isNearManagedHandoff)
        let reached = FirstMateCoordinatorContext(
            status: .measured,
            tokens: 160_000,
            contextWindow: 200_000,
            handoffTargetTokens: 160_000
        )
        #expect(reached.managedHandoffPressure == .thresholdReached)

        let malformed = try JSONDecoder().decode(
            FirstMateCoordinatorContext.self,
            from: Data(#"{"status":"measured","tokens":true,"context_window":-1,"handoff_target_tokens":1.5}"#.utf8)
        )
        #expect(malformed.tokens == nil)
        #expect(malformed.contextWindow == nil)
        #expect(malformed.handoffTargetTokens == nil)
        #expect(malformed.measuredFraction == nil)

        let oversized = FirstMateCoordinatorContext(
            status: .measured,
            tokens: .max,
            contextWindow: 1,
            handoffTargetTokens: .max
        )
        #expect(oversized.tokens == nil)
        #expect(oversized.contextWindow == 1)
        #expect(oversized.handoffTargetTokens == nil)
        #expect(oversized.measuredFraction == nil)

        let oversizedWire = try JSONDecoder().decode(
            FirstMateCoordinatorContext.self,
            from: Data("{\"status\":\"measured\",\"tokens\":\(Int.max),\"context_window\":1,\"handoff_target_tokens\":\(Int.max)}".utf8)
        )
        #expect(oversizedWire.tokens == nil)
        #expect(oversizedWire.contextWindow == 1)
        #expect(oversizedWire.handoffTargetTokens == nil)
        #expect(oversizedWire.measuredFraction == nil)

        let feature = try JSONDecoder().decode(
            FirstMateFeature.self,
            from: Data(#"{"id":"feature","title":"Synthetic","goal":"Verify context","cwd":"/workspace/synthetic","status":"running","revision":1,"created_at":"now","updated_at":"now","native_session_id":"session-1","coordinator_owner":"owner-hidden-from-ui","coordinator_context":{"native_session_id":"session-1","status":"measured","tokens":0,"context_window":200000,"handoff_target_tokens":160000,"observed_at":"2030-01-01T12:00:00Z"}}"#.utf8)
        )
        #expect(feature.nativeSessionID == "session-1")
        #expect(feature.coordinatorOwner != nil)
        #expect(feature.coordinatorContext?.tokens == 0)
    }

    @Test("New capabilities remain additive")
    func capabilities() throws {
        let value = try JSONDecoder().decode(
            FirstMateCapabilities.self,
            from: Data(#"{"ok":true,"capabilities":["first-mate-v1","first-mate-attachments-v1","first-mate-context-v1","first-mate-safe-model-settings-v1"]}"#.utf8)
        )
        #expect(value.supportsAttachments)
        #expect(value.supportsContext)
        #expect(value.supportsSafeModelSettings)
        #expect(!value.supportsArchive)
    }

    @Test("Safe settings fields are omitted for legacy callers and exact for established sessions")
    @MainActor
    func settingsEncoding() throws {
        let legacy = FirstMateModelSettings(
            model: "synthetic/model",
            thinking: "high",
            expectedSettingsRevision: 2,
            requestID: "legacy-request"
        )
        let legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(legacyObject["expected_session_id"] == nil)
        #expect(legacyObject["confirm_session_model_change"] == nil)

        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        var legacyFeature = try #require(store.snapshot?.feature)
        legacyFeature.nativeSessionID = nil
        legacyFeature.modelSettingsRevision = 2
        let actualLegacyProposal = try #require(FirstMateModelSettingsProposal.make(
            feature: legacyFeature,
            context: store.operationContext,
            model: "synthetic/model",
            thinking: "high",
            safeSettingsSupported: false,
            requestID: "actual-ui-legacy"
        ))
        let actualLegacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(actualLegacyProposal.settings)) as? [String: Any]
        )
        #expect(Set(actualLegacyObject.keys) == ["model", "thinking", "expected_settings_revision", "request_id"])

        let safe = FirstMateModelSettings(
            model: "synthetic/model",
            thinking: "high",
            expectedSettingsRevision: 2,
            requestID: "safe-request",
            expectedSessionID: "session-1",
            confirmSessionModelChange: true
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(safe)) as? [String: Any])
        #expect(object["expected_session_id"] as? String == "session-1")
        #expect(object["confirm_session_model_change"] as? Bool == true)
    }

    #if os(macOS)
    @Test("Feature composer attachments, quotes, and dictation remain isolated") @MainActor
    func stagedComposerState() {
        let drafts = FirstMateComposerDraftStore()
        let quote = ChatQuote(text: "Synthetic answer", comment: "Keep this", source: "feature-one")
        drafts.setQuotes([quote], for: "feature-one")
        drafts.setContainsDictation(true, for: "feature-one")
        #expect(drafts.quotes(for: "feature-one") == [quote])
        #expect(drafts.quotes(for: "feature-two").isEmpty)
        #expect(drafts.containsDictation(for: "feature-one"))
        #expect(!drafts.containsDictation(for: "feature-two"))
        drafts.setContainsDictation(false, for: "feature-one")
        #expect(!drafts.containsDictation(for: "feature-one"))
    }

    @Test("Only the latest three completed assistant messages can be quoted")
    func quoteEligibility() {
        let messages = (0..<5).map { index in
            FirstMateMessage(
                id: "assistant-\(index)",
                featureID: "feature",
                role: "assistant",
                text: index == 1 ? "" : "Answer \(index)",
                status: index == 4 ? "queued" : "delivered",
                createdAt: "2030-01-01T12:00:00Z"
            )
        } + [FirstMateMessage(id: "user", featureID: "feature", role: "user", text: "Direction", status: "delivered", createdAt: "2030-01-01T12:00:00Z")]
        #expect(FirstMateQuoteEligibility.messageIDs(in: messages) == ["assistant-0", "assistant-2", "assistant-3"])
    }

    @Test("Quote Save revalidates eligibility, control, feature selection, and closed state") @MainActor
    func quoteSavePolicy() throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        let controlLease = FirstMateWorkspaceControlLease()
        controlLease.update(store: store, available: true)
        var snapshot = try #require(store.snapshot)
        let source = FirstMateMessage(
            id: "eligible",
            featureID: snapshot.feature.id,
            role: "assistant",
            text: "Synthetic eligible response",
            status: "delivered",
            createdAt: "2030-01-01T12:00:00Z"
        )
        snapshot.messages = [source]
        store.receive(snapshot)
        let context = store.operationContext
        #expect(FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: store.snapshot(for: context),
            expectedContext: context,
            currentContext: store.operationContext,
            canControl: store.controlAvailable
        ))

        var noLongerEligible = snapshot
        noLongerEligible.messages.append(contentsOf: (0..<3).map {
            FirstMateMessage(id: "new-\($0)", featureID: snapshot.feature.id, role: "assistant", text: "New \($0)", status: "delivered", createdAt: "2030-01-01T12:00:00Z")
        })
        noLongerEligible.feature.revision += 1
        store.receive(noLongerEligible)
        #expect(!FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: store.snapshot(for: context),
            expectedContext: context,
            currentContext: store.operationContext,
            canControl: true
        ))

        let otherID = store.features.first { $0.id != snapshot.feature.id }?.id
        store.select(try #require(otherID))
        #expect(!FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: store.snapshot(for: context),
            expectedContext: context,
            currentContext: store.operationContext,
            canControl: true
        ))

        store.select(snapshot.feature.id)
        var closed = noLongerEligible
        closed.messages = [source]
        closed.feature.status = "completed"
        closed.feature.revision += 1
        store.receive(closed)
        #expect(!FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: store.snapshot(for: store.operationContext),
            expectedContext: store.operationContext,
            currentContext: store.operationContext,
            canControl: true
        ))
        #expect(!FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: snapshot,
            expectedContext: context,
            currentContext: context,
            canControl: false
        ))
    }

    @Test("Workspace control lease revokes a cached host and fences stale cleanup") @MainActor
    func workspaceControlLease() throws {
        let firstStore = FirstMateStore()
        let secondStore = FirstMateStore()
        firstStore.configure(client: nil, demo: true)
        secondStore.configure(client: nil, demo: true)
        let featureID = try #require(firstStore.selectedFeatureID)
        secondStore.select(featureID)

        var snapshot = try #require(firstStore.snapshot)
        let source = FirstMateMessage(
            id: "cached-host-quote",
            featureID: featureID,
            role: "assistant",
            text: "Synthetic cached-host answer",
            status: "delivered",
            createdAt: "2030-01-01T12:00:00Z"
        )
        snapshot.messages = [source]
        firstStore.receive(snapshot)
        let cachedContext = firstStore.operationContext
        let firstLifecycle = firstStore.lifecycle

        let workspaceLease = FirstMateWorkspaceControlLease()
        workspaceLease.update(store: firstStore, available: true)
        #expect(FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: firstStore.snapshot(for: cachedContext),
            expectedContext: cachedContext,
            currentContext: firstStore.operationContext,
            canControl: firstStore.controlAvailable
        ))

        workspaceLease.update(store: secondStore, available: true)
        #expect(!firstStore.controlAvailable)
        #expect(secondStore.controlAvailable)
        workspaceLease.release(
            storeID: ObjectIdentifier(firstStore),
            lifecycleIdentity: firstLifecycle
        )
        #expect(secondStore.controlAvailable)
        #expect(!FirstMateQuoteEligibility.canStage(
            sourceMessageID: source.id,
            snapshot: firstStore.snapshot(for: cachedContext),
            expectedContext: cachedContext,
            currentContext: firstStore.operationContext,
            canControl: firstStore.controlAvailable
        ))

        let previousSecondLifecycle = secondStore.lifecycle
        secondStore.configure(client: nil, demo: true)
        workspaceLease.update(store: secondStore, available: true)
        workspaceLease.release(
            storeID: ObjectIdentifier(secondStore),
            lifecycleIdentity: previousSecondLifecycle
        )
        #expect(secondStore.controlAvailable)

        let newerLease = FirstMateWorkspaceControlLease()
        newerLease.update(store: secondStore, available: true)
        workspaceLease.release()
        #expect(secondStore.controlAvailable)
        newerLease.release()
        #expect(!secondStore.controlAvailable)
    }

    @Test("Composer lifecycle identity isolates reconnects and same feature IDs in different stores") @MainActor
    func composerLifecycleIdentity() throws {
        let firstStore = FirstMateStore()
        let secondStore = FirstMateStore()
        firstStore.configure(client: nil, demo: true)
        secondStore.configure(client: nil, demo: true)
        let featureID = try #require(firstStore.selectedFeatureID)
        secondStore.select(featureID)
        let firstID = try #require(firstStore.operationContext.destinationID(for: featureID))
        let secondID = try #require(secondStore.operationContext.destinationID(for: featureID))
        #expect(firstID != secondID)

        firstStore.configure(client: nil, demo: true)
        firstStore.select(featureID)
        let reconnectedID = try #require(firstStore.operationContext.destinationID(for: featureID))
        #expect(firstID != reconnectedID)
    }

    @Test("Frozen model proposals reject rotation, revision, selection, owner, and queue changes") @MainActor
    func frozenModelProposal() throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        var feature = try #require(store.snapshot?.feature)
        feature.nativeSessionID = "session-a"
        feature.modelSettingsRevision = 4
        let context = store.operationContext
        let proposal = try #require(FirstMateModelSettingsProposal.make(
            feature: feature,
            context: context,
            model: "synthetic/reasoner",
            thinking: "high",
            safeSettingsSupported: true,
            requestID: "frozen-request"
        ))
        #expect(proposal.settings.expectedSessionID == "session-a")
        #expect(proposal.settings.requestID == "frozen-request")
        #expect(proposal.settings.confirmSessionModelChange == nil)

        var state = FirstMateModelSettingsProposalState()
        let stagedProposal = state.stage(
            feature: feature,
            context: context,
            model: "synthetic/reasoner",
            thinking: "high",
            safeSettingsSupported: true,
            requestID: "state-request"
        )
        let staged = try #require(stagedProposal)
        let retriedProposal = state.stage(
            feature: feature,
            context: context,
            model: "synthetic/reasoner",
            thinking: "high",
            safeSettingsSupported: true,
            requestID: "must-not-replace"
        )
        let retried = try #require(retriedProposal)
        #expect(staged.settings == retried.settings)
        #expect(retried.settings.requestID == "state-request")
        #expect(state.needsConfirmation)
        let unconfirmedSubmission = state.proposalForSubmission()
        #expect(unconfirmedSubmission == nil)

        // A busy-state or outside dismissal does not imply consent. An ordinary
        // retry must still reopen confirmation instead of yielding a payload.
        var busy = feature
        busy.coordinatorOwner = "synthetic-owner"
        #expect(staged.blockReason(
            feature: busy,
            currentContext: context,
            safeSettingsSupported: true,
            canControl: true,
            hasQueuedWork: false,
            operationInFlight: false
        ) == .coordinatorBusy)
        let retrySubmission = state.proposalForSubmission()
        #expect(retrySubmission == nil)
        let confirmedSubmission = state.proposalForSubmission(userConfirmed: true)
        let confirmed = try #require(confirmedSubmission)
        #expect(confirmed.settings.confirmSessionModelChange == true)
        #expect(!state.needsConfirmation)
        let uncertainRetrySubmission = state.proposalForSubmission()
        let uncertainRetry = try #require(uncertainRetrySubmission)
        #expect(confirmed.settings == uncertainRetry.settings)
        #expect(uncertainRetry.settings.requestID == "state-request")

        var invalidatedFeature = feature
        invalidatedFeature.modelSettingsRevision = 5
        let didInvalidate = state.invalidateUnless(
            feature: invalidatedFeature,
            currentContext: context,
            safeSettingsSupported: true
        )
        #expect(didInvalidate)
        #expect(state.proposal == nil)
        let invalidatedSubmission = state.proposalForSubmission()
        #expect(invalidatedSubmission == nil)

        let cancelledProposal = state.stage(
            feature: feature,
            context: context,
            model: "synthetic/reasoner",
            thinking: "high",
            safeSettingsSupported: true,
            requestID: "cancelled-request"
        )
        _ = try #require(cancelledProposal)
        state.cancel()
        #expect(state.proposal == nil)
        let cancelledSubmission = state.proposalForSubmission()
        #expect(cancelledSubmission == nil)

        var initialSession = feature
        initialSession.nativeSessionID = nil
        var initialState = FirstMateModelSettingsProposalState()
        let stagedInitialProposal = initialState.stage(
            feature: initialSession,
            context: context,
            model: "synthetic/reasoner",
            thinking: "high",
            safeSettingsSupported: false,
            requestID: "initial-request"
        )
        let initial = try #require(stagedInitialProposal)
        #expect(!initial.requiresConfirmation)
        let initialSubmission = initialState.proposalForSubmission()
        #expect(initialSubmission == initial)
        let initialObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(initial.settings)) as? [String: Any]
        )
        #expect(initialObject["expected_session_id"] == nil)
        #expect(initialObject["confirm_session_model_change"] == nil)

        var rotated = feature
        rotated.nativeSessionID = "session-b"
        #expect(!proposal.matches(feature: rotated, currentContext: context, safeSettingsSupported: true))
        rotated.nativeSessionID = nil
        #expect(!proposal.matches(feature: rotated, currentContext: context, safeSettingsSupported: true))
        rotated = feature
        rotated.modelSettingsRevision = 5
        #expect(!proposal.matches(feature: rotated, currentContext: context, safeSettingsSupported: true))

        var owned = feature
        owned.coordinatorOwner = "synthetic-owner"
        #expect(proposal.blockReason(
            feature: owned,
            currentContext: context,
            safeSettingsSupported: true,
            canControl: true,
            hasQueuedWork: false,
            operationInFlight: false
        ) == .coordinatorBusy)
        #expect(proposal.blockReason(
            feature: feature,
            currentContext: context,
            safeSettingsSupported: true,
            canControl: true,
            hasQueuedWork: true,
            operationInFlight: false
        ) == .queuedWork)
        #expect(proposal.blockReason(
            feature: feature,
            currentContext: context,
            safeSettingsSupported: true,
            canControl: true,
            hasQueuedWork: false,
            operationInFlight: true
        ) == .operationInFlight)
        #expect(proposal.blockReason(
            feature: feature,
            currentContext: context,
            safeSettingsSupported: true,
            canControl: false,
            hasQueuedWork: false,
            operationInFlight: false
        ) == .unavailable)

        let otherID = try #require(store.features.first { $0.id != feature.id }?.id)
        store.select(otherID)
        #expect(!proposal.matches(feature: feature, currentContext: store.operationContext, safeSettingsSupported: true))
    }

    @Test("Context presentation distinguishes approach, threshold, and unknown window")
    func contextPresentation() {
        var feature = FirstMateDemo.features(step: 0)[0].feature
        feature.nativeSessionID = "session"
        feature.coordinatorContext = .init(nativeSessionID: "session", status: .measured, tokens: 144_000, contextWindow: nil, handoffTargetTokens: 160_000, observedAt: "2030-01-01T12:00:00.123Z")
        var presentation = FirstMateCoordinatorContextPresentation(feature: feature, capabilityAvailable: true)
        #expect(presentation.summary.contains("window unknown"))
        #expect(presentation.pressure?.contains("Approaching") == true)
        #expect(presentation.measurement?.contains("Measured") == true)

        feature.coordinatorContext?.tokens = 160_000
        presentation = .init(feature: feature, capabilityAvailable: true)
        #expect(presentation.pressure?.contains("threshold reached") == true)

        feature.coordinatorContext?.observedAt = "not-a-timestamp"
        presentation = .init(feature: feature, capabilityAvailable: true)
        #expect(presentation.measurement == nil)

        feature.coordinatorContext = .init(
            nativeSessionID: "session",
            status: .measured,
            tokens: .max,
            contextWindow: 1,
            handoffTargetTokens: nil
        )
        presentation = .init(feature: feature, capabilityAvailable: true)
        #expect(presentation.summary.contains("measurement unavailable"))

        feature.nativeSessionID = nil
        presentation = .init(feature: feature, capabilityAvailable: true)
        #expect(presentation.summary.contains("new session"))
    }

    @Test("Camel-case attachment envelopes decode without changing workspace compatibility")
    func camelCaseAttachment() throws {
        let data = Data(#"{"ok":true,"attachment":{"id":"attachment-1","filename":"sample.txt","originalFilename":"Sample.txt","contentType":"text/plain","size":12,"path":"first-mate:feature/attachment-1","workspaceId":"first-mate:feature","createdAt":"2030-01-01T12:00:00Z"}}"#.utf8)
        let response = try JSONDecoder().decode(AttachmentUploadResponse.self, from: data)
        #expect(response.attachment?.originalFilename == "Sample.txt")
        #expect(response.attachment?.workspaceID == "first-mate:feature")
    }
    #endif
}
