import SwiftUI

/// The profile the selected machine uses: its Soul and User documents, where
/// it lives, and a way to switch to another profile.
struct AgentProfileEditorCard: View {
    @Bindable var store: AgentProfilesStore
    @Binding var document: AgentProfileDocument
    let choose: (AgentProfilesStore.ProfileChoice?) -> Void
    let newProfile: () -> Void
    let rename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            Divider().overlay(HerdrTheme.separator)

            VStack(alignment: .leading, spacing: 10) {
                documentTabs
                if let note = store.editingOwnerNote {
                    Label(note, systemImage: store.isLoading ? "hourglass" : "wifi.slash")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                editor
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider().overlay(HerdrTheme.separator)

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(HerdrTheme.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-profile-editor")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(String(profileName.prefix(1)).uppercased())
                .herdrFont(.title3, weight: .bold)
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 38, height: 38)
                .background(HerdrTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(profileName)
                    .herdrFont(.title3, weight: .semibold)
                    .lineLimit(1)
                Text(whereItLives)
                    .herdrFont(.caption)
                    .foregroundStyle(syncProblem ? HerdrTheme.warning : HerdrTheme.mist)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            switchMenu

            Menu {
                Button("Rename…", action: rename)
                    .disabled(!store.canChangeSavedProfile)
                if store.editingProfileIsShared {
                    Button("Sync Now") { Task { await store.syncNow() } }
                        .disabled(store.isLocked)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("More profile actions")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("agent-profile-more")
        }
    }

    private var switchMenu: some View {
        let choices = store.profileChoices
        let active = store.activeReference
        let primary = choices.filter { !$0.isUnusedStarter || $0.reference == active }
        let starters = choices.filter { $0.isUnusedStarter && $0.reference != active }
        return Menu {
            Section("Use on \(store.selectedMachine?.name ?? "this machine")") {
                ForEach(primary) { choice in
                    choiceButton(choice, isActive: choice.reference == active)
                }
            }
            if !starters.isEmpty {
                Menu("Empty Profiles") {
                    ForEach(starters) { choice in
                        choiceButton(choice, isActive: false)
                    }
                }
            }
            Divider()
            Button("New Profile…", action: newProfile)
            if active != nil {
                Button("Don't Use a Profile") { choose(nil) }
            }
        } label: {
            Label("Switch", systemImage: "arrow.left.arrow.right")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(store.isLocked)
        .help("Choose which profile agents on this machine use")
        .accessibilityIdentifier("agent-profile-switch")
    }

    private func choiceButton(_ choice: AgentProfilesStore.ProfileChoice, isActive: Bool) -> some View {
        Button {
            choose(choice)
        } label: {
            let title = "\(choice.profile.name) · \(choice.owner.name)"
            if isActive {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: - Documents

    private var documentTabs: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Document", selection: $document) {
                ForEach(AgentProfileDocument.allCases) { document in
                    Text(isDirty(document) ? "\(document.title) •" : document.title).tag(document)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("agent-profile-document")

            Text(document.summary)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(2)
        }
    }

    private var editor: some View {
        let text = document == .soul ? $store.soulDraft : $store.userDraft
        let isTooLong = document == .soul ? store.soulIsTooLong : store.userIsTooLong
        return ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .herdrFont(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .disabled(!store.editingProfileIsEditable || store.isLocked)
                .accessibilityLabel(document.title)
                .accessibilityIdentifier("agent-profile-\(document.rawValue)")

            if text.wrappedValue.isEmpty {
                Text(document.placeholder)
                    .herdrFont(.body)
                    .lineSpacing(3)
                    .foregroundStyle(HerdrTheme.muted.opacity(0.6))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTooLong ? HerdrTheme.alert : HerdrTheme.separator, lineWidth: 1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            footerStatus
            Spacer(minLength: 8)
            if store.profileHasUnsavedChanges {
                Button("Revert", action: store.revertProfile)
                    .buttonStyle(.bordered)
                    .disabled(store.isLocked)
            }
            Button {
                Task { await store.saveProfile() }
            } label: {
                if store.isSaving {
                    ProgressView().controlSize(.small).frame(width: 36)
                } else {
                    Text("Save")
                        .frame(minWidth: 36)
                }
            }
            .herdrProminentButton()
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!store.canSaveProfile)
            .accessibilityIdentifier("agent-profile-save")
        }
    }

    @ViewBuilder
    private var footerStatus: some View {
        if store.soulIsTooLong || store.userIsTooLong {
            Label(
                "\(store.soulIsTooLong ? "Soul" : "User") is over the 16 KB limit.",
                systemImage: "exclamationmark.triangle"
            )
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.alert)
        } else if store.profileDraftIsBehindServer {
            Label("Changed elsewhere since you started editing", systemImage: "exclamationmark.triangle")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.warning)
        } else if store.profileHasUnsavedChanges {
            Label {
                Text(shareNote)
            } icon: {
                Circle().fill(HerdrTheme.mauve).frame(width: 7, height: 7)
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mauve)
        } else if let updated = AgentProfileDates.relative(store.editingProfile?.updatedAt) {
            Text("Updated \(updated)")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
        }
    }

    // MARK: - Text

    private var profileName: String {
        store.editingProfile?.name ?? "Profile"
    }

    private var ownerName: String? {
        store.editingReference.map(store.ownerName(for:))
    }

    private var otherUsers: [String] {
        guard let reference = store.editingReference else { return [] }
        return store.machinesUsing(reference)
            .filter { $0.id != store.selectedMachineID }
            .map(\.name)
    }

    private var syncProblem: Bool {
        guard store.editingProfileIsShared, let effective = store.selectedOverview?.effective else { return false }
        return effective.syncStatus == "unavailable" || !(effective.error ?? "").isEmpty
    }

    private var whereItLives: String {
        var parts: [String] = []
        if store.editingProfileIsShared, let ownerName {
            parts.append("Shared from \(ownerName)")
            if syncProblem {
                parts.append("couldn't sync")
            } else if let synced = AgentProfileDates.relative(store.selectedOverview?.effective.lastSyncedAt) {
                parts.append("synced \(synced)")
            }
        } else {
            parts.append("Saved on this machine")
        }
        if !otherUsers.isEmpty {
            parts.append("also used by \(ListFormatter.localizedString(byJoining: otherUsers))")
        }
        return parts.joined(separator: " · ")
    }

    private var shareNote: String {
        let everyone = otherUsers
        guard store.editingProfileIsShared || !everyone.isEmpty else { return "Unsaved changes" }
        let machines = ([store.selectedMachine?.name].compactMap { $0 } + everyone)
        return "Unsaved · applies to \(ListFormatter.localizedString(byJoining: machines))"
    }

    private func isDirty(_ document: AgentProfileDocument) -> Bool {
        store.hasUnsavedChanges(in: document)
    }
}
