import SwiftUI

struct FirstMateComposerModelControls: View {
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    let context: FirstMateStore.OperationContext
    let canControl: Bool
    let hasQueuedWork: Bool
    let modelFavorites: ModelFavoritesStore

    @State private var catalog: FirstMateModelCatalog?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var proposalState = FirstMateModelSettingsProposalState()
    @State private var showsConfirmation = false

    private var proposal: FirstMateModelSettingsProposal? { proposalState.proposal }

    /// Sits in the composer's tool row: the model + effort pill, then "Use
    /// host default". Narrow composers drop the labels before the pill.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
        }
        .task(id: context) { await loadCatalog() }
        .onChange(of: store.operationContext) { invalidateProposalIfNeeded() }
        .onChange(of: feature.nativeSessionID) { invalidateProposalIfNeeded() }
        .onChange(of: feature.modelSettingsRevision) { invalidateProposalIfNeeded() }
        .onChange(of: feature.coordinatorOwner) { dismissConfirmationWhenBlocked() }
        .onChange(of: hasQueuedWork) { dismissConfirmationWhenBlocked() }
        .confirmationDialog(
            "Change this coordinator session?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply for next coordinator turn") {
                Task { await saveProposal(userConfirmed: true) }
            }
            Button("Cancel", role: .cancel) {
                proposalState.cancel()
            }
        } message: {
            Text("Changing model or thinking for an established session can reprocess context, invalidate prompt caches, and add cost. Workers keep their own models. The change applies to the next coordinator turn and does not reset the session.")
        }
        .accessibilityIdentifier("first-mate-model-controls")
    }

    @ViewBuilder
    private func controls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            PiModelEffortPill {
                PiModelPickerChip(
                    currentModel: displayedModel,
                    availableModels: availableModels,
                    isLoading: isLoading,
                    isSetting: isSaving,
                    isEnabled: controlsEnabled,
                    isInteractive: supportsSettings,
                    errorMessage: error,
                    selectModel: selectModel,
                    retry: {
                        if proposalState.needsConfirmation {
                            showsConfirmation = true
                        } else if proposal != nil {
                            Task { await saveProposal() }
                        } else {
                            Task { await loadCatalog() }
                        }
                    },
                    modelFavorites: modelFavorites,
                    style: .segment
                )
            } effort: {
                PiThinkingLevelChip(
                    currentLevel: displayedThinking,
                    isSetting: isSaving,
                    isEnabled: controlsEnabled,
                    isInteractive: supportsSettings,
                    selectLevel: selectThinking,
                    style: .segment
                )
            }
            if configuredDiffersFromActual {
                let next = "Next: \(feature.modelDisplayName)\(configuredThinkingSuffix)"
                Group {
                    if compact {
                        // Narrow composers keep the pending change as a glyph.
                        Image(systemName: "clock.arrow.circlepath")
                            .herdrFont(size: 12)
                            .foregroundStyle(HerdrTheme.iconTint)
                            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
                            .contentShape(.rect)
                    } else {
                        Text(next)
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .help("\(next). Configured for the next coordinator turn; the current session is unchanged until the server applies it safely")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(next)
            }
            if supportsSettings {
                Button("Use host default", systemImage: "arrow.uturn.backward", action: selectHostDefault)
                    .labelStyle(HostDefaultLabelStyle(compact: compact))
                    .buttonStyle(HerdrButtonStyle(kind: .ghost, height: HerdrTheme.ControlHeight.regular))
                    .help("Use host default")
                    .disabled(!controlsEnabled)
            } else {
                Label(compact ? "Update server" : "Update server for safe model changes", systemImage: "arrow.down.circle")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(1)
                    .help("Update this feature's companion server for safe model changes")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private struct HostDefaultLabelStyle: LabelStyle {
        let compact: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon
                if !compact { configuration.title }
            }
        }
    }

    private var controlsEnabled: Bool {
        canControl
            && context == store.operationContext
            && supportsSettings
            && feature.coordinatorOwner == nil
            && !hasQueuedWork
            && !store.isSending
            && !isLoading
            && !isSaving
    }

    private var supportsSettings: Bool {
        feature.modelSettingsRevision != nil
            && (feature.nativeSessionID == nil || store.safeModelSettingsSupported)
    }

    private var availableModels: [PiAvailableModel] {
        (catalog?.models ?? []).map { option in
            let modelID = option.id.hasPrefix(option.provider + "/")
                ? String(option.id.dropFirst(option.provider.count + 1))
                : option.id
            return PiAvailableModel(
                provider: option.provider,
                modelID: modelID,
                name: option.name,
                reasoning: option.reasoning,
                contextWindow: nil
            )
        }
    }

    private var displayedModel: PiModelIdentity? {
        let raw = feature.nativeSessionID == nil
            ? feature.coordinatorModel
            : feature.modelSelection?.actualModel
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { return .init(provider: parts[0], id: parts[1], name: nil) }
        if let option = catalog?.models.first(where: { $0.id == raw }) {
            return .init(provider: option.provider, id: raw, name: option.name)
        }
        return .init(provider: "configured", id: raw, name: raw)
    }

    private var displayedThinking: String? {
        feature.nativeSessionID == nil
            ? feature.coordinatorThinking
            : feature.modelSelection?.actualThinking
    }

    private var configuredDiffersFromActual: Bool {
        guard feature.nativeSessionID != nil else { return false }
        return feature.modelSelection?.actualModel != feature.coordinatorModel
            || feature.modelSelection?.actualThinking != feature.coordinatorThinking
    }

    private var configuredThinkingSuffix: String {
        guard let thinking = feature.coordinatorThinking, !thinking.isEmpty else { return "" }
        return " · \(thinking.capitalized)"
    }

    private func loadCatalog() async {
        guard supportsSettings else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            catalog = try await store.fetchModelCatalog(expectedContext: context)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard context == store.operationContext else { return }
            self.error = error.localizedDescription
        }
    }

    private func selectModel(_ selected: PiAvailableModel) {
        guard controlsEnabled else { return }
        let exact = catalog?.models.first(where: {
            $0.provider == selected.provider
                && ($0.id == selected.modelID || $0.id == selected.id)
        })?.id ?? selected.id
        propose(model: exact, thinking: feature.coordinatorThinking ?? "")
    }

    private func selectThinking(_ selected: PiThinkingLevel) {
        guard controlsEnabled else { return }
        guard catalog?.thinkingLevels.contains(selected.rawValue) != false else {
            error = "This host does not offer \(selected.displayName) thinking for First Mate."
            return
        }
        propose(model: feature.coordinatorModel ?? "", thinking: selected.rawValue)
    }

    private func selectHostDefault() {
        propose(model: "", thinking: "")
    }

    private func propose(model: String, thinking: String) {
        guard controlsEnabled else { return }
        guard model != (feature.coordinatorModel ?? "")
                || thinking != (feature.coordinatorThinking ?? "") else { return }

        guard let frozen = proposalState.stage(
            feature: feature,
            context: context,
            model: model,
            thinking: thinking,
            safeSettingsSupported: store.safeModelSettingsSupported
        ) else { return }
        error = nil
        if frozen.requiresConfirmation {
            showsConfirmation = true
        } else {
            Task { await saveProposal() }
        }
    }

    private func saveProposal(userConfirmed: Bool = false) async {
        guard let stagedProposal = proposal else { return }
        let currentFeature = store.feature(for: context)
        if let reason = stagedProposal.blockReason(
            feature: currentFeature,
            currentContext: store.operationContext,
            safeSettingsSupported: store.safeModelSettingsSupported,
            canControl: canControl,
            hasQueuedWork: hasQueuedWork,
            operationInFlight: store.isSending || isSaving
        ) {
            switch reason {
            case .staleTarget:
                refuseStaleProposal()
            case .coordinatorBusy, .queuedWork, .operationInFlight:
                showsConfirmation = false
                error = "The coordinator is busy. Wait for the current or queued turn before changing settings."
            case .unavailable:
                showsConfirmation = false
                error = "Reconnect to this feature before changing coordinator settings."
            }
            return
        }

        guard let proposal = proposalState.proposalForSubmission(userConfirmed: userConfirmed) else {
            showsConfirmation = true
            return
        }
        showsConfirmation = false
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.saveModelSettings(
                proposal.settings,
                expectedContext: proposal.context,
                expectedSessionID: proposal.nativeSessionID,
                expectedSettingsRevision: proposal.settingsRevision
            )
            proposalState.cancel()
            error = nil
        } catch {
            guard context == store.operationContext else { return }
            if case APIError.server(let status, let message) = error, status == 409 {
                proposalState.cancel()
                self.error = message.isEmpty
                    ? "The coordinator changed or became busy. Refresh and confirm the setting again."
                    : message
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func invalidateProposalIfNeeded() {
        guard proposal != nil else {
            showsConfirmation = false
            return
        }
        if proposalState.invalidateUnless(
            feature: store.feature(for: context),
            currentContext: store.operationContext,
            safeSettingsSupported: store.safeModelSettingsSupported
        ) {
            refuseStaleProposal(alreadyInvalidated: true)
        }
    }

    private func dismissConfirmationWhenBlocked() {
        guard feature.coordinatorOwner != nil || hasQueuedWork else { return }
        showsConfirmation = false
        error = "The coordinator is busy. Wait for the current or queued turn before changing settings."
    }

    private func refuseStaleProposal(alreadyInvalidated: Bool = false) {
        showsConfirmation = false
        if !alreadyInvalidated { proposalState.cancel() }
        error = "The feature, coordinator session, or settings revision changed. Choose the setting again."
    }
}
