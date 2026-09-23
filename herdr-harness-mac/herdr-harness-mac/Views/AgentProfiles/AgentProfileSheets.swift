import SwiftUI

/// Shared chrome for Agent Profiles sheets: a title block, content and a
/// trailing button row.
private struct AgentProfileSheetChrome<Content: View, Buttons: View>: View {
    let title: String
    let subtitle: String
    var store: AgentProfilesStore?
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .herdrFont(.title3, weight: .semibold)
                Text(subtitle)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider().overlay(HerdrTheme.separator)

            if let store {
                // Sheets cover the main screen's notices, so repeat them here.
                // Reload happens from the main screen, which confirms first.
                AgentProfileStoreNotices(store: store) { dismiss() }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(HerdrTheme.separator)

            HStack(spacing: 10) {
                buttons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.accent)
    }
}

// MARK: - Suggestions

struct AgentProfileSuggestionsSheet: View {
    let store: AgentProfilesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AgentProfileSheetChrome(
            title: "Suggested edits",
            subtitle: "Agents can suggest changes to a profile. Nothing changes until you approve.",
            store: store
        ) {
            if store.suggestions.isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "checkmark.circle",
                    description: Text("There are no suggestions waiting.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.suggestions) { suggestion in
                            card(suggestion)
                        }
                    }
                    .padding(20)
                }
            }
        } buttons: {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 460, idealHeight: 620)
    }

    private func card(_ suggestion: AgentProfilesStore.Suggestion) -> some View {
        let current = suggestion.current
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.name ?? "Unknown profile")
                        .herdrFont(.headline, weight: .semibold)
                    Text(byline(suggestion))
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                }
                Spacer()
            }

            if !suggestion.proposal.reason.isEmpty {
                Text("“\(suggestion.proposal.reason)”")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.mist)
            }

            diffSection(.soul, old: current?.soul ?? "", new: suggestion.proposal.soul)
            diffSection(.user, old: current?.user ?? "", new: suggestion.proposal.user)

            if suggestion.isOutdated {
                Label(
                    "The profile changed after this was suggested. Decline it and ask the agent to suggest again.",
                    systemImage: "exclamationmark.triangle"
                )
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Decline") { Task { await store.decline(suggestion) } }
                    .buttonStyle(.bordered)
                    .disabled(store.isLocked)
                Button("Approve") { Task { await store.approve(suggestion) } }
                    .herdrProminentButton()
                    .disabled(store.isLocked || suggestion.isOutdated || current == nil)
            }
        }
        .padding(16)
        .background(HerdrTheme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(suggestion.isOutdated ? HerdrTheme.warning.opacity(0.5) : HerdrTheme.separator)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-profile-suggestion-\(suggestion.id)")
    }

    private func byline(_ suggestion: AgentProfilesStore.Suggestion) -> String {
        let when = AgentProfileDates.relative(suggestion.proposal.createdAt).map { " · \($0)" } ?? ""
        return "Suggested by an agent\(when)"
    }

    @ViewBuilder
    private func diffSection(_ document: AgentProfileDocument, old: String, new: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.title)
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
            if old == new {
                Text("No changes")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            } else {
                AgentProfileDiffView(lines: AgentProfileLineDiff.lines(from: old, to: new))
            }
        }
    }
}

struct AgentProfileDiffView: View {
    let lines: [AgentProfileLineDiff.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(line.kind))
                        .herdrFont(.callout, monospaced: true, weight: .semibold)
                        .foregroundStyle(color(line.kind))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    Text(line.text.isEmpty ? " " : line.text)
                        .herdrFont(.callout)
                        .foregroundStyle(line.kind == .unchanged ? HerdrTheme.mist : HerdrTheme.text)
                        .strikethrough(line.kind == .removed, color: HerdrTheme.diffRemove.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(background(line.kind))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(line))
            }
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .clipShape(RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
    }

    private func marker(_ kind: AgentProfileLineDiff.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .unchanged: " "
        }
    }

    private func color(_ kind: AgentProfileLineDiff.Kind) -> Color {
        switch kind {
        case .added: HerdrTheme.diffAdd
        case .removed: HerdrTheme.diffRemove
        case .unchanged: HerdrTheme.muted
        }
    }

    private func background(_ kind: AgentProfileLineDiff.Kind) -> Color {
        switch kind {
        case .added: HerdrTheme.diffAdd.opacity(0.13)
        case .removed: HerdrTheme.diffRemove.opacity(0.13)
        case .unchanged: .clear
        }
    }

    private func accessibilityLabel(_ line: AgentProfileLineDiff.Line) -> String {
        switch line.kind {
        case .added: "Added: \(line.text)"
        case .removed: "Removed: \(line.text)"
        case .unchanged: line.text
        }
    }
}

// MARK: - History

struct AgentProfileHistorySheet: View {
    let store: AgentProfilesStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRevision: Int?
    @State private var confirmsRestore = false

    var body: some View {
        AgentProfileSheetChrome(
            title: "\(store.editingProfile?.name ?? "Profile") history",
            subtitle: "Every save is kept. Restoring a version saves it as a new revision.",
            store: store
        ) {
            if store.isLoadingHistory && store.history.isEmpty {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.historyError, store.history.isEmpty {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "clock.badge.exclamationmark",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(store.history, id: \.revision, selection: $selectedRevision) { revision in
                        row(revision).tag(revision.revision)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(HerdrTheme.ink)
                    .frame(width: 230)

                    Divider().overlay(HerdrTheme.separator)

                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } buttons: {
            if !store.canChangeSavedProfile && store.profileHasUnsavedChanges {
                Text("Save or revert your edits to restore a version.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer()
            Button("Restore This Version") { confirmsRestore = true }
                .buttonStyle(.bordered)
                .disabled(!canRestore)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .task {
            await store.loadHistory()
            selectedRevision = store.history.first?.revision
        }
        .confirmationDialog(
            "Restore revision \(selectedRevision ?? 0)?",
            isPresented: $confirmsRestore,
            titleVisibility: .visible
        ) {
            Button("Restore") {
                guard let revision = selected else { return }
                Task {
                    await store.restore(revision)
                    await store.loadHistory()
                    selectedRevision = store.history.first?.revision
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its Soul and User become the current version. Nothing is deleted.")
        }
    }

    private var selected: AgentProfile? {
        store.history.first { $0.revision == selectedRevision }
    }

    private var canRestore: Bool {
        guard let selected, let current = store.history.first else { return false }
        return selected.revision != current.revision && store.canChangeSavedProfile
    }

    private func row(_ revision: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Revision \(revision.revision)")
                    .herdrFont(.callout, weight: .semibold)
                if revision.revision == store.history.first?.revision {
                    Text("Current")
                        .herdrFont(.caption2, weight: .semibold)
                        .foregroundStyle(HerdrTheme.signal)
                }
            }
            Text(revision.reason.isEmpty ? revision.actor : revision.reason)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
            if let when = AgentProfileDates.relative(revision.updatedAt) {
                Text(when)
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var preview: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AgentProfileDocument.allCases) { document in
                        let text = document == .soul ? selected.soul : selected.user
                        VStack(alignment: .leading, spacing: 6) {
                            Text(document.title)
                                .herdrFont(.caption, weight: .semibold)
                                .foregroundStyle(HerdrTheme.mist)
                            Text(text.isEmpty ? "Empty" : text)
                                .herdrFont(.callout)
                                .foregroundStyle(text.isEmpty ? HerdrTheme.muted : HerdrTheme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(HerdrTheme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
                        }
                    }
                }
                .padding(20)
            }
        } else {
            Text("Choose a revision to see it.")
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Machine-only additions

struct AgentProfileAdditionsSheet: View {
    @Bindable var store: AgentProfilesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let machine = store.selectedMachine?.name ?? "this machine"
        AgentProfileSheetChrome(
            title: "Only on \(machine)",
            subtitle: "Notes added after the profile, only for agents on \(machine). Useful for machine-specific details.",
            store: store
        ) {
            VStack(alignment: .leading, spacing: 14) {
                field("Soul additions", text: $store.overrideSoul, placeholder: "- Keep replies extra short on this machine.")
                field("User additions", text: $store.overrideUser, placeholder: "- Repositories on this machine live in ~/work.")
            }
            .padding(20)
            .disabled(store.isLocked)
        } buttons: {
            if store.overridesHaveUnsavedChanges {
                Button("Revert", action: store.revertOverrides)
                    .buttonStyle(.bordered)
                    .disabled(store.isLocked)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Unsaved notes stay here until you save or revert them")
            Button("Save") {
                Task {
                    await store.saveOverrides()
                    if !store.overridesHaveUnsavedChanges && store.errorMessage == nil
                        && store.conflictMessage == nil && !store.hasPendingMutation {
                        dismiss()
                    }
                }
            }
            .herdrProminentButton()
            .keyboardShortcut(.defaultAction)
            .disabled(!store.canSaveOverrides)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 520)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .herdrFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .accessibilityLabel(title)
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .herdrFont(.body)
                        .foregroundStyle(HerdrTheme.muted.opacity(0.6))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
            .background(HerdrTheme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(
                        AgentProfileLimits.documentIsValid(text.wrappedValue) ? HerdrTheme.separator : HerdrTheme.alert
                    )
            }
        }
    }
}

// MARK: - Preview

struct AgentProfilePromptSheet: View {
    let store: AgentProfilesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let machine = store.selectedMachine?.name ?? "this machine"
        AgentProfileSheetChrome(
            title: "What agents on \(machine) see",
            subtitle: "New conversations start with this. Conversations already running keep the version they started with.",
            store: store
        ) {
            ScrollView {
                Text(prompt)
                    .herdrFont(.callout, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        } buttons: {
            if let status {
                Text(status)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer()
            if store.editingProfileIsShared {
                Button("Sync Now") { Task { await store.syncNow() } }
                    .buttonStyle(.bordered)
                    .disabled(store.isLocked)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 560)
    }

    private var prompt: String {
        let prompt = store.selectedOverview?.effective.prompt ?? ""
        return prompt.isEmpty ? "No profile is in use, so agents get no extra instructions." : prompt
    }

    private var status: String? {
        guard let effective = store.selectedOverview?.effective else { return nil }
        if let error = effective.error, !error.isEmpty { return "Couldn't sync: \(error)" }
        guard store.editingProfileIsShared,
              let synced = AgentProfileDates.relative(effective.lastSyncedAt) else { return nil }
        return "Synced \(synced)"
    }
}

// MARK: - Naming

struct AgentProfileNameSheet: View {
    let title: String
    let subtitle: String
    let confirmTitle: String
    let submit: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, subtitle: String, confirmTitle: String, initialName: String = "", submit: @escaping (String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.confirmTitle = confirmTitle
        self.submit = submit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        AgentProfileSheetChrome(title: title, subtitle: subtitle) {
            TextField("Name", text: $name, prompt: Text("Side projects"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
                .padding(20)
                .accessibilityIdentifier("agent-profile-name")
        } buttons: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: confirm)
                .herdrProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!AgentProfileLimits.nameIsValid(name))
        }
        .frame(width: 420)
    }

    private func confirm() {
        guard AgentProfileLimits.nameIsValid(name) else { return }
        submit(name)
        dismiss()
    }
}
