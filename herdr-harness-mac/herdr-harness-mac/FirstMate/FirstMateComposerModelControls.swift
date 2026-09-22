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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(stacked: false)
            controls(stacked: true)
        }
        .padding(7)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
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
    private func controls(stacked: Bool) -> some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 9))
        layout {
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
                modelFavorites: modelFavorites
            )
            PiThinkingLevelChip(
                currentLevel: displayedThinking,
                isSetting: isSaving,
                isEnabled: controlsEnabled,
                isInteractive: supportsSettings,
                selectLevel: selectThinking
            )
            if configuredDiffersFromActual {
                Text("Next: \(feature.modelDisplayName)\(configuredThinkingSuffix)")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(stacked ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Configured for the next coordinator turn; the current session is unchanged until the server applies it safely")
            }
            if !stacked { Spacer(minLength: 4) }
            if supportsSettings {
                Button("Use host default", systemImage: "arrow.uturn.backward", action: selectHostDefault)
                    .buttonStyle(.plain)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .disabled(!controlsEnabled)
            } else {
                Label("Update server for safe model changes", systemImage: "arrow.down.circle")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
