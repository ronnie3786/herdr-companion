import SwiftUI

struct FirstMateModelSettingsView: View {
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    let context: FirstMateStore.OperationContext
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: FirstMateModelCatalog?
    @State private var model: String
    @State private var thinking: String
    @State private var revision: Int
    @State private var search = ""
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @State private var pending: FirstMateModelSettings?

    init(store: FirstMateStore, feature: FirstMateFeature, context: FirstMateStore.OperationContext) {
        self.store = store
        self.feature = feature
        self.context = context
        _model = State(initialValue: feature.coordinatorModel ?? "")
        _thinking = State(initialValue: feature.coordinatorThinking ?? "")
        _revision = State(initialValue: feature.modelSettingsRevision ?? 0)
    }

    private var models: [FirstMateModelOption] {
        (catalog?.models ?? []).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("First Mate model").herdrFont(.title3, weight: .semibold)
            Text("Saved for this feature and applied to the next First Mate turn. Host planning, execution, and architect routes are configured separately.")
                .herdrFont(.caption).foregroundStyle(.secondary)
            if feature.modelSettingsRevision == nil {
                Label("Update this companion server to 0.12.0b3 or later to configure models here. You can keep chatting with its current model.", systemImage: "arrow.down.circle")
                    .herdrFont(.callout)
                Button("Done") { dismiss() }.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                modelRow(id: "", name: "Host default", subtitle: catalog?.defaultModel.isEmpty == false ? catalog!.defaultModel : "Pi's configured model")
                TextField("Find a model or provider", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("first-mate-model-search")
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if !model.isEmpty, catalog != nil, !catalog!.models.contains(where: { $0.id == model }) {
                            modelRow(id: model, name: model, subtitle: "Saved selection, unavailable in this host's catalog")
                        }
                        ForEach(models) { option in
                            modelRow(id: option.id, name: option.name, subtitle: option.provider)
                        }
                        if loading { ProgressView("Loading host models…").padding() }
                        else if catalog != nil, models.isEmpty {
                            Text(search.isEmpty ? "No configured models found. Check Pi's provider setup on this host." : "No matching models.")
                                .herdrFont(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                }.frame(height: 165)
                Divider()
                Picker("Thinking effort", selection: $thinking) {
                    Text("Automatic").tag("")
                    ForEach(catalog?.thinkingLevels ?? ["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }.accessibilityIdentifier("first-mate-thinking-effort")
                Text("Automatic uses the configured host coordinator effort. When that is unset, Pi keeps the saved session effort or its default. Pi adjusts levels to what the model supports.")
                    .herdrFont(.caption2).foregroundStyle(.secondary)
                if let routing = catalog?.routing {
                    Divider()
                    Text("Host routing defaults").herdrFont(.subheadline, weight: .semibold)
                    routingRow("Coordinator", value: routing.coordinator)
                    routingRow("Planning", value: routing.planning)
                    routingRow("Execution", value: routing.execution)
                    if let architect = routing.architect {
                        routingRow("Architect", value: architect, emptyModelLabel: architect.pinnedDisplayName)
                        Text("Architect is a host-only pin from the private [first_mate] configuration. Change architect_model and architect_thinking there; this feature's model choice never overrides it.")
                            .herdrFont(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Host routing applies to new dispatches, retries, continuations, and handoffs. Already-started sessions keep their recorded selection.")
                        .herdrFont(.caption2).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).herdrFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    Button("Reload") { Task { await reload() } }.disabled(loading || saving)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(loading || saving || store.isSending || context != store.operationContext)
                        .accessibilityIdentifier("first-mate-model-save")
                }
            }
        }
        .padding(20).frame(width: 420)
        .task { if feature.modelSettingsRevision != nil { await loadCatalog() } }
    }

    private func modelRow(id: String, name: String, subtitle: String) -> some View {
        Button { model = id } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).herdrFont(.callout, weight: .medium).lineLimit(1)
                    Text(subtitle).herdrFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if model == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(model == id ? Color.accentColor.opacity(0.10) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }.buttonStyle(.plain).help(id.isEmpty ? "Use this host's default First Mate model" : id)
    }

    private func routingRow(_ title: String, value: FirstMateRoutingDefault, emptyModelLabel: String? = nil) -> some View {
        let fallbackDisplayName = emptyModelLabel ?? value.compactDisplayName
        let displayName = value.configuredDisplayName ?? fallbackDisplayName
        return HStack {
            Text(title).herdrFont(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(displayName).herdrFont(.caption, weight: .medium)
                .lineLimit(1).truncationMode(.middle)
                .help(value.configuredDisplayName == nil ? fallbackDisplayName : [value.model, value.thinking].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    private func loadCatalog() async {
        loading = true
        defer { loading = false }
        do {
            catalog = try await store.fetchModelCatalog(expectedContext: context)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() async {
        await store.refresh()
        guard context == store.operationContext, let current = store.snapshot?.feature else { return }
        model = current.coordinatorModel ?? ""
        thinking = current.coordinatorThinking ?? ""
        revision = current.modelSettingsRevision ?? 0
        pending = nil
        await loadCatalog()
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var settings = FirstMateModelSettings(model: model, thinking: thinking, expectedSettingsRevision: revision, requestID: UUID().uuidString)
        if let pending, pending.model == model, pending.thinking == thinking, pending.expectedSettingsRevision == revision {
            settings = pending
        }
        pending = settings
        do {
            try await store.saveModelSettings(settings, expectedContext: context)
            dismiss()
        } catch {
            if case APIError.server(let status, let message) = error, status == 409 {
                self.error = message.isEmpty
                    ? "The server rejected this model change. Reload the feature and try again."
                    : message
            } else { self.error = error.localizedDescription }
        }
    }
}
