import Foundation

/// Frozen identity and wire payload for one explicit model/thinking proposal.
/// Retrying an uncertain request reuses this exact value and request ID.
struct FirstMateModelSettingsProposal: Equatable, Sendable {
    enum BlockReason: Equatable, Sendable {
        case unavailable
        case staleTarget
        case coordinatorBusy
        case queuedWork
        case operationInFlight
    }

    let featureID: String
    let context: FirstMateStore.OperationContext
    let nativeSessionID: String?
    let settingsRevision: Int
    fileprivate(set) var settings: FirstMateModelSettings
    let requiresConfirmation: Bool

    static func make(
        feature: FirstMateFeature,
        context: FirstMateStore.OperationContext,
        model: String,
        thinking: String,
        safeSettingsSupported: Bool,
        requestID: String = UUID().uuidString
    ) -> Self? {
        guard context.matchesFeature(feature.id),
              let revision = feature.modelSettingsRevision else { return nil }
        let established = feature.nativeSessionID != nil
        guard !established || safeSettingsSupported else { return nil }
        return Self(
            featureID: feature.id,
            context: context,
            nativeSessionID: feature.nativeSessionID,
            settingsRevision: revision,
            settings: FirstMateModelSettings(
                model: model,
                thinking: thinking,
                expectedSettingsRevision: revision,
                requestID: requestID,
                expectedSessionID: safeSettingsSupported ? feature.nativeSessionID : nil,
                // Consent is added only by proposalForSubmission after Apply.
                confirmSessionModelChange: nil
            ),
            requiresConfirmation: established
        )
    }

    func matches(
        feature: FirstMateFeature?,
        currentContext: FirstMateStore.OperationContext,
        safeSettingsSupported: Bool
    ) -> Bool {
        guard let feature else { return false }
        return context == currentContext
            && feature.id == featureID
            && feature.nativeSessionID == nativeSessionID
            && feature.modelSettingsRevision == settingsRevision
            && (!requiresConfirmation || safeSettingsSupported)
    }

    func blockReason(
        feature: FirstMateFeature?,
        currentContext: FirstMateStore.OperationContext,
        safeSettingsSupported: Bool,
        canControl: Bool,
        hasQueuedWork: Bool,
        operationInFlight: Bool
    ) -> BlockReason? {
        guard canControl else { return .unavailable }
        guard matches(
            feature: feature,
            currentContext: currentContext,
            safeSettingsSupported: safeSettingsSupported
        ) else { return .staleTarget }
        guard feature?.coordinatorOwner == nil else { return .coordinatorBusy }
        guard !hasQueuedWork else { return .queuedWork }
        guard !operationInFlight else { return .operationInFlight }
        return nil
    }
}

struct FirstMateModelSettingsProposalState: Equatable, Sendable {
    private(set) var proposal: FirstMateModelSettingsProposal?
    private var userConfirmed = false

    var needsConfirmation: Bool {
        proposal?.requiresConfirmation == true && !userConfirmed
    }

    /// Returns the frozen proposal only when it is safe to submit. Established
    /// sessions require the Apply action to pass `userConfirmed: true` once;
    /// uncertain retries can then reuse the exact proposal and request ID.
    mutating func proposalForSubmission(userConfirmed confirmation: Bool = false) -> FirstMateModelSettingsProposal? {
        guard let proposal else { return nil }
        if proposal.requiresConfirmation {
            guard confirmation || userConfirmed else { return nil }
            if confirmation { userConfirmed = true }
            var confirmedProposal = proposal
            confirmedProposal.settings.confirmSessionModelChange = true
            return confirmedProposal
        }
        return proposal
    }

    mutating func stage(
        feature: FirstMateFeature,
        context: FirstMateStore.OperationContext,
        model: String,
        thinking: String,
        safeSettingsSupported: Bool,
        requestID: @autoclosure () -> String = UUID().uuidString
    ) -> FirstMateModelSettingsProposal? {
        if let proposal,
           proposal.settings.model == model,
           proposal.settings.thinking == thinking,
           proposal.matches(
               feature: feature,
               currentContext: context,
               safeSettingsSupported: safeSettingsSupported
           ) {
            return proposal
        }
        proposal = FirstMateModelSettingsProposal.make(
            feature: feature,
            context: context,
            model: model,
            thinking: thinking,
            safeSettingsSupported: safeSettingsSupported,
            requestID: requestID()
        )
        userConfirmed = false
        return proposal
    }

    mutating func cancel() {
        proposal = nil
        userConfirmed = false
    }

    mutating func invalidateUnless(
        feature: FirstMateFeature?,
        currentContext: FirstMateStore.OperationContext,
        safeSettingsSupported: Bool
    ) -> Bool {
        guard let proposal else { return false }
        guard proposal.matches(
            feature: feature,
            currentContext: currentContext,
            safeSettingsSupported: safeSettingsSupported
        ) else {
            self.proposal = nil
            userConfirmed = false
            return true
        }
        return false
    }
}
