import SwiftUI

struct ResponseBriefRailView: View {
    enum SelectedRecordPresentation: Equatable {
        case card
        case regenerateNeeded
    }

    /// The picker role of a record relative to the verified latest source.
    enum RecordPickerRole: Equatable {
        case latest
        case prior
    }

    static func latestRecord(
        in records: [ResponseBriefPersistence.Record],
        for source: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> ResponseBriefPersistence.Record? {
        guard let source else {
            return records.max { $0.createdAt < $1.createdAt }
        }
        return records
            .filter { isEquivalent($0.source, source) }
            .max { $0.createdAt < $1.createdAt }
    }

    static func selectedRecord(
        in records: [ResponseBriefPersistence.Record],
        selectedRecordID: String?,
        followsLatest: Bool,
        latestSource: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> ResponseBriefPersistence.Record? {
        if followsLatest {
            return latestRecord(in: records, for: latestSource, matching: isEquivalent)
        }
        guard let selectedRecordID else { return nil }
        return records.first { $0.id == selectedRecordID }
    }

    static func shouldShowRecordPicker(
        records: [ResponseBriefPersistence.Record],
        latestSource: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> Bool {
        records.count > 1 || (records.count == 1 && latestRecord(
            in: records,
            for: latestSource,
            matching: isEquivalent
        ) == nil)
    }

    static func selectedRecordPresentation(
        for record: ResponseBriefPersistence.Record
    ) -> SelectedRecordPresentation {
        record.briefConformsToCapturedPolicy ? .card : .regenerateNeeded
    }

    static func stateNeedsAttention(_ state: ResponseBriefCoordinator.ChatState) -> Bool {
        switch state.phase {
        case .idle:
            false
        default:
            true
        }
    }

    static func stateTakesPrecedence(
        _ state: ResponseBriefCoordinator.ChatState,
        over record: ResponseBriefPersistence.Record
    ) -> Bool {
        stateNeedsAttention(state) && state.sourceID == record.source.id
    }

    static func shouldShowStateAlongside(
        _ state: ResponseBriefCoordinator.ChatState,
        record: ResponseBriefPersistence.Record
    ) -> Bool {
        stateNeedsAttention(state) && state.sourceID != record.source.id
    }

    static func selectionFollowsLatest(
        recordID: String,
        records: [ResponseBriefPersistence.Record],
        latestSource: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> Bool {
        recordID == latestRecord(in: records, for: latestSource, matching: isEquivalent)?.id
    }

    /// Labels the picker from the coordinator's verified source relationship,
    /// so a reconciled live projection of the latest answer is not shown as a
    /// prior record.
    static func recordPickerRole(
        for record: ResponseBriefPersistence.Record,
        latestSource: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> RecordPickerRole {
        guard let latestSource else { return .prior }
        return isEquivalent(record.source, latestSource) ? .latest : .prior
    }

    /// A pinned-prior warning is only valid when the selected record does not
    /// verify as a projection of the latest answer.
    static func sourceAssociationLabel(
        selectedRecord: ResponseBriefPersistence.Record?,
        latestSource: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> String? {
        guard let latestSource, let selectedRecord,
              !isEquivalent(selectedRecord.source, latestSource)
        else { return nil }
        return "Pinned to a prior response; the latest response is separate from this selection."
    }

    /// The separate prior-original action is only valid when the selected
    /// record does not verify as a projection of the latest answer.
    static func showsSelectedPriorOriginal(
        selectedRecord: ResponseBriefPersistence.Record?,
        latestSource: ResponseBriefSource?,
        matching isEquivalent: @MainActor (ResponseBriefSource, ResponseBriefSource) -> Bool
            = ResponseBriefIdentity.equivalentByVerifiedIdentity
    ) -> Bool {
        guard let latestSource, let selectedRecord else { return false }
        return !isEquivalent(selectedRecord.source, latestSource)
    }

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
    @State private var confirmsBaselineRestart = false
    @State private var showsSourceInformation = false

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
        .alert("Brief source", isPresented: $showsSourceInformation) {
            Button("OK") {}
        } message: {
            Text(sourceInformationText)
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
        .confirmationDialog(
            "Restart briefs from the latest response?",
            isPresented: $confirmsBaselineRestart,
            titleVisibility: .visible
        ) {
            Button("Restart from latest", action: restartFromLatest)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Older completed responses that could not be matched will be skipped and will not be generated. Briefs resume from the latest completed response.")
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
                if let latestSource,
                   ResponseBriefConcisionPolicy(source: latestSource.text, length: coordinator.length).metrics.shouldGenerate {
                    Button("Regenerate latest response", systemImage: "arrow.clockwise") {
                        Task { await coordinator.regenerate(latestSource, transport: transport) }
                    }
                    .disabled(!coordinator.canRegenerate(latestSource))
                }
                if let chat {
                    Button("Reload brief support and models", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await coordinator.refreshSupport(machineID: chat.machineID, transport: transport) }
                    }
                }
                if selectedRecord != nil || latestSource != nil {
                    Button("Source information", systemImage: "info.circle") {
                        showsSourceInformation = true
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

            if chat.map({ !coordinator.isEnabled($0) }) ?? true {
                Text("Opting in sends the latest completed answer and up to two recent exchanges in an additional private Pi model request. It does not change or resume this chat.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            lengthMenu

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

            if Self.shouldShowRecordPicker(
                records: chatRecords,
                latestSource: latestSource,
                matching: coordinator.areEquivalent
            ) {
                recordPicker
            }

            if let sourceAssociationLabel {
                Text(sourceAssociationLabel)
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.muted)
                    .textSelection(.enabled)
            }

            primaryPresentation(state: state, chat: chat)

            if let notice = state.notice,
               selectedRecord == nil || Self.stateNeedsAttention(state) {
                statusLabel(notice, systemImage: "info.circle", color: HerdrTheme.warning)
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

    @ViewBuilder
    private func primaryPresentation(
        state: ResponseBriefCoordinator.ChatState,
        chat: ResponseBriefChatIdentity
    ) -> some View {
        if let record = selectedRecord {
            if Self.stateTakesPrecedence(state, over: record) {
                statePresentation(state, chat: chat)
            } else {
                switch Self.selectedRecordPresentation(for: record) {
                case .card:
                    ScrollView {
                        ResponseBriefCardView(record: record, openDetail: openDetail)
                    }
                case .regenerateNeeded:
                    regenerateControl(for: record.source)
                }

                if Self.shouldShowStateAlongside(state, record: record) {
                    statePresentation(state, chat: chat)
                }
            }
        } else {
            statePresentation(state, chat: chat)
        }
    }

    @ViewBuilder
    private func statePresentation(
        _ state: ResponseBriefCoordinator.ChatState,
        chat: ResponseBriefChatIdentity
    ) -> some View {
        switch state.phase {
        case .checkingSupport:
            statusLabel("Checking companion support…", systemImage: "network", color: HerdrTheme.mist)
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(
                    state.sourceID == latestSource?.id
                        ? "Creating brief for the latest response…"
                        : "Creating an earlier queued brief…"
                )
                .herdrFont(.callout)
            }
            .accessibilityLabel("Creating response brief")
        case .regenerateNeeded:
            if let source = source(for: state) {
                regenerateControl(for: source)
            } else {
                statusLabel(
                    "This brief needs regeneration.",
                    systemImage: "arrow.clockwise.circle",
                    color: HerdrTheme.warning
                )
            }
        case .unsupported:
            statusLabel(
                "Update the companion for response-brief-v1; no fallback was used.",
                systemImage: "arrow.down.circle",
                color: HerdrTheme.warning
            )
        case let .upgradeRequired(message):
            VStack(alignment: .leading, spacing: 8) {
                statusLabel(message, systemImage: "arrow.down.circle", color: HerdrTheme.warning)
                if let source = source(for: state) {
                    Button("Retry after updating", systemImage: "arrow.clockwise") {
                        Task { await coordinator.retry(source, transport: transport) }
                    }
                }
            }
        case let .baselineUnmatched(message):
            VStack(alignment: .leading, spacing: 8) {
                statusLabel(message, systemImage: "exclamationmark.triangle", color: HerdrTheme.alert)
                Button("Restart briefs from latest response", systemImage: "arrow.triangle.2.circlepath") {
                    confirmsBaselineRestart = true
                }
                .accessibilityHint("Starts a new saved baseline at the latest completed response. Unmatched older responses will not be generated.")
            }
        case .oversized:
            statusLabel(
                "This response exceeds the bounded request; use the full original.",
                systemImage: "doc.badge.ellipsis",
                color: HerdrTheme.warning
            )
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                statusLabel(message, systemImage: "exclamationmark.triangle", color: HerdrTheme.alert)
                if let source = source(for: state) {
                    Button("Retry brief", systemImage: "arrow.clockwise") {
                        Task { await coordinator.retry(source, transport: transport) }
                    }
                }
            }
        case .idle:
            if coordinator.isUnsupported(machineID: chat.machineID) {
                statusLabel(
                    "Update the companion for response-brief-v1; no fallback is available.",
                    systemImage: "arrow.down.circle",
                    color: HerdrTheme.warning
                )
            } else if latestSource == nil, coordinator.isEnabled(chat) {
                ContentUnavailableView(
                    "No completed response yet",
                    systemImage: "text.bubble",
                    description: Text("The latest answer will be briefed after Pi finishes.")
                )
                .foregroundStyle(HerdrTheme.mist)
            }
        }
    }

    private func regenerateControl(for source: ResponseBriefSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLabel(
                "Regenerate this response with the current length and model.",
                systemImage: "arrow.clockwise.circle",
                color: HerdrTheme.warning
            )
            Button("Regenerate this brief", systemImage: "arrow.clockwise") {
                Task { await coordinator.regenerate(source, transport: transport) }
            }
            .disabled(!coordinator.canRegenerate(source))
        }
        .accessibilityIdentifier("response-brief-regenerate-needed")
    }

    private func source(for state: ResponseBriefCoordinator.ChatState) -> ResponseBriefSource? {
        guard let chat else { return nil }
        return coordinator.source(for: state, in: chat)
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

    /// The app-wide brief length control, distinct from Thinking. Choosing a
    /// value regenerates the currently selected source (or the latest).
    private var lengthMenu: some View {
        Menu {
            ForEach(ResponseBriefLength.allCases, id: \.rawValue) { option in
                Button {
                    changeLength(to: option)
                } label: {
                    if coordinator.length == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Label("Length · \(coordinator.length.displayName)", systemImage: "text.alignleft")
        }
        .help("App-wide brief length. Changing it regenerates the current brief.")
        .accessibilityLabel("Brief length")
        .accessibilityIdentifier("response-brief-length")
    }

    private var recordPicker: some View {
        HStack {
            Text("Generated source")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.muted)
            Picker("Generated brief source", selection: selectedRecordBinding) {
                Text("Select prior brief").tag(Optional<String>.none)
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

            if let selectedRecord,
               Self.showsSelectedPriorOriginal(
                   selectedRecord: selectedRecord,
                   latestSource: latestSource,
                   matching: coordinator.areEquivalent
               ) {
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
        Self.selectedRecord(
            in: chatRecords,
            selectedRecordID: selectedRecordID,
            followsLatest: followsLatest,
            latestSource: latestSource,
            matching: coordinator.areEquivalent
        )
    }

    private var selectedRecordBinding: Binding<String?> {
        Binding(
            get: { selectedRecord?.id },
            set: { value in
                selectedRecordID = value
                guard let value else {
                    followsLatest = true
                    return
                }
                followsLatest = Self.selectionFollowsLatest(
                    recordID: value,
                    records: chatRecords,
                    latestSource: latestSource,
                    matching: coordinator.areEquivalent
                )
            }
        )
    }

    private var sourceAssociationLabel: String? {
        Self.sourceAssociationLabel(
            selectedRecord: selectedRecord,
            latestSource: latestSource,
            matching: coordinator.areEquivalent
        )
    }

    private var sourceInformationText: String {
        let source = selectedRecord?.source ?? latestSource
        guard let source else { return "No completed response is selected." }
        return "Response ID: \(source.responseID)\nPi session ID: \(source.chat.sessionID)"
    }

    private var contextOmissionNote: String? {
        guard let latestSource,
              ResponseBriefConcisionPolicy(source: latestSource.text, length: coordinator.length).metrics.shouldGenerate,
              let request = try? ResponseBriefRequestBuilder.request(
                for: latestSource,
                model: coordinator.selectedModel,
                thinkingLevel: coordinator.thinkingLevel,
                clientRequestID: "preview-context-request",
                length: coordinator.length
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
            Task { await coordinator.disable(chat, transport: transport) }
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
        if followsLatest {
            selectedRecordID = Self.latestRecord(
                in: chatRecords,
                for: latestSource,
                matching: coordinator.areEquivalent
            )?.id
        } else if let current = selectedRecordID,
                  let pinned = chatRecords.first(where: { $0.id == current }) {
            // A deliberate replacement for the pinned source becomes the
            // visible selection without switching the pin to the latest.
            if let newest = Self.latestRecord(
                in: chatRecords,
                for: pinned.source,
                matching: coordinator.areEquivalent
            ),
               newest.id != current {
                selectedRecordID = newest.id
            }
        } else {
            selectedRecordID = nil
            followsLatest = true
        }
    }

    /// Targets the currently selected source, falling back to the latest
    /// completed source, through one coordinator action.
    private func changeLength(to option: ResponseBriefLength) {
        let target = selectedRecord?.source ?? latestSource
        Task {
            await coordinator.changeLength(
                option,
                chat: chat,
                selectedSource: target,
                transport: transport
            )
        }
    }

    private func restartFromLatest() {
        guard let chat else { return }
        Task { await coordinator.restartBriefsFromLatest(chat, transport: transport) }
    }

    private func recordPickerLabel(_ record: ResponseBriefPersistence.Record) -> String {
        let time = record.createdAt.formatted(date: .omitted, time: .shortened)
        switch Self.recordPickerRole(
            for: record,
            latestSource: latestSource,
            matching: coordinator.areEquivalent
        ) {
        case .latest: return "Latest · \(time)"
        case .prior: return "Prior · \(time)"
        }
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
