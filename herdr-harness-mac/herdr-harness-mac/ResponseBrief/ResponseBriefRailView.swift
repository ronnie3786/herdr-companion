import SwiftUI

struct ResponseBriefRailView: View {
    @Bindable var coordinator: ResponseBriefCoordinator
    let transport: ResponseBriefTransport
    let chat: ResponseBriefChatIdentity?
    let latestSource: ResponseBriefSource?
    let close: (() -> Void)?
    @State private var selectedRecordID: String?
    @State private var followsLatest = true
    @State private var detailSelection: ResponseBriefDetailSelection?
    @State private var cacheError: String?
    @State private var confirmsCacheClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(HerdrTheme.separator)
            settings
            Divider().overlay(HerdrTheme.separator)
            content
            Spacer(minLength: 0)
        }
        .padding(18)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.ink)
        .task {
            await coordinator.load()
            if let chat {
                await coordinator.prepare(machineID: chat.machineID, transport: transport)
            }
            selectLatestIfNeeded()
        }
        .onChange(of: coordinator.records.map(\.id)) { _, _ in selectLatestIfNeeded() }
        .onChange(of: latestSource?.id) { _, _ in selectLatestIfNeeded() }
        .onChange(of: chat?.id) { _, _ in
            selectedRecordID = nil
            followsLatest = true
            selectLatestIfNeeded()
        }
        .confirmationDialog(
            "Clear cached response briefs?",
            isPresented: $confirmsCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear private brief cache", role: .destructive, action: clearCache)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes locally stored briefs and originals. It does not affect the source Pi chats.")
        }
        .sheet(item: $detailSelection, content: ResponseBriefDetailView.init)
        .accessibilityIdentifier("response-brief-rail")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Label("30-second brief", systemImage: "text.badge.checkmark")
                    .herdrFont(.headline, weight: .bold)
                Text("Experimental · AI rewritten")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer()
            Menu("Brief actions", systemImage: "ellipsis.circle") {
                if let latestSource {
                    Button("Regenerate latest response", systemImage: "arrow.clockwise") {
                        Task { await coordinator.regenerate(latestSource, transport: transport) }
                    }
                }
                if let chat {
                    Button("Reload brief support and models", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await coordinator.refreshSupport(machineID: chat.machineID, transport: transport) }
                    }
                }
                Divider()
                Button("Clear private brief cache", systemImage: "trash", role: .destructive) {
                    confirmsCacheClear = true
                }
            }
            .menuStyle(.borderlessButton)
            if let close {
                Button("Close", systemImage: "xmark", action: close)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chat {
                Button(
                    coordinator.isEnabled(chat) ? "Turn off for this chat" : "Create briefs for this chat",
                    systemImage: coordinator.isEnabled(chat) ? "checkmark.circle.fill" : "circle"
                ) {
                    toggle(chat)
                }
                .buttonStyle(.bordered)
                .tint(HerdrTheme.controlAccent)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            } else {
                Label("Waiting for Pi session identity", systemImage: "clock")
                    .foregroundStyle(HerdrTheme.muted)
            }

            Text("Opting in sends the latest completed answer and up to two recent exchanges in an additional private Pi model request. It does not change or resume this chat.")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)

            if let contextOmissionNote {
                Label(contextOmissionNote, systemImage: "info.circle")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                modelMenu
                thinkingMenu
            }
            .disabled(chat == nil)

            if let chat, !coordinator.isEnabled(chat) {
                Text("Choose a model before enabling; changes apply to this experiment.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let cacheError {
            statusLabel(cacheError, systemImage: "exclamationmark.triangle", color: HerdrTheme.alert)
        }
        if let chat {
            let state = coordinator.state(for: chat)
            switch state.phase {
            case .checkingSupport:
                statusLabel("Checking companion support…", systemImage: "network", color: HerdrTheme.mist)
            case .generating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        state.sourceID == latestSource?.id
                            ? "Creating brief for the latest response…"
                            : "Creating an earlier queued brief; the latest response is waiting…"
                    )
                    .herdrFont(.callout)
                }
                .accessibilityLabel(
                    state.sourceID == latestSource?.id
                        ? "Creating response brief for the latest response"
                        : "Creating an earlier queued response brief"
                )
            case .unsupported:
                statusLabel(
                    "Update this machine’s companion server for response-brief-v1. No generic agent fallback was used.",
                    systemImage: "arrow.down.circle",
                    color: HerdrTheme.warning
                )
            case .oversized:
                statusLabel(
                    "This response cannot fit in the bounded request without truncation. The full original remains available.",
                    systemImage: "doc.badge.ellipsis",
                    color: HerdrTheme.warning
                )
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    statusLabel(message, systemImage: "exclamationmark.triangle", color: HerdrTheme.alert)
                    if let latestSource {
                        Button("Retry latest brief", systemImage: "arrow.clockwise") {
                            Task { await coordinator.retry(latestSource, transport: transport) }
                        }
                    }
                }
            case .idle:
                EmptyView()
            }

            if let notice = state.notice {
                statusLabel(notice, systemImage: "info.circle", color: HerdrTheme.warning)
            }

            if coordinator.isUnsupported(machineID: chat.machineID), state.phase == .idle {
                statusLabel(
                    "Update this machine’s companion server for response-brief-v1. No generic agent fallback is available.",
                    systemImage: "arrow.down.circle",
                    color: HerdrTheme.warning
                )
            }

            if let sourceAssociationLabel {
                Text(sourceAssociationLabel)
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.muted)
                    .textSelection(.enabled)
            }

            if !chatRecords.isEmpty {
                recordPicker
                if let record = selectedRecord {
                    ScrollView {
                        ResponseBriefCardView(record: record, openDetail: openDetail)
                    }
                }
            } else if coordinator.isEnabled(chat), state.phase == .idle,
                      !coordinator.isUnsupported(machineID: chat.machineID) {
                ContentUnavailableView(
                    "No completed response yet",
                    systemImage: "text.bubble",
                    description: Text("The latest answer will be briefed after Pi finishes. Earlier history is not backfilled.")
                )
                .foregroundStyle(HerdrTheme.mist)
            }

            originalResponseActions
        } else {
            ContentUnavailableView(
                "Connect to this Pi chat",
                systemImage: "bolt.horizontal.circle",
                description: Text("Brief opt-in begins only after the actual Pi session identity is known.")
            )
            .foregroundStyle(HerdrTheme.mist)
        }
    }

    private var modelMenu: some View {
        Menu {
            if let chat {
                Button("Reload support and catalog", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await coordinator.refreshSupport(machineID: chat.machineID, transport: transport) }
                }
                Divider()
            }
            Button("Server default") {
                coordinator.selectModel(nil)
                observeLatestSource()
            }
            ForEach(availableModels) { model in
                Button {
                    coordinator.selectModel(model.id)
                    observeLatestSource()
                } label: {
                    if coordinator.selectedModel == model.id {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            Label(selectedModelLabel, systemImage: "cpu")
        }
        .help("Brief model — independent of this chat’s model")
    }

    private var thinkingMenu: some View {
        Menu {
            Button("Server default") {
                coordinator.selectThinkingLevel(nil)
                observeLatestSource()
            }
            ForEach(PiThinkingLevel.allCases, id: \.rawValue) { level in
                Button {
                    coordinator.selectThinkingLevel(level.rawValue)
                    observeLatestSource()
                } label: {
                    if coordinator.thinkingLevel == level.rawValue {
                        Label(level.displayName, systemImage: "checkmark")
                    } else {
                        Text(level.displayName)
                    }
                }
            }
        } label: {
            Label(selectedThinkingLabel, systemImage: "brain")
        }
        .help("Brief thinking level — independent of this chat’s setting")
    }

    private var recordPicker: some View {
        HStack {
            Text("Generated source")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.muted)
            Picker("Generated brief source", selection: selectedRecordBinding) {
                ForEach(chatRecords) { record in
                    Text(recordPickerLabel(record))
                        .tag(Optional(record.id))
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var originalResponseActions: some View {
        if let latestSource {
            Button("Full latest original response", systemImage: "doc.text") {
                openFullOriginal(latestSource, title: "Latest original response")
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.controlAccent)
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .accessibilityHint("Opens the exact, unmodified latest assistant response")

            if let selectedRecord, selectedRecord.source.id != latestSource.id {
                Button("Full selected prior original", systemImage: "clock.arrow.circlepath") {
                    openFullOriginal(selectedRecord.source, title: "Selected prior original response")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens the exact original for the selected prior brief")
            }
        } else if let selectedRecord {
            Button("Full selected original response", systemImage: "doc.text") {
                openFullOriginal(selectedRecord.source, title: "Original response")
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.controlAccent)
        }
    }

    private var chatRecords: [ResponseBriefPersistence.Record] {
        chat.map(coordinator.briefs(for:)) ?? []
    }

    private var selectedRecord: ResponseBriefPersistence.Record? {
        if let selectedRecordID,
           let selected = chatRecords.first(where: { $0.id == selectedRecordID }) {
            return selected
        }
        if followsLatest, let latestSource,
           let latest = chatRecords.first(where: { $0.source.id == latestSource.id }) {
            return latest
        }
        return chatRecords.first
    }

    private var selectedRecordBinding: Binding<String?> {
        Binding(
            get: { selectedRecord?.id },
            set: { value in
                selectedRecordID = value
                let sourceID = chatRecords.first(where: { $0.id == value })?.source.id
                followsLatest = sourceID == latestSource?.id
            }
        )
    }

    private var sourceAssociationLabel: String? {
        guard let latestSource else { return nil }
        if let selectedRecord, selectedRecord.source.id != latestSource.id {
            if followsLatest {
                return "Latest response \(shortResponseID(latestSource.responseID)) has no generated brief yet; showing prior brief \(shortResponseID(selectedRecord.source.responseID))."
            }
            return "Pinned prior brief \(shortResponseID(selectedRecord.source.responseID)); latest response is \(shortResponseID(latestSource.responseID))."
        }
        return "Latest response \(shortResponseID(latestSource.responseID))"
    }

    private var contextOmissionNote: String? {
        guard let latestSource,
              let request = try? ResponseBriefRequestBuilder.request(
                for: latestSource,
                model: coordinator.selectedModel,
                thinkingLevel: coordinator.thinkingLevel,
                clientRequestID: "preview-context-request"
              )
        else { return nil }
        return ResponseBriefRequestBuilder.optionalContextOmissionNote(
            for: latestSource,
            request: request
        )
    }

    private var availableModels: [PiAvailableModel] {
        guard let chat else { return [] }
        return coordinator.modelsByMachine[chat.machineID] ?? []
    }

    private var selectedModelLabel: String {
        guard let selectedModel = coordinator.selectedModel else { return "Default model" }
        return availableModels.first(where: { $0.id == selectedModel })?.displayName ?? selectedModel
    }

    private var selectedThinkingLabel: String {
        guard let thinking = coordinator.thinkingLevel else { return "Default thinking" }
        return PiThinkingLevel(rawValue: thinking)?.displayName ?? thinking
    }

    private func toggle(_ chat: ResponseBriefChatIdentity) {
        if coordinator.isEnabled(chat) {
            coordinator.disable(chat, transport: transport)
        } else if coordinator.enable(chat), let latestSource {
            Task { await coordinator.observe(latestSource, transport: transport) }
        }
    }

    private func observeLatestSource() {
        if let latestSource {
            Task { await coordinator.observe(latestSource, transport: transport) }
        }
    }

    private func selectLatestIfNeeded() {
        if followsLatest || selectedRecordID == nil
            || !chatRecords.contains(where: { $0.id == selectedRecordID }) {
            selectedRecordID = latestSource.flatMap { source in
                chatRecords.first(where: { $0.source.id == source.id })?.id
            } ?? chatRecords.first?.id
            followsLatest = true
        }
    }

    private func recordPickerLabel(_ record: ResponseBriefPersistence.Record) -> String {
        let response = shortResponseID(record.source.responseID)
        if record.source.id == latestSource?.id { return "Latest · \(response)" }
        return "Prior · \(response)"
    }

    private func shortResponseID(_ responseID: String) -> String {
        responseID.count <= 18 ? responseID : "\(responseID.prefix(8))…\(responseID.suffix(6))"
    }

    private func openDetail(_ detail: ResponseBrief.Detail, record: ResponseBriefPersistence.Record) {
        detailSelection = .init(
            title: detail.label,
            source: record.source.text,
            content: .lines(start: detail.startLine, end: detail.endLine)
        )
    }

    private func openFullOriginal(_ source: ResponseBriefSource, title: String) {
        detailSelection = .init(title: title, source: source.text, content: .full)
    }

    private func clearCache() {
        Task {
            do { try await coordinator.clearCache() }
            catch { cacheError = error.localizedDescription }
        }
    }

    private func statusLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .herdrFont(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
