import AppKit
import SwiftUI

struct AgentRoleSaveBar: View {
    let store: AgentRolesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.missingExecutionSkillIDs.isEmpty {
                Label("\(store.missingExecutionSkillIDs.count) selected \(store.missingExecutionSkillIDs.count == 1 ? "skill is" : "skills are") missing on \(store.selectedMachine?.name ?? "the execution computer"). Use Update Copies in Skills, or remove the unavailable selections.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-role-execution-copy-warning")
            }
            if let error = store.errorMessage ?? store.validationMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HerdrTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.errorMessage != nil {
                        Button("Copy Edits", systemImage: "doc.on.doc", action: copyEdits)
                            .buttonStyle(.borderless)
                    }
                }
                .herdrFont(.caption)
                .accessibilityIdentifier("agent-role-save-error")
            }
            HStack(spacing: 10) {
                Text(store.isSavingTeams ? "Saving teams…" : store.isSaving ? "Saving role and skill packages…" : store.hasUnsavedChanges ? "Unsaved changes" : store.savedMessage ?? "Changes apply to new sessions.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Discard", action: discard)
                    .disabled(!store.hasUnsavedChanges || store.isSaving)
                    .accessibilityIdentifier("agent-role-discard")
                Button("Save", action: save)
                    .herdrProminentButton()
                    .disabled(!store.canSave)
                    .accessibilityIdentifier("agent-role-save")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(HerdrTheme.inkFill(0.025))
        .overlay(alignment: .top) { Divider() }
    }

    private func save() { Task { await store.save() } }
    private func discard() {
        store.discard()
        Task { await store.loadIfNeeded() }
    }
    private func copyEdits() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.unsavedEditsText, forType: .string)
    }
}
