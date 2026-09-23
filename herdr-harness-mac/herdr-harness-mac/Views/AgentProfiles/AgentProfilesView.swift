import SwiftUI

struct AgentProfilesView: View {
    private enum Sheet: String, Identifiable {
        case suggestions, history, additions, prompt, newProfile, rename
        var id: String { rawValue }
    }

    /// A change that would drop unsaved edits waits here for confirmation.
    private enum PendingDiscard: Equatable {
        case machine(String)
        case choice(AgentProfilesStore.ProfileChoice?)
        case newProfile
        case reload
    }

    @State private var store: AgentProfilesStore
    @State private var document = AgentProfileDocument.soul
    @State private var sheet: Sheet?
    @State private var pendingDiscard: PendingDiscard?

    init(model: HerdrAppModel) {
        _store = State(initialValue: AgentProfilesStore(model: model))
    }

    init(store: AgentProfilesStore, document: AgentProfileDocument = .soul) {
        _store = State(initialValue: store)
        _document = State(initialValue: document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 20)
                .padding(.bottom, 14)

            if store.machines.isEmpty {
                ContentUnavailableView(
                    "No machines yet",
                    systemImage: "desktopcomputer",
                    description: Text("Add a machine in Settings › Machines, then give its agents a profile here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    AgentProfilesMachineBar(store: store, select: { request(.machine($0)) })
                    notices
                    content
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: 960, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrBackground())
        .foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.accent)
        .accessibilityIdentifier("agent-profiles-view")
        .task { await store.load() }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog(
            "Discard unsaved edits?",
            isPresented: discardIsPresented,
            titleVisibility: .visible
        ) {
            Button("Discard Edits", role: .destructive, action: confirmDiscard)
            Button("Keep Editing", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("Your unsaved Soul, User, or machine-only edits will be lost.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Profiles")
                    .herdrFont(.title2, weight: .semibold)
                Text("Give your agents a personality (Soul) and context about you (User). Each machine uses one profile.")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if store.isLoading || store.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading Agent Profiles")
            }
            Button {
                request(.reload)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel("Reload")
            }
            .buttonStyle(.borderless)
            .help("Reload profiles from every machine")
            .disabled(store.isLoading || store.isSaving)
            .accessibilityIdentifier("agent-profiles-reload")
        }
    }

    // MARK: - Notices

    private var notices: some View {
        AgentProfileStoreNotices(store: store) { request(.reload) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let machine = store.selectedMachine {
            switch store.status(for: machine.id) {
            case .loading:
                messageCard {
                    ProgressView("Loading \(machine.name)…")
                }
            case let .unavailable(message):
                messageCard {
                    ContentUnavailableView {
                        Label("\(machine.name) isn't reachable", systemImage: "wifi.slash")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await store.load() } }
                    }
                }
            case .needsUpdate:
                messageCard {
                    ContentUnavailableView(
                        "Update the companion on \(machine.name)",
                        systemImage: "arrow.down.circle",
                        description: Text("This machine's companion server is too old for Agent Profiles.")
                    )
                }
            case .loaded:
                loadedContent
            }
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if !store.suggestions.isEmpty {
            suggestionBanner
        }
        if store.editingReference == nil {
            noProfileCard
            secondaryActions
        } else {
            AgentProfileEditorCard(
                store: store,
                document: $document,
                choose: { request(.choice($0)) },
                newProfile: { request(.newProfile) },
                rename: { sheet = .rename }
            )
            secondaryActions
        }
    }

    private var suggestionBanner: some View {
        let suggestions = store.suggestions
        var names: [String] = []
        for name in suggestions.map({ $0.current?.name ?? "a profile" }) where !names.contains(name) {
            names.append(name)
        }
        let title = suggestions.count == 1
            ? "An agent suggested an edit to \(names.first ?? "a profile")"
            : "Agents suggested \(suggestions.count) edits to \(ListFormatter.localizedString(byJoining: names))"
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .herdrFont(.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.mauve)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .herdrFont(.callout, weight: .semibold)
                Text("Nothing changes until you approve.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            Spacer()
            Button("Review") { sheet = .suggestions }
                .herdrProminentButton()
                .accessibilityIdentifier("agent-profiles-review-suggestions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(HerdrTheme.mauve.opacity(0.1), in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.mauve.opacity(0.35))
        }
    }

    private var noProfileCard: some View {
        let choices = store.profileChoices
        let primary = choices.filter { !$0.isUnusedStarter }
        let starters = choices.filter(\.isUnusedStarter)
        let machine = store.selectedMachine?.name ?? "This machine"
        return VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(HerdrTheme.muted)
                .accessibilityHidden(true)
            Text("\(machine) doesn't use a profile")
                .herdrFont(.title3, weight: .semibold)
            Text(
                store.savedOverridesAreEmpty
                    ? "Agents here get no Soul or User context. Pick a profile to share one across machines, or start a new one."
                    : "Agents here only get this machine's notes. Pick a profile to share one across machines, or start a new one."
            )
            .herdrFont(.callout)
            .foregroundStyle(HerdrTheme.mist)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if !choices.isEmpty {
                    Menu("Use a Profile") {
                        ForEach(primary) { choice in
                            Button("\(choice.profile.name) · \(choice.owner.name)") { request(.choice(choice)) }
                        }
                        if !starters.isEmpty {
                            Menu("Empty Profiles") {
                                ForEach(starters) { choice in
                                    Button("\(choice.profile.name) · \(choice.owner.name)") { request(.choice(choice)) }
                                }
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .accessibilityIdentifier("agent-profiles-use")
                }
                Button("New Profile…") { request(.newProfile) }
                    .herdrProminentButton()
            }
            .disabled(store.isLocked)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.separator)
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 18) {
            if store.editingReference != nil {
                Button { sheet = .history } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!store.editingProfileIsEditable)
                .accessibilityIdentifier("agent-profile-history")
            }

            Button { sheet = .additions } label: {
                Label(additionsTitle, systemImage: "desktopcomputer")
            }
            .accessibilityIdentifier("agent-profile-additions")

            Button { sheet = .prompt } label: {
                Label("Preview What Agents See", systemImage: "eye")
            }
            .accessibilityIdentifier("agent-profile-preview")

            Spacer()
        }
        .buttonStyle(.borderless)
        .herdrFont(.callout)
        .foregroundStyle(HerdrTheme.mist)
        .padding(.horizontal, 4)
    }

    private var additionsTitle: String {
        let machine = store.selectedMachine?.name ?? "This Machine"
        let title = store.savedOverridesAreEmpty ? "Add Notes for \(machine)" : "Notes for \(machine)"
        return store.overridesHaveUnsavedChanges ? "\(title) (unsaved)" : title
    }

    private func messageCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HerdrTheme.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.separator)
            }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .suggestions:
            AgentProfileSuggestionsSheet(store: store)
        case .history:
            AgentProfileHistorySheet(store: store)
        case .additions:
            AgentProfileAdditionsSheet(store: store)
        case .prompt:
            AgentProfilePromptSheet(store: store)
        case .newProfile:
            AgentProfileNameSheet(
                title: "New profile",
                subtitle: "Saved on \(store.selectedMachine?.name ?? "this machine") and used there right away. Other machines can switch to it too.",
                confirmTitle: "Create"
            ) { name in
                Task { await store.createProfile(named: name) }
            }
        case .rename:
            AgentProfileNameSheet(
                title: "Rename profile",
                subtitle: "Every machine using this profile sees the new name.",
                confirmTitle: "Rename",
                initialName: store.editingProfile?.name ?? ""
            ) { name in
                Task { await store.rename(to: name) }
            }
        }
    }

    // MARK: - Unsaved edits

    private var discardIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDiscard != nil },
            set: { if !$0 { pendingDiscard = nil } }
        )
    }

    private func request(_ change: PendingDiscard) {
        if case let .machine(machineID) = change, machineID == store.selectedMachineID { return }
        if case .reload = change, store.hasPendingMutation {
            // A read is safe while a change is unconfirmed, and keeps its drafts.
            Task { await store.load() }
            return
        }
        if store.hasUnsavedChanges {
            pendingDiscard = change
        } else {
            apply(change)
        }
    }

    private func confirmDiscard() {
        guard let change = pendingDiscard else { return }
        pendingDiscard = nil
        store.discardDrafts()
        apply(change)
    }

    private func apply(_ change: PendingDiscard) {
        switch change {
        case let .machine(machineID):
            store.selectMachine(machineID)
        case let .choice(choice):
            Task { await store.use(choice) }
        case .newProfile:
            sheet = .newProfile
        case .reload:
            Task { await store.reloadDiscardingDrafts() }
        }
    }
}
