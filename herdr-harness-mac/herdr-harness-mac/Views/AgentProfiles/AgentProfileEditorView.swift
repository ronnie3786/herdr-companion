import SwiftUI

struct AgentProfileEditorView: View {
    @Bindable var store: AgentProfilesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            profileEditor
            assignmentEditor
            effectivePreview
        }
        .frame(maxWidth: 900, alignment: .leading)
        .disabled(store.hasPendingMutation)
    }

    private var profileEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Profile name")
                            .herdrFont(.subheadline, weight: .semibold)
                        Spacer()
                        Text("\(store.draft.name.utf8.count) / \(AgentProfileLimits.maximumNameBytes) bytes")
                            .herdrFont(.caption, monospaced: true)
                            .foregroundStyle(store.draft.name.utf8.count <= AgentProfileLimits.maximumNameBytes ? HerdrTheme.muted : HerdrTheme.alert)
                    }
                    TextField("Profile name", text: $store.draft.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("agent-profile-name")
                }

                documentField(
                    title: "SOUL.md",
                    text: $store.draft.soul,
                    byteCount: store.draft.soul.utf8.count,
                    help: "Shared behavior and working principles."
                )
                documentField(
                    title: "USER.md",
                    text: $store.draft.user,
                    byteCount: store.draft.user.utf8.count,
                    help: "Shared preferences and user context."
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Reason for this revision")
                            .herdrFont(.subheadline, weight: .semibold)
                        Spacer()
                        Text("\(store.draft.reason.utf8.count) / \(AgentProfileLimits.maximumReasonBytes) bytes")
                            .herdrFont(.caption, monospaced: true)
                            .foregroundStyle(store.draft.reason.utf8.count <= AgentProfileLimits.maximumReasonBytes ? HerdrTheme.muted : HerdrTheme.alert)
                    }
                    TextField("Required reason", text: $store.draft.reason, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    if store.profileDraftIsBehindServer {
                        Label("Server changed; save will require reconciliation", systemImage: "exclamationmark.triangle")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.alert)
                    } else if store.profileHasUnsavedChanges {
                        Label("Unsaved profile changes", systemImage: "circle.fill")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mauve)
                    }
                    Spacer()
                    if !store.history.isEmpty && !store.isCreatingProfile {
                        Menu("Restore revision", systemImage: "clock.arrow.circlepath") {
                            ForEach(
                                store.history.filter { $0.revision != store.selectedProfile?.revision },
                                id: \.revision
                            ) { revision in
                                Button("Revision \(revision.revision) · \(revision.reason.isEmpty ? revision.actor : revision.reason)") {
                                    Task { await store.restore(revision.revision) }
                                }
                            }
                        }
                        .disabled(
                            store.isSaving
                                || store.isLoadingHistory
                                || store.hasPendingMutation
                                || !store.draft.reasonIsValid
                        )
                    }
                    Button(store.isCreatingProfile ? "Create profile" : "Save revision", systemImage: "checkmark") {
                        Task { await store.createOrUpdateProfile() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.profileDraftCanSave)
                    .accessibilityIdentifier("agent-profile-save")
                }
            }
            .padding(6)
        } label: {
            HStack {
                Label(store.isCreatingProfile ? "New profile" : (store.selectedProfile?.name ?? "Profile"), systemImage: "person.text.rectangle")
                if let baseRevision = store.profileDraftBaseRevision, !store.isCreatingProfile {
                    Text("Draft base r\(baseRevision)")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
        }
    }

    private var assignmentEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Assign a shared profile", isOn: $store.assignmentEnabled)
                    .tint(HerdrTheme.controlAccent)

                if store.assignmentEnabled {
                    Picker("Profile owner", selection: $store.assignmentOwnerMachineID) {
                        Text("Choose a machine").tag(String?.none)
                        ForEach(store.machines) { machine in
                            Text(machine.name).tag(Optional(machine.id))
                        }
                    }
                    .onChange(of: store.assignmentOwnerMachineID) { _, machineID in
                        Task { await store.chooseAssignmentOwner(machineID) }
                    }
                    .accessibilityIdentifier("agent-profile-owner")

                    Picker("Owned profile", selection: $store.assignmentProfileID) {
                        Text(store.isLoadingOwnerProfiles ? "Loading profiles…" : "Choose a profile")
                            .tag(String?.none)
                        ForEach(store.ownerProfiles) { profile in
                            Text("\(profile.name) · r\(profile.revision)").tag(Optional(profile.id))
                        }
                    }
                    .disabled(store.assignmentOwnerMachineID == nil || store.isLoadingOwnerProfiles)
                    .accessibilityIdentifier("agent-profile-assignment")
                }

                Text("Local overrides")
                    .herdrFont(.subheadline, weight: .semibold)
                Text("Overrides add to the selected profile for this data machine. They never change project permissions.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)

                documentField(
                    title: "SOUL override",
                    text: $store.overrideSoul,
                    byteCount: store.overrideSoul.utf8.count,
                    help: "Machine-specific behavior additions."
                )
                documentField(
                    title: "USER override",
                    text: $store.overrideUser,
                    byteCount: store.overrideUser.utf8.count,
                    help: "Machine-specific preference additions."
                )

                HStack {
                    if store.assignmentDraftIsBehindServer {
                        Label("Server changed; save will require reconciliation", systemImage: "exclamationmark.triangle")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.alert)
                    } else if store.assignmentHasUnsavedChanges {
                        Label("Unsaved assignment changes", systemImage: "circle.fill")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mauve)
                    }
                    Spacer()
                    Button("Save assignment", systemImage: "link") {
                        Task { await store.saveAssignment() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.assignmentCanSave || !store.assignmentHasUnsavedChanges)
                    .accessibilityIdentifier("agent-profile-save-assignment")
                }
            }
            .padding(6)
        } label: {
            Label("Assignment & overrides", systemImage: "link")
        }
    }

    private var effectivePreview: some View {
        GroupBox {
            if let effective = store.overview?.effective {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("Source").foregroundStyle(HerdrTheme.mist)
                            Text(effective.profile?.name ?? "No profile")
                        }
                        GridRow {
                            Text("Revision").foregroundStyle(HerdrTheme.mist)
                            Text(effective.profile.map { String($0.revision) } ?? "—")
                                .monospacedDigit()
                        }
                        GridRow {
                            Text("Sync").foregroundStyle(HerdrTheme.mist)
                            Text(effective.syncStatus.capitalized)
                        }
                        GridRow {
                            Text("Last synced").foregroundStyle(HerdrTheme.mist)
                            Text(effective.lastSyncedAt ?? "Not yet")
                        }
                    }
                    .herdrFont(.callout)

                    if let error = effective.error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HerdrTheme.alert)
                    }

                    Text(effective.prompt.isEmpty ? "No effective instructions." : effective.prompt)
                        .herdrFont(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(HerdrTheme.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(6)
            }
        } label: {
            Label("Effective preview", systemImage: "eye")
        }
    }

    private func documentField(
        title: String,
        text: Binding<String>,
        byteCount: Int,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .herdrFont(.subheadline, weight: .semibold)
                Spacer()
                Text("\(byteCount) / \(AgentProfileLimits.maximumDocumentBytes) bytes")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(byteCount <= AgentProfileLimits.maximumDocumentBytes ? HerdrTheme.muted : HerdrTheme.alert)
            }
            Text(help)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            TextField(title, text: text, axis: .vertical)
                .lineLimit(6...14)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
    }
}
