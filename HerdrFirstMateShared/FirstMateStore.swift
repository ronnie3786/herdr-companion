import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class FirstMateStore {
    struct LifecycleIdentity: Equatable, Hashable, Sendable {
        fileprivate let value: UUID

        /// Safe to use as SwiftUI/task identity. This is a random local lifecycle
        /// marker, never a companion credential or server token.
        var opaqueID: String { value.uuidString.lowercased() }
    }

    struct OperationContext: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let featureID: String?
        let lifecycleIdentity: LifecycleIdentity

        func matchesFeature(_ id: String) -> Bool { featureID == id }

        func destinationID(for featureID: String) -> String? {
            guard matchesFeature(featureID) else { return nil }
            return "first-mate:\(featureID):lifecycle:\(lifecycleIdentity.opaqueID)"
        }
    }

    struct ControlLease: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let lifecycleIdentity: LifecycleIdentity
    }

    private struct FeedbackKey: Hashable {
        let featureID: String
        let messageID: String

        init(_ featureID: String, _ messageID: String) {
            self.featureID = featureID
            self.messageID = messageID
        }
    }

    /// Capture when the human acts, before scheduling an asynchronous UI task.
    var operationContext: OperationContext {
        .init(generation: generation, featureID: selectedFeatureID, lifecycleIdentity: lifecycleIdentity)
    }
    var lifecycle: LifecycleIdentity { lifecycleIdentity }

    private(set) var features: [FirstMateFeature] = []
    private(set) var snapshots: [String: FirstMateSnapshot] = [:]
    /// Ordering fences must advance even when an identical verdict does not
    /// notify views. Otherwise a delayed green could overwrite a newer failure.
    @ObservationIgnored private var latestVerifications: [String: FirstMateVerification] = [:]
    @ObservationIgnored private var capabilitiesCheckedAt: Date?
    @ObservationIgnored private var conversationRefreshID = UUID()
    private(set) var readViewsSupported = false
    private(set) var inspectorRefreshRevision = 0
    private(set) var inspectorSnapshots: [String: FirstMateSnapshot] = [:]
    private(set) var inspectorErrors: [String: String] = [:]
    private(set) var earlierMessageCursors: [String: String] = [:]
    private(set) var loadingEarlierMessages: Set<String> = []
    private(set) var earlierMessagesErrors: [String: String] = [:]
    @ObservationIgnored private var chatVersions: [String: String] = [:]
    @ObservationIgnored private var chatRequests: [String: UUID] = [:]
    @ObservationIgnored private var inspectorVersions: [String: String] = [:]
    @ObservationIgnored private var inspectorRequests: [String: UUID] = [:]
    var selectedFeatureID: String?
    var inspector = FirstMateInspector.overview
    /// The Documents inspector's Documents/Links sub-tab. Shared so the
    /// prominent PR section can open the Links collection directly.
    var documentsMode = FirstMateDocumentsMode.documents
    var graphMode = false
    var selectedVisitID: String?
    var draft = ""
    var search = ""
    var showArchived = false
    var isCreating = false
    #if os(macOS)
    var isDark = true
    #else
    var isDark = ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateDark")
    #endif
    private(set) var isDemo = false
    private(set) var isRefreshing = false
    private(set) var isSending = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var unsupported = false
    private(set) var archiveSupported = false
    private(set) var attachmentsSupported = false
    private(set) var contextSupported = false
    private(set) var safeModelSettingsSupported = false
    private(set) var linksSupported = false
    /// The companion advertises `first-mate-lead-v1`.
    private(set) var leadSupported = false
    /// The lead First Mate's feature ID once it has been opened. Its snapshot
    /// lives in ``snapshots`` like a feature's, but it is never in ``features``.
    private(set) var leadFeatureID: String?
    private(set) var controlAvailable = false
    // Response feedback is companion data that deliberately stays outside
    // FirstMateSnapshot and composer state. Caches are scoped to this client
    // lifecycle and to the exact feature and response they came from.
    //
    // The capability is tri-state so a failed or unanswered check is never
    // mistaken for a confirmed old server: only a successful capability
    // response without `first-mate-feedback-v1` shows upgrade guidance, while
    // `.unknown` keeps cached ratings readable and an open draft recoverable.
    private(set) var feedbackCapability: FirstMateFeedbackCapability = .unknown
    var feedbackSupported: Bool { feedbackCapability == .supported }
    private(set) var feedbackCategories: [FirstMateFeedbackCategory] = []
    private(set) var feedbackCategoriesLoaded = false
    private(set) var isLoadingFeedbackCategories = false
    private(set) var isAddingFeedbackCategory = false
    private(set) var feedbackCategoriesError: String?
    private var feedbackRecords: [String: [String: FirstMateFeedback]] = [:]
    private var loadedFeedbackFeatures: Set<String> = []
    private var loadingFeedbackFeatures: Set<String> = []
    private var feedbackErrors: [String: String] = [:]
    private var savingFeedbackKeys: Set<FeedbackKey> = []
    private var feedbackSaveErrors: [FeedbackKey: String] = [:]
    private var feedbackConflicts: Set<FeedbackKey> = []
    private var feedbackDrafts: [FeedbackKey: FirstMateFeedbackDraft] = [:]
    private var pendingFeedbackRequests: [FeedbackKey: FirstMateFeedbackSaveRequest] = [:]
    private(set) var isSavingLink = false
    private(set) var linkMutationError: String?
    private(set) var lastUpdated: Date?
    private(set) var runtimeHealth: FirstMateRuntimeHealth?
    var openedResource: FirstMateResource?
    var resourcePresentation: FirstMateResourcePresentation?
    private(set) var resourceText = ""
    private(set) var sessionMessages: [FirstMateSessionMessage]? = nil
    private(set) var resourceLoading = false
    private(set) var resourceError: String?
    private(set) var resourceUsage: FirstMateUsage?
    private(set) var resourceModelSelection: FirstMateModelSelection?
    private(set) var sessionNextBefore: Int?
    private(set) var sessionTotalMessages: Int?
    private(set) var sessionLoadedMessages = 0
    private(set) var isLoadingEarlier = false
    private(set) var sessionPageError: String?
    private var generation = 0
    private var lifecycleIdentity = LifecycleIdentity(value: UUID())
    private var activeControlLease: ControlLease?
    private var resourceGeneration = 0
    private var drafts: [String: String] = [:]
    private var pendingMessages: [String: (text: String, requestID: String)] = [:]
    /// Optimistic submissions for one exact feature, in submission order.
    /// Scoped to this store's lifecycle: ``configure(client:demo:demoFeatures:)``
    /// clears them, and a local identity never reaches the companion.
    private var outgoingMessages: [String: [FirstMateOutgoingMessage]] = [:]
    /// The snapshot sent with a pending message to the lead, by request ID,
    /// so a retry repeats the exact request.
    private var pendingLeadContexts: [String: FirstMateLeadContext] = [:]
    /// Builds the read-only snapshot of the person's other machines that
    /// messages to the lead carry. Set by the owner (the chat window, the HUD).
    @ObservationIgnored var leadContextProvider: (@MainActor () -> FirstMateLeadContext?)?
    private var pendingLinkSaves: [String: (draft: FirstMateLinkDraft, requestID: String)] = [:]
    private var pendingLinkVisibility: [String: String] = [:]
    private var demoStep = 0
    /// Set for a custom demo (the chat window's, timed around today), whose
    /// sends are stamped with the wall clock. The default demo keeps its fixed
    /// timestamp.
    private var demoUsesWallClock = false
    @ObservationIgnored private var client: (any FirstMateClient)?
    @ObservationIgnored private(set) var journalEventSnapshotsSupported = false
    #if os(macOS)
    @ObservationIgnored let composerDrafts = FirstMateComposerDraftStore()
    #endif

    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var canManageLinks: Bool { isDemo || linksSupported }
    var canMutateLinks: Bool { isDemo || controlAvailable }
    var snapshot: FirstMateSnapshot? { selectedFeatureID.flatMap { snapshots[$0] } }
    var hasUnsentDrafts: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #if os(macOS)
        return hasText || composerDrafts.hasStagedContent
        #else
        return hasText
        #endif
    }

    func executionDisplayStatus(for feature: FirstMateFeature) -> String {
        if !isDemo, ["running", "coordinating", "recovering"].contains(feature.status),
           error != nil || runtimeHealth?.warning != nil {
            return "unverified"
        }
        return feature.status
    }

    var filteredFeatures: [FirstMateFeature] {
        features.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.goal.localizedCaseInsensitiveContains(search) }
    }
    var activeFeatures: [FirstMateFeature] { filteredFeatures.filter { !$0.isArchived } }
    var archivedFeatures: [FirstMateFeature] { filteredFeatures.filter(\.isArchived) }

    /// `demoFeatures` replaces the default demo (`FirstMateDemo.features(step: 0)`)
    /// for a demo store; it is ignored otherwise.
    func configure(client: (any FirstMateClient)?, demo: Bool, demoFeatures: [FirstMateSnapshot]? = nil) {
        generation += 1
        lifecycleIdentity = LifecycleIdentity(value: UUID())
        resourceGeneration += 1
        self.client = client
        isDemo = demo
        features = []
        snapshots = [:]
        selectedFeatureID = nil
        selectedVisitID = nil
        draft = ""
        drafts = [:]
        pendingMessages = [:]
        outgoingMessages = [:]
        pendingLeadContexts = [:]
        openedResource = nil
        resourcePresentation = nil
        resourceText = ""
        sessionMessages = nil
        resourceLoading = false
        resourceError = nil
        resourceUsage = nil
        resourceModelSelection = nil
        resetSessionPagination()
        error = nil
        unsupported = false
        archiveSupported = demo
        attachmentsSupported = demo
        contextSupported = demo
        safeModelSettingsSupported = demo
        feedbackCapability = demo ? .supported : .unknown
        feedbackCategories = demo ? FirstMateFeedbackDefaults.categories.map {
            FirstMateFeedbackCategory(id: $0.id, label: $0.label, createdAt: FirstMateDemo.timestamp)
        } : []
        feedbackCategoriesLoaded = demo
        isLoadingFeedbackCategories = false
        isAddingFeedbackCategory = false
        feedbackCategoriesError = nil
        feedbackRecords = [:]
        loadedFeedbackFeatures = []
        loadingFeedbackFeatures = []
        feedbackErrors = [:]
        savingFeedbackKeys = []
        feedbackSaveErrors = [:]
        feedbackConflicts = []
        feedbackDrafts = [:]
        pendingFeedbackRequests = [:]
        linksSupported = demo
        leadSupported = demo && (demoFeatures ?? []).contains { $0.feature.isLead }
        leadFeatureID = nil
        isSavingLink = false
        linkMutationError = nil
        pendingLinkSaves = [:]
        pendingLinkVisibility = [:]
        activeControlLease = nil
        controlAvailable = demo
        isRefreshing = false
        isSending = false
        isCreating = false
        showArchived = false
        documentsMode = .documents
        hasLoaded = false
        lastUpdated = nil
        #if os(macOS)
        composerDrafts.discardAll()
        #endif
        runtimeHealth = nil
        latestVerifications = [:]
        capabilitiesCheckedAt = nil
        conversationRefreshID = UUID()
        readViewsSupported = false
        inspectorSnapshots = [:]; inspectorErrors = [:]; inspectorVersions = [:]; inspectorRequests = [:]
        chatVersions = [:]; chatRequests = [:]
        earlierMessageCursors = [:]; loadingEarlierMessages = []; earlierMessagesErrors = [:]
        demoUsesWallClock = demo && demoFeatures != nil
        if demo {
            demoStep = 0
            for value in demoFeatures ?? FirstMateDemo.features(step: 0) { receive(value) }
            selectedFeatureID = features.first?.id
            hasLoaded = true
        }
    }

    func acquireControlLease(available: Bool) -> ControlLease {
        let lease = ControlLease(id: UUID(), lifecycleIdentity: lifecycleIdentity)
        activeControlLease = lease
        controlAvailable = available
        return lease
    }

    func updateControlLease(_ lease: ControlLease, available: Bool) {
        guard activeControlLease == lease, lease.lifecycleIdentity == lifecycleIdentity else { return }
        controlAvailable = available
    }

    func releaseControlLease(_ lease: ControlLease) {
        guard activeControlLease == lease, lease.lifecycleIdentity == lifecycleIdentity else { return }
        activeControlLease = nil
        controlAvailable = false
    }

    func select(_ id: String) {
        if let old = selectedFeatureID { drafts[old] = draft }
        selectedFeatureID = id
        draft = drafts[id] ?? ""
        selectedVisitID = snapshots[id]?.feature.currentVisitID
        error = nil
        linkMutationError = nil
        closeResource()
    }

    /// Navigates from Overview to the Documents inspector's Links collection.
    func showLinksCollection() {
        inspector = .documents
        documentsMode = .links
    }

    func composerDraft(for context: OperationContext) -> String {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return "" }
        return selectedFeatureID == featureID ? draft : drafts[featureID] ?? ""
    }

    func setComposerDraft(_ value: String, for context: OperationContext) {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return }
        if selectedFeatureID == featureID {
            draft = value
        } else {
            drafts[featureID] = value
        }
    }

    func receive(_ value: FirstMateSnapshot, isPresentationRead: Bool = false) {
        guard value.ok else { return }
        if let existing = snapshots[value.feature.id],
           existing.feature.revision > value.feature.revision ||
           (existing.feature.modelSettingsRevision ?? 0) > (value.feature.modelSettingsRevision ?? 0) { return }
        if value.hasDetails, let existing = snapshots[value.feature.id], existing.feature.revision == value.feature.revision,
           existing.latestEventSequence > value.latestEventSequence { return }
        if !isPresentationRead {
            for view in [FirstMateReadView.overview, .details] {
                inspectorVersions[inspectorKey(featureID: value.feature.id, view: view)] = nil
            }
            inspectorRefreshRevision &+= 1
        }
        // Mutation receipts invalidate an outstanding conditional read. Its
        // older response must not replace freshly accepted local work.
        chatVersions[value.feature.id] = nil
        chatRequests[value.feature.id] = nil
        var value = value
        if let existing = snapshots[value.feature.id]?.feature ?? features.first(where: { $0.id == value.feature.id }) {
            value.feature.verification = Self.retainedVerification(
                incoming: value.feature.verification,
                includesField: value.feature.includesVerification,
                cached: latestVerifications[value.feature.id] ?? existing.verification,
                incomingIsStale: Self.isStrictlyOlderTimestamp(value.feature.updatedAt, than: existing.updatedAt),
                authoritative: value.hasDetails
            )
            value.feature.includesVerification = value.feature.includesVerification || existing.includesVerification
        }
        latestVerifications[value.feature.id] = value.feature.verification
        if let health = value.runtimeHealth, !FirstMatePollPresentation.sameHealth(health, runtimeHealth) { runtimeHealth = health }
        // An identical poll changes nothing on screen. Dictionary and array
        // element writes notify observers even when the value is unchanged.
        if value.hasDetails, let existing = snapshots[value.feature.id],
           FirstMatePollPresentation.sameSnapshot(existing, value),
           value.feature.isLead || features.contains(where: { $0.id == value.feature.id && FirstMatePollPresentation.sameFeature($0, value.feature) }) {
            reconcileOutgoingMessages(for: value.feature.id)
            return
        }
        if !value.hasDetails, var existing = snapshots[value.feature.id] {
            // Mutations acknowledge the feature; their omitted arrays and usage are not deletions.
            // A delayed mutation may have the same feature/settings revisions as a
            // newer full session-rotation snapshot. Only valid, strictly ordered
            // timestamps fence its stale session identity; equal or unparseable
            // synthetic timestamps retain the compatible merge behavior.
            var feature = value.feature
            let hasStaleIdentityMetadata = Self.isStrictlyOlderTimestamp(
                feature.updatedAt,
                than: existing.feature.updatedAt
            )
            if feature.usage == nil { feature.usage = existing.feature.usage }
            if hasStaleIdentityMetadata {
                feature.updatedAt = existing.feature.updatedAt
                feature.nativeSessionID = existing.feature.nativeSessionID
                feature.includesNativeSessionID = existing.feature.includesNativeSessionID
                feature.coordinatorContext = existing.feature.coordinatorContext
                feature.modelSelection = existing.feature.modelSelection
            } else {
                // An explicit native_session_id:null is a managed rotation and
                // must not resurrect its predecessor. Only genuinely omitted
                // old-server metadata inherits the cached identity and context.
                if !feature.includesNativeSessionID {
                    feature.nativeSessionID = existing.feature.nativeSessionID
                }
                if feature.coordinatorContext == nil,
                   feature.nativeSessionID == existing.feature.nativeSessionID {
                    feature.coordinatorContext = existing.feature.coordinatorContext
                }
                if feature.modelSelection == nil { feature.modelSelection = existing.feature.modelSelection }
            }
            existing.feature = feature
            if value.includesLinks { existing.links = value.links }
            if !FirstMatePollPresentation.sameSnapshot(snapshots[value.feature.id]!, existing) {
                snapshots[value.feature.id] = existing
            }
        } else {
            var incoming = value
            if !incoming.includesLinks, let existing = snapshots[incoming.feature.id] {
                // A server without the additive links field is not evidence
                // that previously cached links were removed.
                incoming.links = existing.links
            }
            if snapshots[incoming.feature.id].map({ !FirstMatePollPresentation.sameSnapshot($0, incoming) }) ?? true {
                snapshots[incoming.feature.id] = incoming
            }
        }
        let acceptedFeature = snapshots[value.feature.id]?.feature ?? value.feature
        if acceptedFeature.isLead {
            // The lead is a conversation above the features, never one of them.
            if leadFeatureID != acceptedFeature.id { leadFeatureID = acceptedFeature.id }
        } else if let index = features.firstIndex(where: { $0.id == value.feature.id }) {
            if !FirstMatePollPresentation.sameFeature(features[index], acceptedFeature) { features[index] = acceptedFeature }
        } else { features.append(acceptedFeature) }
        lastUpdated = .now
        // Observation is presentation state, not part of the snapshot: a poll
        // may be the first proof that a submitted row exists, and its status
        // may be newer than a receipt that has not arrived yet.
        reconcileOutgoingMessages(for: value.feature.id)
    }

    private func apply(_ capabilities: FirstMateCapabilities) {
        capabilitiesCheckedAt = .now
        #if os(macOS)
        readViewsSupported = capabilities.ok && capabilities.supportsReadViews
        #endif
        archiveSupported = capabilities.ok && capabilities.supportsArchive
        attachmentsSupported = capabilities.ok && capabilities.supportsAttachments
        contextSupported = capabilities.ok && capabilities.supportsContext
        safeModelSettingsSupported = capabilities.ok && capabilities.supportsSafeModelSettings
        let journalOnly = capabilities.ok && capabilities.supportsJournalEventSnapshots
        if journalEventSnapshotsSupported != journalOnly { journalEventSnapshotsSupported = journalOnly }
        feedbackCapability = capabilities.ok
            ? (capabilities.supportsFeedback ? .supported : .unsupported)
            : .unknown
        linksSupported = capabilities.ok && capabilities.supportsLinks
        leadSupported = capabilities.ok && capabilities.supportsLead
    }

    /// Opens the lead First Mate: creates it on the companion on first use,
    /// loads its conversation, and selects it. Returns false when the
    /// companion has no lead or the request failed (see ``error``).
    @discardableResult
    func openLead() async -> Bool {
        if isDemo {
            guard let id = leadFeatureID else { return false }
            if selectedFeatureID != id { select(id) }
            return true
        }
        guard let client else {
            error = "Connect to a companion server to talk to First Mate."
            return false
        }
        let context = operationContext
        func isCurrent() -> Bool { !Task.isCancelled && context == operationContext }
        do {
            if !hasLoaded, let capabilities = try? await client.fetchFirstMateCapabilities() {
                // A store that only shows the lead (the HUD's) never runs a
                // full refresh, so the composer learns what it supports here.
                guard isCurrent() else { return false }
                apply(capabilities)
                hasLoaded = true
            }
            guard isCurrent() else { return false }
            let response = try await client.ensureFirstMateLead(requestID: UUID().uuidString)
            guard isCurrent() else { return false }
            guard response.ok, let lead = response.lead, lead.feature.isLead else { throw APIError.invalidResponse }
            leadSupported = true
            try await readConversation(lead.feature.id, isCurrent: isCurrent)
            guard isCurrent(), snapshots[lead.feature.id] != nil else { return false }
            if selectedFeatureID != lead.feature.id { select(lead.feature.id) }
            error = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent() else { return false }
            record(error)
            return false
        }
    }

    /// The lead's cached conversation, when it has been opened.
    var leadSnapshot: FirstMateSnapshot? { leadFeatureID.flatMap { snapshots[$0] } }

    /// Refreshes only the opened lead's conversation: no feature list. The
    /// HUD polls this while its chat card shows.
    func refreshLead() async {
        guard !isDemo, let client, let id = leadFeatureID, !isRefreshing else { return }
        let capturedGeneration = generation
        do {
            try await readConversation(id) { !Task.isCancelled && capturedGeneration == generation }
            guard capturedGeneration == generation else { return }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard capturedGeneration == generation else { return }
            record(error)
        }
    }

    func refresh(includeConversation: Bool = true) async {
        guard !isRefreshing else { return }
        if isDemo {
            features = snapshots.values.map(\.feature)
                .filter { !$0.isLead && (showArchived || !$0.isArchived) }
                .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            reconcileSelection()
            return
        }
        guard let client else { return }
        let capturedGeneration = generation
        isRefreshing = true
        defer { if capturedGeneration == generation { isRefreshing = false } }
        do {
            do {
                let capabilities = try await client.fetchFirstMateCapabilities()
                guard capturedGeneration == generation else { return }
                apply(capabilities)
            } catch {
                guard capturedGeneration == generation else { return }
                archiveSupported = false
                attachmentsSupported = false
                contextSupported = false
                safeModelSettingsSupported = false
                journalEventSnapshotsSupported = false
                feedbackCapability = .unknown
                // A transient capability failure is not proof that this
                // companion lacks first-mate-links-v1, so keep the last known
                // answer instead of showing upgrade guidance mid-outage.
            }
            let list = try await client.fetchFirstMateFeatures(scope: showArchived ? .all : .active)
            guard capturedGeneration == generation else { return }
            guard list.ok else { throw APIError.invalidResponse }
            if !FirstMatePollPresentation.sameHealth(runtimeHealth, list.runtimeHealth) { runtimeHealth = list.runtimeHealth }
            let refreshedFeatures = list.features.map { feature in
                guard var cached = snapshots[feature.id]?.feature ?? features.first(where: { $0.id == feature.id }) else { return feature }
                cached.verification = latestVerifications[feature.id] ?? cached.verification
                if cached.revision > feature.revision || cached.updatedAt > feature.updatedAt {
                    var retained = cached
                    if let usage = feature.usage { retained.usage = usage }
                    return retained
                }
                var refreshed = feature
                if refreshed.usage == nil { refreshed.usage = cached.usage }
                refreshed.verification = Self.retainedVerification(
                    incoming: refreshed.verification,
                    includesField: refreshed.includesVerification,
                    cached: cached.verification,
                    incomingIsStale: Self.isStrictlyOlderTimestamp(refreshed.updatedAt, than: cached.updatedAt),
                    authoritative: true
                )
                refreshed.includesVerification = refreshed.includesVerification || cached.includesVerification
                return refreshed
            }
            for feature in refreshedFeatures { latestVerifications[feature.id] = feature.verification }
            if !FirstMatePollPresentation.sameFeatures(features, refreshedFeatures) { features = refreshedFeatures }
            reconcileSelection()
            if includeConversation, let id = selectedFeatureID {
                // Pi telemetry is most of a long-running feature's events and no
                // First Mate screen shows it.
                try await readConversation(id) { !Task.isCancelled && capturedGeneration == generation }
                guard capturedGeneration == generation else { return }
            }
            hasLoaded = true
            unsupported = false
            error = nil
            lastUpdated = .now
        } catch is CancellationError { return }
        catch {
            guard capturedGeneration == generation else { return }
            hasLoaded = true
            record(error)
        }
    }

    /// The chat window already has the fleet's list. Read its selected
    /// conversation directly, with a periodically renewed capability probe.
    /// A superseded read may finish, but cannot publish into a new selection,
    /// connection, or a newer request, even if its transport ignores cancel.
    func refreshConversation() async {
        guard !isDemo, let client, let featureID = selectedFeatureID else { return }
        let context = operationContext
        let requestID = UUID()
        conversationRefreshID = requestID
        func isCurrent() -> Bool {
            !Task.isCancelled && context == operationContext && conversationRefreshID == requestID
        }
        do {
            if capabilitiesCheckedAt.map({ Date.now.timeIntervalSince($0) >= 60 }) ?? true {
                do {
                    let capabilities = try await client.fetchFirstMateCapabilities()
                    guard isCurrent() else { return }
                    apply(capabilities)
                } catch {
                    guard isCurrent() else { return }
                    // An outage is not evidence that a known capability was
                    // removed. An unknown companion still gets the legacy GET.
                }
            }
            guard isCurrent() else { return }
            try await readConversation(featureID, isCurrent: isCurrent)
            guard isCurrent() else { return }
            hasLoaded = true
            unsupported = false
            error = nil
            if lastUpdated == nil { lastUpdated = .now }
        } catch is CancellationError { return }
        catch {
            guard isCurrent() else { return }
            hasLoaded = true
            record(error)
        }
    }

    private func readConversation(_ id: String, isCurrent: () -> Bool) async throws {
        guard let client else { return }
        let request = UUID()
        chatRequests[id] = request
        let version = snapshots[id] == nil ? nil : chatVersions[id]
        let response: FirstMatePresentationResponse
        if readViewsSupported {
            response = try await client.fetchFirstMatePresentation(id, view: .chat, before: nil, ifVersion: version)
        } else {
            response = .init(snapshot: try await client.fetchFirstMateFeature(id, journalEventsOnly: journalEventSnapshotsSupported))
        }
        guard isCurrent(), chatRequests[id] == request else { return }
        guard response.ok else { throw APIError.invalidResponse }
        if response.unchanged {
            guard let version, version == response.version, snapshots[id] != nil else { throw APIError.invalidResponse }
            if let health = response.runtimeHealth, !FirstMatePollPresentation.sameHealth(health, runtimeHealth) { runtimeHealth = health }
            return
        }
        guard var value = response.snapshot, value.feature.id == id else { throw APIError.invalidResponse }
        if let existing = snapshots[id] {
            guard existing.feature.revision <= value.feature.revision,
                  (existing.feature.modelSettingsRevision ?? 0) <= (value.feature.modelSettingsRevision ?? 0),
                  existing.latestEventSequence <= value.latestEventSequence else { return }
        }
        var cursor = response.nextBefore
        if response.version != nil, let existing = snapshots[id], let first = value.messages.first {
            // Keep pages the person already opened when the new tail overlaps
            // them. A gap resets pagination so history never silently skips rows.
            let incomingIDs = Set(value.messages.map(\.id))
            if existing.messages.contains(where: { incomingIDs.contains($0.id) }) {
                let older = existing.messages.filter {
                    !incomingIDs.contains($0.id) && ($0.createdAt < first.createdAt || ($0.createdAt == first.createdAt && $0.id < first.id))
                }
                if !older.isEmpty {
                    value.messages = older + value.messages
                    cursor = earlierMessageCursors[id]
                }
            }
        }
        receive(value, isPresentationRead: true)
        chatVersions[id] = response.version
        if earlierMessageCursors[id] != cursor { earlierMessageCursors[id] = cursor }
    }

    var inspectorReadView: FirstMateReadView { inspector == .overview ? .overview : .details }
    func inspectorKey(featureID: String, view: FirstMateReadView) -> String { "\(featureID)|\(view.rawValue)" }
    func inspectorSnapshot(featureID: String, view: FirstMateReadView) -> FirstMateSnapshot? {
        isDemo ? snapshots[featureID] : inspectorSnapshots[inspectorKey(featureID: featureID, view: view)]
    }

    /// This read never writes the chat snapshot. Overview can arrive before
    /// the transcript, and the heavier tabs load only when selected.
    func refreshInspector(featureID: String, view: FirstMateReadView) async {
        guard !isDemo, let client, view != .chat else { return }
        let context = operationContext
        let key = inspectorKey(featureID: featureID, view: view)
        let request = UUID()
        inspectorRequests[key] = request
        func isCurrent() -> Bool { !Task.isCancelled && context == operationContext && inspectorRequests[key] == request }
        do {
            if capabilitiesCheckedAt == nil {
                do {
                    let capabilities = try await client.fetchFirstMateCapabilities()
                    guard isCurrent() else { return }
                    apply(capabilities)
                } catch {
                    guard isCurrent() else { return }
                    // Unknown/older companions still get an independent legacy read.
                }
            }
            let response: FirstMatePresentationResponse
            if readViewsSupported {
                response = try await client.fetchFirstMatePresentation(featureID, view: view, before: nil, ifVersion: inspectorVersions[key])
            } else {
                response = .init(snapshot: try await client.fetchFirstMateFeature(featureID, journalEventsOnly: journalEventSnapshotsSupported))
            }
            guard isCurrent() else { return }
            guard response.ok else { throw APIError.invalidResponse }
            if response.unchanged {
                guard inspectorSnapshots[key] != nil, let version = response.version, version == inspectorVersions[key] else { throw APIError.invalidResponse }
            } else {
                guard let value = response.snapshot, value.feature.id == featureID else { throw APIError.invalidResponse }
                if let cached = inspectorSnapshots[key], cached.feature.revision > value.feature.revision || cached.latestEventSequence > value.latestEventSequence { return }
                if inspectorSnapshots[key].map({ !FirstMatePollPresentation.sameSnapshot($0, value) }) ?? true {
                    inspectorSnapshots[key] = value
                }
                inspectorVersions[key] = response.version
            }
            if inspectorErrors[key] != nil { inspectorErrors[key] = nil }
        } catch is CancellationError { return }
        catch {
            guard isCurrent() else { return }
            inspectorErrors[key] = error.localizedDescription
        }
    }

    func loadEarlierMessages() async {
        guard let id = selectedFeatureID, let cursor = earlierMessageCursors[id],
              !loadingEarlierMessages.contains(id), let client else { return }
        let context = operationContext
        let expectedCursor = cursor
        loadingEarlierMessages.insert(id)
        defer { if isCurrentLifecycle(context) { loadingEarlierMessages.remove(id) } }
        do {
            let response = try await client.fetchFirstMatePresentation(id, view: .chat, before: cursor, ifVersion: nil)
            guard !Task.isCancelled, context == operationContext, earlierMessageCursors[id] == expectedCursor else { return }
            guard response.ok, !response.unchanged, let page = response.snapshot, page.feature.id == id,
                  var current = snapshots[id] else { throw APIError.invalidResponse }
            // A page contributes history only. Its feature/verification cannot
            // replace newer state delivered by a simultaneous latest-page read.
            let ids = Set(current.messages.map(\.id))
            current.messages = (page.messages.filter { !ids.contains($0.id) } + current.messages).sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
            }
            if !FirstMatePollPresentation.sameSnapshot(snapshots[id]!, current) { snapshots[id] = current }
            earlierMessageCursors[id] = response.nextBefore
            earlierMessagesErrors[id] = nil
        } catch is CancellationError { return }
        catch {
            guard context == operationContext else { return }
            earlierMessagesErrors[id] = error.localizedDescription
        }
    }

    func create(title: String, goal: String, cwd: String, requestID: String, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        guard !isSending else { return false }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        if isDemo {
            let feature = FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd)
            receive(feature)
            select(feature.feature.id)
            return true
        }
        guard let client else { error = "Connect to a companion server to create a feature."; return false }
        do {
            let value = try await client.createFirstMateFeature(title: title, goal: goal, cwd: cwd, requestID: requestID)
            guard capturedGeneration == generation else { return false }
            guard value.ok, !value.feature.id.isEmpty else { throw APIError.invalidResponse }
            receive(value)
            select(value.feature.id)
            await refresh()
            return true
        } catch {
            guard capturedGeneration == generation else { return false }
            record(error)
            return false
        }
    }

    /// Receives a creation receipt without selecting it or starting an internal
    /// refresh. The caller owns navigation. Keep transport busy/error/lifecycle
    /// handling here rather than exposing mutable store internals to adapters.
    /// The existing Mac create method above deliberately retains its behavior.
    func receiveCreation(
        expectedContext: OperationContext,
        operation: @MainActor () async throws -> FirstMateSnapshot
    ) async -> FirstMateSnapshot? {
        guard expectedContext == operationContext, !isSending, !Task.isCancelled else { return nil }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await operation()
            guard capturedGeneration == generation else { return nil }
            guard value.ok, !value.feature.id.isEmpty else { throw APIError.invalidResponse }
            // Even if navigation moved elsewhere, the confirmed record belongs
            // in this exact live owner's cache. receive never selects it.
            receive(value)
            if expectedContext == operationContext { error = nil }
            return value
        } catch {
            guard capturedGeneration == generation, expectedContext == operationContext, !Task.isCancelled else { return nil }
            record(error)
            return nil
        }
    }

    func send(expectedContext: OperationContext? = nil, expectedText: String? = nil) async {
        if let expectedContext, expectedContext != operationContext { return }
        if let expectedText, expectedText != draft { return }
        let originalDraft = draft
        let text = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let context = expectedContext ?? operationContext
        guard await sendPreparedMessage(text, expectedContext: context),
              let id = context.featureID else { return }
        if context == operationContext, draft == originalDraft { draft = "" }
        if drafts[id] == originalDraft { drafts[id] = nil }
    }

    /// Sends a fully serialized composer payload. Callers own draft, attachment,
    /// and quote clearing so only the exact accepted items are removed.
    func sendPreparedMessage(_ text: String, expectedContext: OperationContext) async -> Bool {
        guard expectedContext == operationContext,
              let id = expectedContext.featureID,
              !isSending,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isDemo {
            sendDemo(text, featureID: id)
            return true
        }
        guard let client else {
            error = "Connect to send your direction."
            return false
        }
        let pending = pendingMessages[id].flatMap { $0.text == text ? $0 : nil }
            ?? (text: text, requestID: UUID().uuidString)
        pendingMessages[id] = pending
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        let context = id == leadFeatureID
            ? pendingLeadContexts[pending.requestID] ?? leadContextProvider?()
            : nil
        if let context { pendingLeadContexts[pending.requestID] = context }
        do {
            let value = if let context {
                try await client.sendFirstMateMessage(featureID: id, text: text, requestID: pending.requestID, context: context)
            } else {
                try await client.sendFirstMateMessage(featureID: id, text: text, requestID: pending.requestID)
            }
            guard capturedGeneration == generation, expectedContext.generation == generation else { return false }
            guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
            receive(value)
            pendingMessages[id] = nil
            pendingLeadContexts[pending.requestID] = nil
            error = nil
            await refresh()
            return capturedGeneration == generation && expectedContext.generation == generation
        } catch {
            guard capturedGeneration == generation else { return false }
            record(error)
            return false
        }
    }

    // MARK: - Optimistic outgoing messages

    /// Validates and reserves one submission for immediate presentation.
    ///
    /// The reservation is created synchronously, before any transport starts,
    /// so the caller can clear the submitted composer material and begin the
    /// request afterwards. It returns nil for a foreign, closed, or otherwise
    /// unready destination, an empty payload, another operation already using
    /// this store, or a submission already in flight for this feature; an
    /// invalid call never consumes content.
    func beginOutgoingMessage(
        _ text: String,
        expectedContext: OperationContext,
        submission: FirstMateOutgoingMessage.Submission? = nil
    ) -> FirstMateOutgoingMessage.Handle? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expectedContext == operationContext,
              isCurrentLifecycle(expectedContext),
              let featureID = expectedContext.featureID,
              !isSending,
              !trimmed.isEmpty,
              isDemo || client != nil,
              isDestinationAlive(expectedContext),
              !(snapshots[featureID].map { ["completed", "cancelled"].contains($0.feature.status) } ?? false),
              !(outgoingMessages[featureID]?.contains { $0.state.isPending } ?? false) else { return nil }
        let message = FirstMateOutgoingMessage(
            id: FirstMateOutgoingMessage.makeLocalID(),
            featureID: featureID,
            requestID: UUID().uuidString,
            text: text,
            createdAt: HerdrTimestamp.string(from: .now),
            baselineMessageIDs: Set((snapshots[featureID]?.messages ?? []).map(\.id)),
            leadContext: featureID == leadFeatureID ? leadContextProvider?() : nil,
            submission: submission,
            state: .pending,
            acceptedStatus: nil
        )
        outgoingMessages[featureID, default: []].append(message)
        return FirstMateOutgoingMessage.Handle(
            outgoingID: message.id,
            requestID: message.requestID,
            featureID: featureID,
            context: expectedContext
        )
    }

    /// Runs the transport for a reservation created by ``beginOutgoingMessage``.
    ///
    /// A confirmed receipt is recorded without waiting for any follow-up
    /// refresh; a follow-up poll only retires the local row when the
    /// authoritative conversation includes it. Returns the resulting state, or
    /// nil when the reservation no longer belongs to this store lifecycle.
    @discardableResult
    func completeOutgoingMessage(
        _ handle: FirstMateOutgoingMessage.Handle
    ) async -> FirstMateOutgoingMessage.State? {
        await transportOutgoingMessage(handle, isRetry: false)
    }

    /// Explicitly retries a failed or unconfirmed reservation with its
    /// original payload, request identity, and frozen lead context. Nothing
    /// retries automatically, and an in-flight or accepted submission is
    /// never resent.
    @discardableResult
    func retryOutgoingMessage(
        _ handle: FirstMateOutgoingMessage.Handle
    ) async -> FirstMateOutgoingMessage.State? {
        await transportOutgoingMessage(handle, isRetry: true)
    }

    /// Explicitly abandons a failed submission without resending it, returning
    /// its frozen composer material so a caller can restore untouched content.
    /// Returns nil when the reservation is unknown or not a failure.
    @discardableResult
    func discardOutgoingMessage(
        _ handle: FirstMateOutgoingMessage.Handle
    ) -> FirstMateOutgoingMessage.Submission? {
        guard isCurrentLifecycle(handle.context),
              var entries = outgoingMessages[handle.featureID],
              let index = entries.firstIndex(where: { $0.id == handle.outgoingID && $0.requestID == handle.requestID }),
              entries[index].state.isRetryable else { return nil }
        let submission = entries[index].submission
        entries.remove(at: index)
        outgoingMessages[handle.featureID] = entries.isEmpty ? nil : entries
        return submission
    }

    /// This feature's outgoing submissions, in submission order.
    func outgoingMessages(for featureID: String) -> [FirstMateOutgoingMessage] {
        outgoingMessages[featureID] ?? []
    }

    /// One exact reservation, or nil when its store lifecycle has moved on.
    func outgoingMessage(_ handle: FirstMateOutgoingMessage.Handle) -> FirstMateOutgoingMessage? {
        guard isCurrentLifecycle(handle.context) else { return nil }
        return outgoingMessages[handle.featureID]?.first {
            $0.id == handle.outgoingID && $0.requestID == handle.requestID
        }
    }

    /// The newest red send error for this feature, from a definite rejection
    /// or an unconfirmed transport result. It stays separate from ``error``,
    /// which carries refresh and other operation failures, so a successful
    /// poll can never erase an unresolved send error.
    func sendFailure(for featureID: String) -> FirstMateOutgoingMessage? {
        outgoingMessages[featureID]?.last { $0.state.isFailure }
    }

    /// True while this exact feature has a transport request in flight.
    func isSubmitting(featureID: String) -> Bool {
        outgoingMessages[featureID]?.contains { $0.state.isPending } ?? false
    }

    /// True while a submission for this feature is still awaiting its
    /// authoritative row. Submission-related working feedback belongs after
    /// the local row and stops on a failure.
    func isAwaitingSendResolution(featureID: String) -> Bool {
        guard let entries = outgoingMessages[featureID], !entries.isEmpty else { return false }
        let messages = (snapshots[featureID]?.messages ?? []).filter(\.isConversation)
        let matches = FirstMateOutgoingMessage.provisionalMatches(outgoing: entries, messages: messages)
        return entries.contains { entry in
            (entry.state.isPending || entry.state.isAcceptedAwaitingSnapshot)
                && !isOutgoingResolved(entry, in: messages, matches: matches)
        }
    }

    /// The conversation rows to show for one snapshot: the authoritative
    /// conversation plus honest local rows for submissions it has not
    /// reflected yet. Local rows are appended last, so working feedback that
    /// follows the transcript can never appear ahead of them.
    func conversationMessages(for snapshot: FirstMateSnapshot) -> [FirstMateMessage] {
        var messages = snapshot.messages.filter(\.isConversation)
        guard let entries = outgoingMessages[snapshot.feature.id], !entries.isEmpty else { return messages }
        let matches = FirstMateOutgoingMessage.provisionalMatches(outgoing: entries, messages: messages)
        for entry in entries where !isOutgoingResolved(entry, in: messages, matches: matches) {
            messages.append(entry.localMessage)
        }
        return messages
    }

    /// The same projection grouped into conversation turns.
    func conversationEntries(for snapshot: FirstMateSnapshot) -> [FirstMateConversationEntry] {
        FirstMateConversationEntry.make(messages: conversationMessages(for: snapshot))
    }

    /// The newest authoritative conversation message ID, for read markers and
    /// feedback. Local presentation IDs never appear here.
    func newestServerMessageID(for snapshot: FirstMateSnapshot) -> String? {
        snapshot.messages.last { $0.isConversation }?.id
    }

    /// Refreshes one exact feature in the captured lifecycle. It never changes
    /// the selection and never clears a send failure: a failed poll only
    /// records the ordinary refresh error.
    func refreshFeature(_ context: OperationContext) async {
        guard !isDemo, isCurrentLifecycle(context), let featureID = context.featureID, let client else { return }
        do {
            try await readConversation(featureID) { !Task.isCancelled && self.isCurrentLifecycle(context) }
            guard isCurrentLifecycle(context) else { return }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLifecycle(context) else { return }
            record(error)
        }
    }

    private func isCurrentLifecycle(_ context: OperationContext) -> Bool {
        context.generation == generation && context.lifecycleIdentity == lifecycleIdentity
    }

    private func transportOutgoingMessage(
        _ handle: FirstMateOutgoingMessage.Handle,
        isRetry: Bool
    ) async -> FirstMateOutgoingMessage.State? {
        guard isCurrentLifecycle(handle.context),
              handle.context.featureID == handle.featureID,
              var entries = outgoingMessages[handle.featureID],
              let index = entries.firstIndex(where: { $0.id == handle.outgoingID && $0.requestID == handle.requestID }) else {
            return nil
        }
        if isRetry {
            guard entries[index].state.isRetryable else { return entries[index].state }
            entries[index].state = .pending
        } else {
            // A second completion for the same reservation (or a completion
            // for an already-finished one) must never send a duplicate.
            guard entries[index].state.isPending else { return entries[index].state }
        }
        outgoingMessages[handle.featureID] = entries
        let entry = entries[index]

        if isDemo {
            sendDemo(entry.text, featureID: handle.featureID)
            return recordOutgoingAcceptance(handle, receipt: nil)
        }
        guard let client else {
            return recordOutgoingFailure(
                handle,
                state: .failed(message: "Connect to send your direction.")
            )
        }
        do {
            let value: FirstMateSnapshot
            if handle.featureID == leadFeatureID, let leadContext = entry.leadContext {
                value = try await client.sendFirstMateMessage(
                    featureID: handle.featureID,
                    text: entry.text,
                    requestID: entry.requestID,
                    context: leadContext
                )
            } else {
                value = try await client.sendFirstMateMessage(
                    featureID: handle.featureID,
                    text: entry.text,
                    requestID: entry.requestID
                )
            }
            guard isCurrentLifecycle(handle.context) else { return nil }
            guard value.ok, value.feature.id == handle.featureID else {
                return recordOutgoingFailure(handle, state: Self.outgoingFailureState(for: APIError.invalidResponse))
            }
            receive(value)
            guard isCurrentLifecycle(handle.context) else { return nil }
            return recordOutgoingAcceptance(handle, receipt: value.message)
        } catch is CancellationError {
            guard isCurrentLifecycle(handle.context) else { return nil }
            return recordOutgoingFailure(handle, state: .deliveryUnconfirmed(
                message: "Delivery could not be confirmed. Sending was interrupted."
            ))
        } catch {
            guard isCurrentLifecycle(handle.context) else { return nil }
            return recordOutgoingFailure(handle, state: Self.outgoingFailureState(for: error))
        }
    }

    @discardableResult
    private func recordOutgoingAcceptance(
        _ handle: FirstMateOutgoingMessage.Handle,
        receipt: FirstMateMessage?
    ) -> FirstMateOutgoingMessage.State? {
        guard isCurrentLifecycle(handle.context),
              var entries = outgoingMessages[handle.featureID],
              let index = entries.firstIndex(where: { $0.id == handle.outgoingID && $0.requestID == handle.requestID }) else {
            return nil
        }
        let messageID = receipt.flatMap { $0.id.isEmpty ? nil : $0.id }
        entries[index].state = .acceptedAwaitingSnapshot(messageID: messageID)
        entries[index].acceptedStatus = FirstMateOutgoingMessage.advancingStatus(
            entries[index].acceptedStatus,
            to: receipt?.status
        )
        outgoingMessages[handle.featureID] = entries
        // A poll may already have shown the accepted row while the receipt was
        // delayed: keep its newer status instead of the receipt's older one.
        reconcileOutgoingMessages(for: handle.featureID)
        return outgoingMessages[handle.featureID]?[index].state
    }

    @discardableResult
    private func recordOutgoingFailure(
        _ handle: FirstMateOutgoingMessage.Handle,
        state: FirstMateOutgoingMessage.State
    ) -> FirstMateOutgoingMessage.State? {
        guard isCurrentLifecycle(handle.context),
              var entries = outgoingMessages[handle.featureID],
              let index = entries.firstIndex(where: { $0.id == handle.outgoingID && $0.requestID == handle.requestID }) else {
            return nil
        }
        entries[index].state = state
        outgoingMessages[handle.featureID] = entries
        return state
    }

    /// Conservative, display-only: a receipt identity or a one-to-one
    /// provisional match records the canonical row's status so a later
    /// receipt can never roll it back.
    private func reconcileOutgoingMessages(for featureID: String) {
        guard var entries = outgoingMessages[featureID], !entries.isEmpty,
              let snapshot = snapshots[featureID] else { return }
        let messages = snapshot.messages.filter(\.isConversation)
        let matches = FirstMateOutgoingMessage.provisionalMatches(outgoing: entries, messages: messages)
        var changed = false
        for index in entries.indices {
            let observedID = entries[index].acknowledgedMessageID ?? matches[entries[index].id]
            guard let observedID, let message = messages.first(where: { $0.id == observedID }) else { continue }
            let advanced = FirstMateOutgoingMessage.advancingStatus(entries[index].acceptedStatus, to: message.status)
            if advanced != entries[index].acceptedStatus {
                entries[index].acceptedStatus = advanced
                changed = true
            }
        }
        if changed { outgoingMessages[featureID] = entries }
    }

    private func isOutgoingResolved(
        _ entry: FirstMateOutgoingMessage,
        in messages: [FirstMateMessage],
        matches: [String: String]
    ) -> Bool {
        if let messageID = entry.acknowledgedMessageID,
           messages.contains(where: { $0.id == messageID }) { return true }
        return matches[entry.id] != nil
    }

    /// A definite rejection keeps its ordinary error text; an uncertain
    /// transport result explicitly says delivery was not confirmed. Only a
    /// 4xx (or an unimplemented route) is treated as a rejection.
    private static func outgoingFailureState(for error: Error) -> FirstMateOutgoingMessage.State {
        if case let APIError.server(status, _) = error, status < 500 || status == 501 {
            return .failed(message: error.localizedDescription)
        }
        return .deliveryUnconfirmed(message: "Delivery could not be confirmed. \(error.localizedDescription)")
    }

    func uploadAttachment(
        at fileURL: URL,
        contentType: String,
        expectedContext: OperationContext
    ) async throws -> UploadedAttachment {
        guard expectedContext == operationContext,
              let featureID = expectedContext.featureID,
              attachmentsSupported,
              let client else { throw APIError.invalidResponse }
        let capturedGeneration = generation
        let response = try await client.uploadFirstMateAttachment(
            featureID: featureID,
            fileURL: fileURL,
            contentType: contentType
        )
        guard capturedGeneration == generation,
              expectedContext.generation == generation,
              response.ok,
              let attachment = response.attachment else { throw APIError.invalidResponse }
        return attachment
    }

    func transcribeVoice(
        at fileURL: URL,
        expectedContext: OperationContext
    ) async throws -> VoiceTranscriptionResponse {
        guard expectedContext == operationContext, let client else { throw APIError.invalidResponse }
        let capturedGeneration = generation
        let response = try await client.transcribeFirstMateVoice(fileURL: fileURL)
        guard capturedGeneration == generation, expectedContext.generation == generation, response.ok else {
            throw APIError.invalidResponse
        }
        return response
    }

    func isDestinationAlive(_ context: OperationContext) -> Bool {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return false }
        return snapshots[featureID] != nil || features.contains { $0.id == featureID }
    }

    func snapshot(for context: OperationContext) -> FirstMateSnapshot? {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity,
              let featureID = context.featureID else { return nil }
        return snapshots[featureID]
    }

    func feature(for context: OperationContext) -> FirstMateFeature? {
        guard context.generation == generation,
              context.lifecycleIdentity == lifecycleIdentity else { return nil }
        return snapshot(for: context)?.feature
            ?? features.first { context.matchesFeature($0.id) }
    }

    func perform(_ action: String, expectedContext: OperationContext? = nil) async {
        if let expectedContext, expectedContext != operationContext { return }
        guard let id = selectedFeatureID, !isSending else { return }
        if isDemo {
            guard var value = snapshot else { return }
            value.feature.status = action == "pause" ? "paused" : action == "cancel" ? "cancelled" : "awaiting_direction"
            value.feature.revision += 1
            receive(value)
            return
        }
        guard let client else { return }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.performFirstMateAction(featureID: id, action: action, requestID: UUID().uuidString)
            guard capturedGeneration == generation else { return }
            guard value.ok, value.feature.id == id else { throw APIError.invalidResponse }
            receive(value)
            error = nil
            await refresh()
        } catch { if capturedGeneration == generation { record(error) } }
    }

    func setArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason? = nil) async -> Bool {
        guard !isSending else { return false }
        if isDemo {
            guard var value = snapshots[featureID] else { return false }
            value.feature.archivedAt = archived ? FirstMateDemo.timestamp : nil
            value.feature.archiveReason = archived ? reason?.rawValue : nil
            receive(value)
            if archived && !showArchived { features.removeAll { $0.id == featureID } }
            reconcileSelection()
            return true
        }
        guard archiveSupported else {
            error = "Update this companion server to archive First Mate features."
            return false
        }
        guard let client else { error = "Connect to archive this feature."; return false }
        let capturedGeneration = generation
        isSending = true
        defer { if capturedGeneration == generation { isSending = false } }
        do {
            let value = try await client.setFirstMateArchived(
                featureID: featureID,
                archived: archived,
                reason: archived ? reason : nil,
                requestID: UUID().uuidString
            )
            guard capturedGeneration == generation, value.ok, value.feature.id == featureID else {
                throw APIError.invalidResponse
            }
            receive(value)
            if archived && !showArchived {
                features.removeAll { $0.id == featureID }
                reconcileSelection()
            }
            error = nil
            await refresh()
            return true
        } catch {
            if capturedGeneration == generation { record(error) }
            return false
        }
    }

    /// Explicitly saves one PR or general HTTP(S) link to this feature.
    ///
    /// The caller's captured context fences the whole operation: a delayed
    /// response can only update the feature it was requested for, never a
    /// newly selected feature or a replacement host. A failed attempt keeps
    /// its request identity so an explicit retry is idempotent.
    @discardableResult
    func saveLink(_ draft: FirstMateLinkDraft, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        let context = expectedContext ?? operationContext
        guard let featureID = context.featureID, !isSavingLink else { return false }
        guard let normalized = FirstMateLinkClassifier.normalize(url: draft.url, title: draft.title, kind: draft.kind) else {
            if context == operationContext {
                linkMutationError = "Enter an absolute http or https URL without credentials."
            }
            return false
        }
        if isDemo {
            applyDemoLink(normalized, featureID: featureID)
            if context == operationContext { linkMutationError = nil }
            return true
        }
        guard controlAvailable else {
            if context == operationContext { linkMutationError = "This First Mate view does not currently control this feature." }
            return false
        }
        guard linksSupported else {
            if context == operationContext { linkMutationError = Self.linksUpgradeMessage }
            return false
        }
        guard let client else {
            if context == operationContext { linkMutationError = "Connect to this companion to save links." }
            return false
        }
        let pending = pendingLinkSaves[featureID].flatMap { $0.draft == draft ? $0 : nil }
            ?? (draft: draft, requestID: UUID().uuidString)
        pendingLinkSaves[featureID] = pending
        let capturedGeneration = generation
        isSavingLink = true
        defer { if capturedGeneration == generation { isSavingLink = false } }
        do {
            let response = try await client.saveFirstMateLink(
                featureID: featureID,
                url: normalized.url,
                title: normalized.titleSupplied ? normalized.title : nil,
                kind: draft.kind,
                requestID: pending.requestID
            )
            guard capturedGeneration == generation,
                  response.ok,
                  response.snapshot.feature.id == featureID else { throw APIError.invalidResponse }
            receive(response.snapshot)
            pendingLinkSaves[featureID] = nil
            if context == operationContext { linkMutationError = nil }
            return capturedGeneration == generation
        } catch {
            guard capturedGeneration == generation else { return false }
            if context == operationContext { linkMutationError = Self.linkFailureMessage(error) }
            return false
        }
    }

    /// Reversibly hides or restores one feature-owned link.
    @discardableResult
    func setLinkHidden(_ linkID: String, hidden: Bool, expectedContext: OperationContext? = nil) async -> Bool {
        if let expectedContext, expectedContext != operationContext { return false }
        let context = expectedContext ?? operationContext
        guard let featureID = context.featureID, !isSavingLink,
              let link = (inspectorSnapshot(featureID: featureID, view: .details)
                  ?? inspectorSnapshot(featureID: featureID, view: .overview)
                  ?? snapshots[featureID])?.link(linkID),
              link.featureID == featureID else { return false }
        if isDemo {
            applyDemoVisibility(linkID, hidden: hidden, featureID: featureID)
            if context == operationContext { linkMutationError = nil }
            return true
        }
        guard controlAvailable else {
            if context == operationContext { linkMutationError = "This First Mate view does not currently control this feature." }
            return false
        }
        guard linksSupported else {
            if context == operationContext { linkMutationError = Self.linksUpgradeMessage }
            return false
        }
        guard let client else {
            if context == operationContext { linkMutationError = "Connect to this companion to change links." }
            return false
        }
        let pendingKey = "\(featureID)|\(linkID)|\(hidden)"
        let requestID = pendingLinkVisibility[pendingKey] ?? UUID().uuidString
        pendingLinkVisibility[pendingKey] = requestID
        let capturedGeneration = generation
        isSavingLink = true
        defer { if capturedGeneration == generation { isSavingLink = false } }
        do {
            let response = try await client.setFirstMateLinkVisibility(
                featureID: featureID,
                linkID: linkID,
                hidden: hidden,
                requestID: requestID
            )
            guard capturedGeneration == generation,
                  response.ok,
                  response.snapshot.feature.id == featureID else { throw APIError.invalidResponse }
            receive(response.snapshot)
            pendingLinkVisibility[pendingKey] = nil
            if context == operationContext { linkMutationError = nil }
            return capturedGeneration == generation
        } catch {
            guard capturedGeneration == generation else { return false }
            if context == operationContext { linkMutationError = Self.linkFailureMessage(error) }
            return false
        }
    }

    static let linksUpgradeMessage = "Saving links needs a companion server advertising first-mate-links-v1. Update and restart the companion, then Refresh."

    private static func linkFailureMessage(_ error: Error) -> String {
        if case let APIError.server(status, _) = error, status == 404 || status == 501 {
            return linksUpgradeMessage
        }
        return error.localizedDescription
    }

    private func applyDemoLink(_ normalized: FirstMateNormalizedLink, featureID: String) {
        guard var value = snapshots[featureID] else { return }
        if let index = value.links.firstIndex(where: { $0.url == normalized.url }) {
            if normalized.titleSupplied, value.links[index].titleSource != "user" {
                value.links[index].title = normalized.title
                value.links[index].titleSource = "user"
                receive(value)
            }
            return
        }
        value.links.append(FirstMateLink(
            id: "demo-link-\(UUID().uuidString.lowercased())",
            featureID: featureID,
            url: normalized.url,
            kind: normalized.kind,
            title: normalized.title,
            titleSource: normalized.titleSupplied ? "user" : "",
            source: "user",
            provenance: .init(),
            hidden: false,
            createdAt: FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp
        ))
        receive(value)
    }

    private func applyDemoVisibility(_ linkID: String, hidden: Bool, featureID: String) {
        guard var value = snapshots[featureID],
              let index = value.links.firstIndex(where: { $0.id == linkID }) else { return }
        value.links[index].hidden = hidden
        value.links[index].updatedAt = FirstMateDemo.timestamp
        receive(value)
    }

    func fetchModelCatalog(expectedContext: OperationContext) async throws -> FirstMateModelCatalog {
        guard expectedContext == operationContext else { throw APIError.invalidResponse }
        if isDemo { return FirstMateDemo.modelCatalog }
        guard let client else { throw APIError.invalidResponse }
        let catalog = try await client.fetchFirstMateModels()
        guard expectedContext == operationContext, catalog.ok else { throw APIError.invalidResponse }
        return catalog
    }

    func reportComposerError(_ message: String) {
        error = message
    }

    func saveModelSettings(
        _ settings: FirstMateModelSettings,
        expectedContext: OperationContext,
        expectedSessionID: String? = nil,
        expectedSettingsRevision: Int? = nil
    ) async throws {
        guard expectedContext == operationContext, let id = selectedFeatureID,
              !isDemo, !isSending, let client else { throw APIError.invalidResponse }
        if let expectedSettingsRevision {
            guard let current = feature(for: expectedContext),
                  current.nativeSessionID == expectedSessionID,
                  current.modelSettingsRevision == expectedSettingsRevision else {
                throw APIError.invalidResponse
            }
        }
        let capturedGeneration = generation
        isSending = true
        defer { if generation == capturedGeneration { isSending = false } }
        let value = try await client.setFirstMateModel(featureID: id, settings: settings)
        guard generation == capturedGeneration,
              expectedContext.generation == generation,
              value.ok,
              value.feature.id == id else { throw APIError.invalidResponse }
        receive(value)
    }

    // MARK: - Response feedback

    /// A companion's low-quality reason catalog, loaded only from a server that
    /// advertises `first-mate-feedback-v1`. Categories are append-only, so a
    /// delayed read merges by stable ID instead of replacing newer additions,
    /// and `feedbackCategoriesLoaded` becomes true only after a full fetch.
    @discardableResult
    func loadFeedbackCategories(expectedContext: OperationContext) async -> Bool {
        guard isCurrentFeedbackContext(expectedContext), feedbackSupported, !isDemo,
              !isLoadingFeedbackCategories, let client else { return false }
        isLoadingFeedbackCategories = true
        feedbackCategoriesError = nil
        defer { if isCurrentFeedbackContext(expectedContext) { isLoadingFeedbackCategories = false } }
        do {
            let response = try await client.fetchFirstMateFeedbackCategories()
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            guard response.ok, response.categories.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }) else {
                throw APIError.invalidResponse
            }
            for category in response.categories { mergeFeedbackCategory(category) }
            feedbackCategoriesLoaded = true
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            feedbackCategoriesError = error.localizedDescription
            return false
        }
    }

    /// Loads every retained rating for one exact feature. A delayed completion
    /// updates only the feature it was captured for, and a lower revision can
    /// never replace a newer local record. Returns false when the full fetch
    /// did not succeed so callers can distinguish loaded from partial state.
    @discardableResult
    func loadFeedback(expectedContext: OperationContext) async -> Bool {
        guard let featureID = expectedContext.featureID,
              isCurrentFeedbackContext(expectedContext), feedbackSupported, !isDemo,
              !loadingFeedbackFeatures.contains(featureID), let client else { return false }
        loadingFeedbackFeatures.insert(featureID)
        feedbackErrors[featureID] = nil
        defer { if isCurrentFeedbackContext(expectedContext) { loadingFeedbackFeatures.remove(featureID) } }
        do {
            let response = try await client.fetchFirstMateFeedback(featureID: featureID)
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            guard response.ok, response.featureID == featureID,
                  response.records.allSatisfy({ $0.featureID == featureID && !$0.messageID.isEmpty }) else {
                throw APIError.invalidResponse
            }
            for record in response.records { receiveFeedback(record, featureID: featureID) }
            loadedFeedbackFeatures.insert(featureID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentFeedbackContext(expectedContext) else { return false }
            feedbackErrors[featureID] = error.localizedDescription
            return false
        }
    }

    /// Saves the editor draft for one exact response. The draft's pinned base
    /// revision is the only base used, so a refresh that arrives mid-edit can
    /// never silently authorize an overwrite; a stale revision is surfaced as
    /// a conflict for explicit reload-and-retry recovery. Safe retries reuse
    /// the failed request identity, and a failure keeps both the known record
    /// and the editable draft intact.
    @discardableResult
    func saveFeedback(
        _ draft: FirstMateFeedbackDraft,
        messageID: String,
        expectedContext: OperationContext
    ) async -> Bool {
        guard let featureID = expectedContext.featureID,
              isCurrentFeedbackContext(expectedContext),
              !messageID.isEmpty else { return false }
        let key = FeedbackKey(featureID, messageID)
        guard !savingFeedbackKeys.contains(key) else { return false }
        // The typed draft is retained before any write attempt so a rejection or
        // failure can restore the editable explanation with a visible retry.
        // Editor drafts already carry the pin their load established; a nil
        // base revision means a quick action, which is pinned once at
        // submission time from the record the user could see.
        var retainedDraft = draft
        if retainedDraft.baseRevision == nil {
            retainedDraft.baseRevision = feedbackRecords[featureID]?[messageID]?.revision ?? 0
        }
        feedbackDrafts[key] = retainedDraft
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
        let requestDraft = retainedDraft.forRequest
        switch feedbackCapability {
        case .unsupported:
            feedbackSaveErrors[key] = "Update this companion server to rate First Mate responses."
            return false
        case .unknown:
            // A failed or unanswered capability check is a temporary
            // connection problem: keep the draft and retry path, and never
            // claim the server needs an update it may already have.
            feedbackSaveErrors[key] = "Connect to this feature's host to save feedback."
            return false
        case .supported:
            break
        }
        // Writes revalidate the control grant; reads do not need it.
        guard controlAvailable else {
            feedbackSaveErrors[key] = "This workspace is read-only right now."
            return false
        }
        if isDemo {
            feedbackDrafts[key] = nil
            feedbackSaveErrors[key] = nil
            feedbackConflicts.remove(key)
            receiveFeedback(demoFeedback(from: requestDraft, featureID: featureID, messageID: messageID), featureID: featureID)
            return true
        }
        guard let client else {
            feedbackSaveErrors[key] = "Connect to this feature's host to save feedback."
            return false
        }
        let expectedRevision = retainedDraft.baseRevision ?? 0
        var request = FirstMateFeedbackSaveRequest(
            rating: requestDraft.rating,
            categoryIDs: requestDraft.categoryIDs,
            comment: requestDraft.comment,
            expectedRevision: expectedRevision,
            requestID: ""
        )
        if let pending = pendingFeedbackRequests[key], pending.hasSamePayload(as: request) {
            request = pending
        } else {
            request.requestID = UUID().uuidString
            pendingFeedbackRequests[key] = request
        }
        let capturedGeneration = generation
        let capturedLifecycle = lifecycleIdentity
        savingFeedbackKeys.insert(key)
        defer {
            if capturedGeneration == generation, capturedLifecycle == lifecycleIdentity {
                savingFeedbackKeys.remove(key)
            }
        }
        do {
            let response = try await client.saveFirstMateFeedback(
                featureID: featureID,
                messageID: messageID,
                request: request
            )
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return false }
            guard response.ok, response.featureID == featureID,
                  response.feedback.featureID == featureID,
                  response.feedback.messageID == messageID else { throw APIError.invalidResponse }
            receiveFeedback(response.feedback, featureID: featureID)
            pendingFeedbackRequests[key] = nil
            feedbackDrafts[key] = nil
            feedbackSaveErrors[key] = nil
            feedbackConflicts.remove(key)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return false }
            // The known record and the typed draft stay available for an
            // explicit retry; the saved rating is never optimistically changed.
            feedbackSaveErrors[key] = error.localizedDescription
            if Self.isStaleRevisionError(error) { feedbackConflicts.insert(key) }
            return false
        }
    }

    /// Explicit resolution for a stale-revision rejection. Reloads the exact
    /// feature's retained ratings, then rebases only the preserved local draft
    /// onto the newly loaded revision so a deliberate retry uses the new
    /// revision and a fresh request identity. The attempted up/clear payload
    /// is kept exactly as submitted.
    @discardableResult
    func resolveFeedbackConflict(
        messageID: String,
        expectedContext: OperationContext
    ) async -> Bool {
        guard let featureID = expectedContext.featureID,
              isCurrentFeedbackContext(expectedContext),
              !messageID.isEmpty else { return false }
        guard await loadFeedback(expectedContext: expectedContext) else { return false }
        guard isCurrentFeedbackContext(expectedContext) else { return false }
        let key = FeedbackKey(featureID, messageID)
        var draft = feedbackDrafts[key] ?? feedbackDraft(for: featureID, messageID: messageID)
        draft.baseRevision = feedbackRecords[featureID]?[messageID]?.revision ?? 0
        feedbackDrafts[key] = draft
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
        return true
    }

    /// Immediate positive rating, used by the thumbs-up control.
    @discardableResult
    func rateFeedback(
        _ rating: FirstMateFeedbackRating,
        messageID: String,
        expectedContext: OperationContext
    ) async -> Bool {
        await saveFeedback(
            FirstMateFeedbackDraft(rating: rating),
            messageID: messageID,
            expectedContext: expectedContext
        )
    }

    /// Adds a reusable reason and returns it, reusing an equivalent category.
    @discardableResult
    func addFeedbackCategory(
        label rawLabel: String,
        expectedContext: OperationContext
    ) async -> FirstMateFeedbackCategory? {
        guard isCurrentFeedbackContext(expectedContext) else { return nil }
        switch feedbackCapability {
        case .unsupported:
            feedbackCategoriesError = "Update this companion server to add feedback reasons."
            return nil
        case .unknown:
            feedbackCategoriesError = "Connect to this feature's host to add a reason."
            return nil
        case .supported:
            break
        }
        guard controlAvailable else {
            feedbackCategoriesError = "This workspace is read-only right now."
            return nil
        }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !label.contains(where: { $0.isNewline }),
              label.unicodeScalars.count <= 80 else {
            feedbackCategoriesError = "Enter a single-line reason of 80 characters or fewer."
            return nil
        }
        if isDemo { return demoCategory(named: label) }
        guard !isAddingFeedbackCategory, let client else {
            feedbackCategoriesError = "Connect to this feature's host to add a reason."
            return nil
        }
        let capturedGeneration = generation
        let capturedLifecycle = lifecycleIdentity
        isAddingFeedbackCategory = true
        defer {
            if capturedGeneration == generation, capturedLifecycle == lifecycleIdentity {
                isAddingFeedbackCategory = false
            }
        }
        do {
            let response = try await client.createFirstMateFeedbackCategory(
                label: label,
                requestID: UUID().uuidString
            )
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return nil }
            guard response.ok, !response.category.id.isEmpty, !response.category.label.isEmpty else {
                throw APIError.invalidResponse
            }
            mergeFeedbackCategory(response.category)
            // A single-category response is not a full catalog: keep the
            // loaded flag reserved for a successful full fetch so the editor
            // can offer a category reload until the complete list is known.
            feedbackCategoriesError = nil
            return response.category
        } catch is CancellationError {
            return nil
        } catch {
            guard capturedGeneration == generation, capturedLifecycle == lifecycleIdentity else { return nil }
            feedbackCategoriesError = error.localizedDescription
            return nil
        }
    }

    func feedback(for featureID: String, messageID: String) -> FirstMateFeedback? {
        feedbackRecords[featureID]?[messageID]
    }

    /// The editor's starting point: an unsaved draft if one exists, otherwise
    /// the loaded record pinned to its retained revision, otherwise an
    /// unselected negative rating. A draft is never seeded from the empty cache
    /// before the first load completes, and a completed fetch that found no
    /// record pins revision zero so a delayed first rating conflicts instead of
    /// authorizing a silent overwrite.
    func feedbackDraft(for featureID: String, messageID: String) -> FirstMateFeedbackDraft {
        let key = FeedbackKey(featureID, messageID)
        if let draft = feedbackDrafts[key] { return draft }
        guard hasLoadedFeedback(for: featureID) else { return FirstMateFeedbackDraft() }
        if let record = feedbackRecords[featureID]?[messageID] {
            return FirstMateFeedbackDraft(
                rating: record.rating ?? .down,
                categoryIDs: record.categoryIDs,
                comment: record.comment,
                baseRevision: record.revision
            )
        }
        return FirstMateFeedbackDraft(baseRevision: 0)
    }

    func setFeedbackDraft(
        _ draft: FirstMateFeedbackDraft,
        for featureID: String,
        messageID: String,
        expectedContext: OperationContext
    ) {
        guard let contextFeature = expectedContext.featureID,
              contextFeature == featureID,
              isCurrentFeedbackContext(expectedContext) else { return }
        let key = FeedbackKey(featureID, messageID)
        // The editor freezes while a save is in flight; the store keeps that
        // invariant even if a view task races the submission, and an editor
        // cannot seed a draft before the first record load completes.
        guard !savingFeedbackKeys.contains(key),
              hasLoadedFeedback(for: featureID) else { return }
        // An edit never loses the revision it was pinned to: a caller that
        // supplies a fresh struct inherits the existing draft's pin, then the
        // visible record, then the loaded-but-absent zero pin. A refresh that
        // arrives mid-edit can therefore never authorize an overwrite.
        var pinnedDraft = draft
        if pinnedDraft.baseRevision == nil {
            pinnedDraft.baseRevision = feedbackDrafts[key]?.baseRevision
                ?? feedbackRecords[featureID]?[messageID]?.revision
                ?? 0
        }
        feedbackDrafts[key] = pinnedDraft
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
    }

    /// Cancelling an edit discards only that edit, never the saved rating.
    func discardFeedbackDraft(for featureID: String, messageID: String) {
        let key = FeedbackKey(featureID, messageID)
        feedbackDrafts[key] = nil
        feedbackSaveErrors[key] = nil
        feedbackConflicts.remove(key)
    }

    /// True once the retained ratings for this feature have loaded completely.
    /// The synthetic demo and legacy fixture features are always loaded.
    func hasLoadedFeedback(for featureID: String) -> Bool {
        isDemo || loadedFeedbackFeatures.contains(featureID)
    }

    func canRate(messageID: String, featureID: String) -> Bool {
        guard let message = snapshots[featureID]?.messages.first(where: { $0.id == messageID }) else { return false }
        return FirstMateFeedbackEligibility.isEligible(message)
    }

    func isLoadingFeedback(for featureID: String) -> Bool { loadingFeedbackFeatures.contains(featureID) }
    func feedbackError(for featureID: String) -> String? { feedbackErrors[featureID] }
    func isSavingFeedback(featureID: String, messageID: String) -> Bool {
        savingFeedbackKeys.contains(FeedbackKey(featureID, messageID))
    }
    func feedbackSaveError(featureID: String, messageID: String) -> String? {
        feedbackSaveErrors[FeedbackKey(featureID, messageID)]
    }
    /// True when the last save failed because another client advanced the
    /// retained revision. Recovery reloads the record before retrying.
    func feedbackConflict(featureID: String, messageID: String) -> Bool {
        feedbackConflicts.contains(FeedbackKey(featureID, messageID))
    }

    private func isCurrentFeedbackContext(_ context: OperationContext) -> Bool {
        context.generation == generation && context.lifecycleIdentity == lifecycleIdentity
    }

    private static func isStaleRevisionError(_ error: Error) -> Bool {
        if case APIError.server(let status, _) = error { return status == 409 }
        return false
    }

    /// A lower revision is a delayed read or a delayed receipt; the newer
    /// locally known record always wins.
    private func receiveFeedback(_ record: FirstMateFeedback, featureID: String) {
        guard record.featureID == featureID, !record.messageID.isEmpty, record.revision >= 0 else { return }
        var records = feedbackRecords[featureID] ?? [:]
        if let existing = records[record.messageID], existing.revision > record.revision { return }
        records[record.messageID] = record
        feedbackRecords[featureID] = records
    }

    /// Categories are append-only user data. A delayed full fetch adds or
    /// refreshes entries by stable ID and never removes a newer local addition.
    private func mergeFeedbackCategory(_ category: FirstMateFeedbackCategory) {
        if let index = feedbackCategories.firstIndex(where: { $0.id == category.id }) {
            feedbackCategories[index] = category
        } else {
            feedbackCategories.append(category)
        }
    }

    private func demoFeedback(
        from draft: FirstMateFeedbackDraft,
        featureID: String,
        messageID: String
    ) -> FirstMateFeedback {
        let existing = feedbackRecords[featureID]?[messageID]
        let message = snapshots[featureID]?.messages.first { $0.id == messageID }
        return FirstMateFeedback(
            messageID: messageID,
            featureID: featureID,
            rating: draft.rating,
            categoryIDs: draft.categoryIDs,
            comment: draft.comment,
            revision: (existing?.revision ?? 0) + 1,
            createdAt: existing?.createdAt ?? FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp,
            provenance: FirstMateFeedbackProvenance(
                responseText: message?.text ?? "",
                responseCreatedAt: message?.createdAt,
                sourceKind: "legacy",
                inReplyTo: nil,
                visitID: nil,
                featureRevision: snapshots[featureID]?.feature.revision,
                coordinatorSessionID: nil,
                sessionProvenance: "unavailable"
            )
        )
    }

    private func demoCategory(named label: String) -> FirstMateFeedbackCategory {
        let normalized = Self.normalizedCategoryLabel(label)
        if let existing = feedbackCategories.first(where: { Self.normalizedCategoryLabel($0.label) == normalized }) {
            return existing
        }
        let collapsed = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let category = FirstMateFeedbackCategory(
            id: "fmc-demo-\(feedbackCategories.count + 1)",
            label: collapsed,
            createdAt: FirstMateDemo.timestamp
        )
        feedbackCategories.append(category)
        feedbackCategoriesLoaded = true
        feedbackCategoriesError = nil
        return category
    }

    private static func normalizedCategoryLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    func open(_ resource: FirstMateResource) async {
        resourceGeneration += 1
        let token = resourceGeneration
        openedResource = resource
        if resourcePresentation == nil { resourcePresentation = FirstMateResourcePresentation() }
        resourceText = ""
        sessionMessages = nil
        resourceError = nil
        let resourceSnapshot = selectedFeatureID.flatMap {
            inspectorSnapshot(featureID: $0, view: .details) ?? inspectorSnapshot(featureID: $0, view: .overview)
        } ?? snapshot
        resourceUsage = resource.usage(in: resourceSnapshot)
        resourceModelSelection = resource.modelSelection(in: resourceSnapshot)
        resetSessionPagination()
        resourceLoading = true
        defer { if token == resourceGeneration { resourceLoading = false } }
        if isDemo {
            sessionMessages = FirstMateDemo.sessionMessages(for: resource)
            resourceText = FirstMateDemo.content(for: resource, snapshot: snapshot)
            return
        }
        guard let client else { resourceError = "Reconnect to this feature's host to read its saved resource."; return }
        do {
            let content: String
            switch resource {
            case .document(let document):
                let response = try await client.fetchFirstMateDocument(document.id)
                guard response.ok, response.document.id == document.id else { throw APIError.invalidResponse }
                content = response.document.content ?? response.content ?? "This document has no text preview."
            case .session, .history:
                guard let sessionID = resource.nativeSessionID else { throw APIError.invalidResponse }
                let response = try await client.fetchFirstMateSession(sessionID, before: nil)
                guard response.ok, response.nativeSessionID == sessionID else { throw APIError.invalidResponse }
                guard token == resourceGeneration else { return }
                sessionMessages = response.messages
                sessionNextBefore = response.nextBefore
                sessionTotalMessages = response.totalMessages
                sessionLoadedMessages = response.messages?.count ?? 0
                if let usage = response.usage { resourceUsage = usage }
                if let selection = response.modelSelection { resourceModelSelection = selection }
                content = response.messages?.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
                    ?? response.content ?? "The saved session does not have any messages yet."
            }
            guard token == resourceGeneration else { return }
            resourceText = content
        } catch { if token == resourceGeneration { resourceError = error.localizedDescription } }
    }

    func closeResource() {
        resourceGeneration += 1
        openedResource = nil
        resourcePresentation = nil
        resourceLoading = false
        sessionMessages = nil
        resourceUsage = nil
        resourceModelSelection = nil
        resetSessionPagination()
    }

    func loadEarlierSessionMessages() async {
        guard !isLoadingEarlier, let before = sessionNextBefore,
              let sessionID = openedResource?.nativeSessionID, let client else { return }
        let token = resourceGeneration
        isLoadingEarlier = true
        sessionPageError = nil
        defer { if token == resourceGeneration { isLoadingEarlier = false } }
        do {
            let response = try await client.fetchFirstMateSession(sessionID, before: before)
            guard token == resourceGeneration else { return }
            guard response.ok, response.nativeSessionID == sessionID else { throw APIError.invalidResponse }
            if let next = response.nextBefore, next < 0 || next >= before { throw APIError.invalidResponse }
            let earlier = response.messages ?? []
            if let sessionMessages { self.sessionMessages = earlier + sessionMessages }
            let text = earlier.map { "\($0.role.capitalized)\n\($0.text)" }.joined(separator: "\n\n")
            if !text.isEmpty { resourceText = text + (resourceText.isEmpty ? "" : "\n\n" + resourceText) }
            sessionLoadedMessages += earlier.count
            sessionNextBefore = response.nextBefore
            sessionTotalMessages = response.totalMessages ?? sessionTotalMessages
            if let usage = response.usage { resourceUsage = usage }
            if let selection = response.modelSelection { resourceModelSelection = selection }
        } catch { if token == resourceGeneration { sessionPageError = error.localizedDescription } }
    }

    private static func isStrictlyOlderTimestamp(_ candidate: String, than existing: String) -> Bool {
        guard let candidateDate = HerdrTimestamp.date(from: candidate),
              let existingDate = HerdrTimestamp.date(from: existing) else { return false }
        return candidateDate < existingDate
    }

    /// Conservative verification merge for partial acknowledgements and
    /// delayed full snapshots.
    ///
    /// - A partial acknowledgement (mutation response) that omits the field
    ///   inherits the cached assessment.
    /// - An authoritative full snapshot that omits, nulls, or malforms the
    ///   field reports unavailable evidence: the cached verdict is downgraded
    ///   so an old green never remains current.
    /// - An explicit empty assessment never erases retained evidence for a
    ///   partial acknowledgement.
    /// - A strictly older feature timestamp keeps the cached assessment.
    /// - Otherwise the assessment with the newer feature revision and
    ///   computation timestamp wins, so a delayed verified response cannot
    ///   overwrite a newer partial or failed verdict.
    private static func retainedVerification(
        incoming: FirstMateVerification?,
        includesField: Bool,
        cached: FirstMateVerification?,
        incomingIsStale: Bool,
        authoritative: Bool
    ) -> FirstMateVerification? {
        if incomingIsStale { return cached }
        guard let cached else { return includesField ? incoming : nil }
        guard includesField, let incoming else {
            // An omitted or malformed field is evidence of absence only in an
            // authoritative full snapshot; a mutation acknowledgement merely
            // did not carry the assessment.
            return authoritative ? Self.unavailableVerification(previous: cached) : cached
        }
        if authoritative, incoming.status != .verified,
           incoming.featureRevision == nil, incoming.computedAtDate == nil {
            // A full response without usable ordering still withdraws green.
            // Keep the last ordering fence so a delayed green cannot revive it.
            var unavailable = incoming
            unavailable.featureRevision = cached.featureRevision
            unavailable.computedAt = cached.computedAt
            return unavailable
        }
        if cached.status != .verified, incoming.status == .verified,
           incoming.featureRevision == cached.featureRevision,
           let cachedDate = cached.computedAtDate,
           let incomingDate = incoming.computedAtDate,
           incomingDate <= cachedDate {
            return cached
        }
        return incoming.isAtLeastAsFresh(as: cached) ? incoming : cached
    }

    private static func unavailableVerification(previous: FirstMateVerification) -> FirstMateVerification {
        FirstMateVerification(
            status: .unavailable,
            featureRevision: previous.featureRevision,
            coverageReasons: ["The companion did not report structured suite evidence for this feature."],
            evidencePresent: true,
            computedAt: previous.computedAt
        )
    }

    private func resetSessionPagination() {
        sessionNextBefore = nil
        sessionTotalMessages = nil
        sessionLoadedMessages = 0
        isLoadingEarlier = false
        sessionPageError = nil
    }

    private func reconcileSelection() {
        guard selectedFeatureID == nil || !features.contains(where: { $0.id == selectedFeatureID }) else { return }
        // The lead stays selected: it is never in the feature list.
        if let selectedFeatureID, selectedFeatureID == leadFeatureID { return }
        if let first = features.first {
            select(first.id)
        } else {
            if let old = selectedFeatureID { drafts[old] = draft }
            selectedFeatureID = nil
            selectedVisitID = nil
            draft = ""
            closeResource()
        }
    }

    func advanceDemo() {
        guard isDemo else { return }
        demoStep = (demoStep + 1) % FirstMateDemo.stepTitles.count
        for value in FirstMateDemo.features(step: demoStep) {
            snapshots[value.feature.id] = nil
            receive(value)
        }
        selectedVisitID = snapshot?.feature.currentVisitID
    }
    var demoStepTitle: String { FirstMateDemo.stepTitles[demoStep] }

    private func sendDemo(_ text: String, featureID: String) {
        guard var value = snapshot else { return }
        let createdAt = demoSendTimestamp(after: value.messages.last?.createdAt)
        value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "user", text: text, status: "delivered", createdAt: createdAt))
        let reply = value.feature.isLead
            ? "This is a synthetic demo, so I answer from made-up features. Connect a companion and I'll check your real ones."
            : "Your direction is recorded in this synthetic demo. Use Next scenario to inspect the planned implementation, review, checkpoint, and handoff states."
        value.messages.append(.init(id: UUID().uuidString, featureID: featureID, role: "assistant", text: reply, status: "delivered", createdAt: createdAt))
        value.feature.revision += 1
        receive(value)
    }

    /// A wall-clock demo stamps now, but never before the chat's newest
    /// message: seeded messages sit at fixed clock times today, which can be
    /// later than now.
    private func demoSendTimestamp(after latest: String?) -> String {
        guard demoUsesWallClock else { return FirstMateDemo.timestamp }
        let now = Date()
        let floor = latest.flatMap(HerdrTimestamp.date(from:))?.addingTimeInterval(60) ?? now
        return HerdrTimestamp.string(from: max(now, floor))
    }

    private func record(_ failure: Error) {
        if case APIError.server(let status, _) = failure, status == 404 || status == 501 {
            unsupported = true
            error = "This companion server needs First Mate support. Update the server to a version with first-mate-v1."
        } else { error = failure.localizedDescription }
    }
}

/// Owns the UI-control grant for one visible workspace. Moving this lease to a
/// different store or lifecycle revokes the previous grant first. Store-issued
/// tokens make delayed cleanup harmless after a newer view has taken ownership.
@MainActor
final class FirstMateWorkspaceControlLease {
    private weak var store: FirstMateStore?
    private var token: FirstMateStore.ControlLease?

    func update(store newStore: FirstMateStore, available: Bool) {
        if store === newStore,
           let token,
           token.lifecycleIdentity == newStore.lifecycle {
            newStore.updateControlLease(token, available: available)
            return
        }

        release()
        store = newStore
        token = newStore.acquireControlLease(available: available)
    }

    func release() {
        if let store, let token {
            store.releaseControlLease(token)
        }
        store = nil
        token = nil
    }

    func release(storeID: ObjectIdentifier, lifecycleIdentity: FirstMateStore.LifecycleIdentity) {
        guard let store,
              let token,
              ObjectIdentifier(store) == storeID,
              token.lifecycleIdentity == lifecycleIdentity else { return }
        release()
    }
}
