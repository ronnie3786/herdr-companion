import SwiftUI

/// Chooses saved roles and PR review agents to write to a roles file.
struct AgentRolesExportSheet: View {
    let model: AgentRolesShareModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Export Roles").herdrFont(.title2, weight: .semibold)
                Text("Choose roles saved on \(model.exportMachineName) to share as a file teammates can import.")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if model.store.hasUnsavedChanges {
                    Label("Unsaved edits aren't included.", systemImage: "info.circle")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.warning)
                        .accessibilityIdentifier("agent-roles-export-unsaved")
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("Prompts and skill files, including scripts, are shared exactly as saved. Agent Profiles aren't included.")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.exportError {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-roles-export-error")
            }
            HStack(spacing: 10) {
                if model.isExporting || isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AgentRolesSharePresentation.exportTitle(model.exportCount), action: export)
                    .herdrProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport || isSaving)
                    .accessibilityIdentifier("agent-roles-export-confirm")
            }
        }
        .padding(24)
        .frame(width: 640, height: 600)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.controlAccent)
        .task { if model.exportPreview == nil, model.exportError == nil { await model.loadExportPreview() } }
        .accessibilityIdentifier("agent-roles-export-sheet")
    }

    @ViewBuilder private var content: some View {
        if model.isLoadingExportPreview {
            ProgressView("Loading roles…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.exportPreview {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.exportWorkerRoles.isEmpty {
                        section("First Mate roles") {
                            ForEach(model.exportWorkerRoles) { row($0) }
                        }
                    }
                    if !model.exportReviewRolesWithoutTeam.isEmpty || !model.exportTeams.isEmpty {
                        section("PR review agents") {
                            ForEach(model.exportReviewRolesWithoutTeam) { row($0) }
                            ForEach(model.exportTeams) { team in
                                teamHeader(team)
                                ForEach(team.roles) { row($0).padding(.leading, 22) }
                            }
                        }
                    }
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        Label {
                            Text(verbatim: warning)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 2) { rows() }
                .padding(6)
                .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.outline))
        }
    }

    private func teamHeader(_ team: AgentRolesShareModel.ExportTeam) -> some View {
        let shareable = team.roles.filter(\.shareable)
        let members = shareable.map { role in
            Binding(get: { model.isExportSelected(role.id) }, set: { model.setExportRole(role.id, selected: $0) })
        }
        return HStack(spacing: 8) {
            Toggle(sources: members, isOn: \.self) {
                Label {
                    Text(verbatim: team.name)
                } icon: {
                    Image(systemName: "person.3")
                }
                .herdrFont(.callout, weight: .semibold)
            }
            .toggleStyle(.checkbox)
            .disabled(shareable.isEmpty || model.isExporting)
            .accessibilityIdentifier("agent-roles-export-team-\(team.name)")
            Text(AgentRolesSharePresentation.plural(team.roles.count, "agent", "agents"))
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ role: AgentRolesSharePreview.Role) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.isExportSelected(role.id) },
                                 set: { model.setExportRole(role.id, selected: $0) })) {
                Text(verbatim: role.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!role.shareable || model.isExporting)
            .accessibilityIdentifier("agent-role-export-row-\(role.id)")
            AgentRolesShareRoleIcon(isPRReview: role.isPRReview, avatar: role.avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: role.name)
                        .herdrFont(.callout, weight: .medium)
                        .lineLimit(1)
                    if !role.shareable { AgentRolesShareBadge(title: "Default") }
                }
                Text(verbatim: AgentRolesSharePresentation.exportSubtitle(role))
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(role.shareable ? 1 : 0.62)
    }

    private func export() {
        Task {
            guard let export = await model.exportSelectedRoles() else { return }
            isSaving = true
            AgentRolesSharePanels.save(export, model: model) { saved in
                isSaving = false
                if saved { dismiss() }
            }
        }
    }
}
