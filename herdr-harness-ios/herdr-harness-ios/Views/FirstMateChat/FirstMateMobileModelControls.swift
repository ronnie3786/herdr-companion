import SwiftUI

@MainActor
enum FirstMateMobileModelPolicy {
    static func unavailableReason(store: FirstMateStore, context: FirstMateStore.OperationContext,
                                  canControl: Bool, operationInFlight: Bool = false) -> String? {
        guard canControl, store.controlAvailable else { return "Reconnect with control of this conversation to change settings." }
        guard context == store.operationContext, let snapshot = store.snapshot(for: context) else {
            return "The conversation changed. Reopen model settings."
        }
        guard !FirstMateMobileTranscriptPolicy.isClosed(snapshot) else { return "This feature is closed." }
        let feature = snapshot.feature
        guard feature.modelSettingsRevision != nil,
              feature.nativeSessionID == nil || store.safeModelSettingsSupported else {
            return "Update this companion server for safe model changes."
        }
        guard feature.coordinatorOwner == nil, !snapshot.messages.contains(where: { $0.status == "queued" }),
              !store.isSending, !store.isSubmitting(featureID: feature.id), !operationInFlight else {
            return "Wait for the current or queued coordinator turn before changing settings."
        }
        return nil
    }

    static func featureWithObservedSettings(_ snapshot: FirstMateSnapshot) -> FirstMateFeature {
        var feature = snapshot.feature
        if let id = feature.nativeSessionID,
           let selection = snapshot.coordinatorSessions.last(where: { $0.nativeSessionID == id })?.modelSelection {
            feature.modelSelection = selection
        }
        return feature
    }
}

struct FirstMateMobileModelControls: View {
    @Bindable var store: FirstMateStore
    let context: FirstMateStore.OperationContext
    let canControl: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: FirstMateModelCatalog?
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var proposal = FirstMateModelSettingsProposalState()
    @State private var confirms = false

    private var feature: FirstMateFeature? { store.snapshot(for: context).map(FirstMateMobileModelPolicy.featureWithObservedSettings) }
    private var reason: String? {
        FirstMateMobileModelPolicy.unavailableReason(store: store, context: context, canControl: canControl, operationInFlight: saving)
    }
    private var enabled: Bool { reason == nil && !loading && proposal.proposal == nil }
    private struct ConsentIdentity: Equatable {
        let context: FirstMateStore.OperationContext
        let session: String?
        let revision: Int?
        let reason: String?
        let safe: Bool
    }
    private var identity: ConsentIdentity {
        .init(context: store.operationContext, session: feature?.nativeSessionID, revision: feature?.modelSettingsRevision,
              reason: FirstMateMobileModelPolicy.unavailableReason(store: store, context: context, canControl: canControl),
              safe: store.safeModelSettingsSupported)
    }

    var body: some View {
        let capturedContext = context
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let feature {
                        if feature.nativeSessionID != nil {
                            setting("Current session", model: feature.modelSelection?.actualModel, thinking: feature.modelSelection?.actualThinking,
                                    fallback: "Not reported by this session")
                            setting("Requested for next turn", model: feature.coordinatorModel, thinking: feature.coordinatorThinking, fallback: "Host default")
                        } else {
                            setting("New coordinator", model: feature.coordinatorModel, thinking: feature.coordinatorThinking, fallback: "Host default")
                        }
                    }
                    Text("These settings apply to the coordinator. Workers keep their own models.")
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText)
                    if let reason { Text(reason).foregroundStyle(HerdrTheme.warning) }
                    if loading { ProgressView("Loading this machine's models…") }
                    if let catalog {
                        VStack(alignment: .leading, spacing: 4) {
                            HerdrMicroLabel(text: "MODEL")
                            ForEach(catalog.models, id: \.id) { option in
                                Button { stage(model: option.id, thinking: feature?.coordinatorThinking ?? "") } label: {
                                    HStack {
                                        Text(option.name.isEmpty ? option.id : option.name).fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                        if feature?.coordinatorModel == option.id { Image(systemName: "checkmark") }
                                    }.frame(minHeight: 44)
                                }.disabled(!enabled)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HerdrMicroLabel(text: "THINKING")
                            ForEach(catalog.thinkingLevels, id: \.self) { level in
                                Button { stage(model: feature?.coordinatorModel ?? "", thinking: level) } label: {
                                    HStack { Text(level.capitalized); Spacer(); if feature?.coordinatorThinking == level { Image(systemName: "checkmark") } }
                                        .frame(minHeight: 44)
                                }.disabled(!enabled)
                            }
                        }
                        Button("Use host default", systemImage: "arrow.uturn.backward") { stage(model: "", thinking: "") }
                            .buttonStyle(HerdrButtonStyle(kind: .outline)).disabled(!enabled)
                            .accessibilityIdentifier("first-mate-model-default")
                    }
                    if let error {
                        Text(error).foregroundStyle(HerdrTheme.warning).fixedSize(horizontal: false, vertical: true)
                        if proposal.proposal != nil {
                            Button("Retry this change") {
                                if proposal.needsConfirmation { confirms = true } else { save() }
                            }.disabled(reason != nil || saving)
                            Button("Discard proposal and choose again") { proposal.cancel(); self.error = nil }
                                .disabled(saving)
                        } else {
                            Button("Reload settings") { Task { await store.refresh(); await load(capturedContext) } }
                                .disabled(loading || saving)
                        }
                    }
                    if saving { ProgressView("Saving settings…") }
                }
                .padding(16).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane) }
            .herdrNavigationBarChrome()
            .navigationTitle("Model and thinking").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .herdrAppChrome(separateSurface: true)
        .task(id: capturedContext) { await load(capturedContext) }
        .onChange(of: identity) { _, _ in
            if !saving { proposal.cancel(); confirms = false }
        }
        .onDisappear { proposal.cancel(); confirms = false }
        .confirmationDialog("Change this coordinator session?", isPresented: $confirms, titleVisibility: .visible) {
            Button("Apply for next coordinator turn") { save(confirmed: true) }
            Button("Cancel", role: .cancel) { proposal.cancel() }
        } message: {
            Text("Changing model or thinking may reprocess context, invalidate prompt caches, and add cost. The change applies to the next coordinator turn without resetting this session.")
        }
        .accessibilityIdentifier("first-mate-model-sheet")
    }

    private func setting(_ title: String, model: String?, thinking: String?, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            Text([model.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, thinking?.capitalized].compactMap { $0 }.joined(separator: " · "))
                .herdrFont(.body, weight: .semibold).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load(_ captured: FirstMateStore.OperationContext) async {
        guard !loading, captured == context, captured == store.operationContext else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await store.fetchModelCatalog(expectedContext: captured)
            guard !Task.isCancelled, captured == store.operationContext else { return }
            catalog = value; error = nil
        } catch is CancellationError { }
        catch { if captured == store.operationContext { self.error = error.localizedDescription } }
    }

    private func stage(model: String, thinking: String) {
        guard enabled, let feature else { return }
        guard let frozen = proposal.stage(feature: feature, context: context, model: model, thinking: thinking,
                                           safeSettingsSupported: store.safeModelSettingsSupported) else { return }
        error = nil
        if frozen.requiresConfirmation { confirms = true } else { save() }
    }

    private func save(confirmed: Bool = false) {
        guard reason == nil, let staged = proposal.proposal,
              staged.blockReason(feature: store.feature(for: context), currentContext: store.operationContext,
                  safeSettingsSupported: store.safeModelSettingsSupported, canControl: canControl && store.controlAvailable,
                  hasQueuedWork: store.snapshot(for: context)?.messages.contains { $0.status == "queued" } == true,
                  operationInFlight: saving || store.isSending || store.isSubmitting(featureID: staged.featureID)) == nil,
              let frozen = proposal.proposalForSubmission(userConfirmed: confirmed) else {
            proposal.cancel(); confirms = false; error = reason ?? "The session changed. Choose the setting again."
            return
        }
        saving = true; confirms = false
        Task {
            defer { saving = false }
            guard !Task.isCancelled, proposal.proposal?.settings.requestID == frozen.settings.requestID, context == store.operationContext,
                  FirstMateMobileModelPolicy.unavailableReason(store: store, context: context, canControl: canControl) == nil,
                  frozen.matches(feature: store.feature(for: context), currentContext: store.operationContext,
                                 safeSettingsSupported: store.safeModelSettingsSupported) else {
                proposal.cancel(); error = "The session changed. Choose the setting again."; return
            }
            do {
                if store.isDemo, var snapshot = store.snapshot(for: context) {
                    snapshot.feature.coordinatorModel = frozen.settings.model.isEmpty ? nil : frozen.settings.model
                    snapshot.feature.coordinatorThinking = frozen.settings.thinking.isEmpty ? nil : frozen.settings.thinking
                    snapshot.feature.modelSettingsRevision = frozen.settingsRevision + 1
                    snapshot.feature.revision += 1; store.receive(snapshot)
                } else {
                    try await store.saveModelSettings(frozen.settings, expectedContext: frozen.context,
                        expectedSessionID: frozen.nativeSessionID, expectedSettingsRevision: frozen.settingsRevision)
                }
                proposal.cancel(); error = nil
            } catch {
                guard context == store.operationContext else { proposal.cancel(); return }
                if case APIError.server(let status, _) = error, status == 409 { proposal.cancel() }
                self.error = error.localizedDescription
            }
        }
    }
}
