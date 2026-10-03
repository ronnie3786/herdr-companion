import SwiftUI

/// Reviews a roles file's import plan before anything changes on the machine.
struct AgentRolesImportSheet: View {
    let model: AgentRolesShareModel
    @Environment(\.dismiss) private var dismiss

    private var machine: String { model.importMachineName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import to \(machine)").herdrFont(.title2, weight: .semibold)
                if let fileLine {
                    Text(verbatim: fileLine)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Label("Prompts and skills run with your permissions on \(machine).", systemImage: "lock.shield")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.importNotice, !model.isImportCancelled {
                Label {
                    Text(verbatim: notice)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-roles-import-notice")
            }
            if let error = model.importError {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-roles-import-error")
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                if model.isPlanningImport || model.isCommittingImport { ProgressView().controlSize(.small) }
                if !model.replaceRoleIDs.isEmpty, !model.isImportCancelled {
                    Text("\(AgentRolesSharePresentation.plural(model.replaceRoleIDs.count, "role", "roles")) on \(machine) will be replaced.")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer()
                Button(model.importPlan == nil || model.isImportCancelled ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCommittingImport)
                if model.importPlan != nil, !model.isImportCancelled {
                    Button(AgentRolesSharePresentation.importTitle(model.importCount), action: commit)
                        .herdrProminentButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canCommitImport)
                        .accessibilityIdentifier("agent-roles-import-confirm")
                }
            }
        }
        .padding(24)
        .frame(width: 680, height: 640)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.controlAccent)
        .interactiveDismissDisabled(model.isCommittingImport)
        .accessibilityIdentifier("agent-roles-import-sheet")
    }

    private var fileLine: String? {
        let date = model.importExportedAt.map { "Exported \($0.formatted(date: .abbreviated, time: .shortened))" }
        let parts = [model.importFileName, date].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let plan = model.importPlan, !model.isImportCancelled {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                        Label {
                            Text(verbatim: warning)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.importWorkerRoles.isEmpty {
                        section("First Mate roles") {
                            ForEach(model.importWorkerRoles) { row($0, plan: plan) }
                        }
                    }
                    if !model.importReviewRolesWithoutTeam.isEmpty || !model.importTeams.isEmpty {
                        section("PR review agents") {
                            ForEach(model.importReviewRolesWithoutTeam) { row($0, plan: plan) }
                            ForEach(model.importTeams) { team in
                                teamHeader(team.team)
                                ForEach(team.roles) { row($0, plan: plan).padding(.leading, 16) }
                            }
                        }
                    }
                    if !model.importUnchangedRoles.isEmpty { unchanged }
                    if !plan.skills.isEmpty {
                        section("Skills") {
                            ForEach(Array(plan.skills.enumerated()), id: \.offset) { _, skill in
                                AgentRolesImportSkillRow(skill: skill, machine: machine,
                                    usedBy: skill.usedBy.compactMap { id in plan.roles.first { $0.id == id }?.name })
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.importError == nil {
            ProgressView(model.importFileName.map { "Reviewing \($0)…" } ?? "Reviewing roles…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            rows()
        }
    }

    private func teamHeader(_ team: AgentRolesImportPlan.Team) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(verbatim: team.name)
            } icon: {
                Image(systemName: "person.3")
            }
            .herdrFont(.callout, weight: .semibold)
            AgentRolesShareBadge(title: team.createsTeam ? "New team" : "Joins your team",
                                 tint: team.createsTeam ? HerdrTheme.success : HerdrTheme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func row(_ role: AgentRolesImportPlan.Role, plan: AgentRolesImportPlan) -> some View {
        AgentRolesImportRow(role: role, machine: machine,
            selected: Binding(get: { model.isImportSelected(role.id) }, set: { model.setImportRole(role.id, selected: $0) }),
            enabled: !model.isPlanningImport && !model.isCommittingImport)
    }

    private var unchanged: some View {
        let roles = model.importUnchangedRoles
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(roles) { role in
                    Text(verbatim: role.name)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Label("\(roles.count) \(roles.count == 1 ? "role already matches" : "roles already match")",
                  systemImage: "checkmark.circle")
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.secondaryText)
        }
        .padding(10)
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.outline))
        .accessibilityIdentifier("agent-roles-import-unchanged")
    }

    private func commit() {
        Task { if await model.commitImport() { dismiss() } }
    }
}

/// One role in the plan: its checkbox, what importing does, and its contents on request.
struct AgentRolesImportRow: View {
    let role: AgentRolesImportPlan.Role
    let machine: String
    @Binding var selected: Bool
    let enabled: Bool
    @State private var expanded: Bool

    init(role: AgentRolesImportPlan.Role, machine: String, selected: Binding<Bool>, enabled: Bool, expanded: Bool = false) {
        self.role = role
        self.machine = machine
        _selected = selected
        self.enabled = enabled
        _expanded = State(initialValue: expanded)
    }

    private var hasDetails: Bool {
        if role.kind == .update, !role.changes.isEmpty { return true }
        if !role.skills.isEmpty { return true }
        guard let saved = role.role else { return false }
        return role.isPRReview || !saved.systemPrompt.isEmpty || !saved.whenToUse.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: $selected) { Text(verbatim: role.name) }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!role.isSelectable || !enabled)
                    .padding(.top, 5)
                    .accessibilityIdentifier("agent-role-import-row-\(role.id)")
                AgentRolesShareRoleIcon(isPRReview: role.isPRReview, avatar: role.role?.avatar ?? "review")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: role.name)
                            .herdrFont(.callout, weight: .medium)
                            .lineLimit(1)
                        AgentRolesShareBadge(title: AgentRolesSharePresentation.actionTitle(role),
                                             tint: AgentRolesSharePresentation.actionTint(role))
                        if AgentRolesSharePresentation.delegates(role) {
                            AgentRolesShareBadge(title: "Can delegate", tint: HerdrTheme.accent)
                        }
                    }
                    if role.role != nil || !role.skills.isEmpty {
                        Text(verbatim: AgentRolesSharePresentation.importSkillsLine(role))
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                    }
                    ForEach(Array(([role.reason].filter { !$0.isEmpty } + role.notes).enumerated()), id: \.offset) { _, note in
                        Text(verbatim: note)
                            .herdrFont(.caption)
                            .foregroundStyle(role.isSelectable ? HerdrTheme.secondaryText : HerdrTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if hasDetails {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(HerdrTheme.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.herdrPlain)
                    .accessibilityLabel(expanded ? "Hide details" : "Show details")
                    .accessibilityIdentifier("agent-role-import-details-\(role.id)")
                }
            }
            if expanded && hasDetails { details.padding(.leading, 34) }
        }
        .padding(10)
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.outline))
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if role.kind == .update, !role.changes.isEmpty {
                field("Changes", role.changes.joined(separator: ", "), monospaced: false)
            }
            if let saved = role.role {
                if !role.isPRReview, !saved.whenToUse.isEmpty {
                    field("When to use", saved.whenToUse, monospaced: false)
                }
                if !saved.systemPrompt.isEmpty { field("System prompt", saved.systemPrompt, monospaced: true) }
                if role.isPRReview {
                    field("Review prompt", saved.reviewPrompt.isEmpty ? "Uses the default review prompt." : saved.reviewPrompt,
                          monospaced: !saved.reviewPrompt.isEmpty)
                }
            }
            if !role.skills.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills").herdrFont(.caption, weight: .semibold).foregroundStyle(HerdrTheme.secondaryText)
                    ForEach(Array(role.skills.enumerated()), id: \.offset) { _, skill in
                        HStack(spacing: 6) {
                            Image(systemName: AgentRolesSharePresentation.outcomeSymbol(skill.skillOutcome))
                                .foregroundStyle(AgentRolesSharePresentation.outcomeTint(skill.skillOutcome))
                                .accessibilityHidden(true)
                            Text(verbatim: skill.name).herdrFont(.caption, weight: .medium)
                            Text(verbatim: AgentRolesSharePresentation.outcomeTitle(skill.skillOutcome, machine: machine))
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private func field(_ title: String, _ value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).herdrFont(.caption, weight: .semibold).foregroundStyle(HerdrTheme.secondaryText)
            Text(verbatim: value)
                .herdrFont(.caption, monospaced: monospaced)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 6))
        }
    }
}

/// A skill package the file brings, its outcome on this machine, and its files.
struct AgentRolesImportSkillRow: View {
    let skill: AgentRolesImportPlan.Skill
    let machine: String
    let usedBy: [String]
    @State private var showsSkillText = false
    private static let shownFiles = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: AgentRolesSharePresentation.outcomeSymbol(skill.skillOutcome))
                    .foregroundStyle(AgentRolesSharePresentation.outcomeTint(skill.skillOutcome))
                    .accessibilityHidden(true)
                Text(verbatim: skill.name)
                    .herdrFont(.callout, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AgentRolesShareBadge(title: AgentRolesSharePresentation.outcomeTitle(skill.skillOutcome, machine: machine),
                                     tint: AgentRolesSharePresentation.outcomeTint(skill.skillOutcome))
            }
            if !skill.description.isEmpty {
                Text(verbatim: skill.description)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(3)
            }
            Text(verbatim: AgentRolesSharePresentation.outcomeDetail(skill.skillOutcome, machine: machine)
                 + (usedBy.isEmpty ? "" : " Used by \(usedBy.joined(separator: ", ")).")
                 + (skill.executableFiles > 0 ? " Includes \(AgentRolesSharePresentation.plural(skill.executableFiles, "executable file", "executable files"))." : ""))
                .herdrFont(.caption2)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !skill.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(skill.files.prefix(Self.shownFiles).enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 6) {
                            Image(systemName: file.executable ? "terminal" : "doc")
                                .foregroundStyle(file.executable ? HerdrTheme.warning : HerdrTheme.iconTint)
                                .frame(width: 14)
                                .accessibilityHidden(true)
                            Text(verbatim: file.path)
                                .herdrFont(.caption, monospaced: true)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if file.executable { AgentRolesShareBadge(title: "Executable", tint: HerdrTheme.warning) }
                            Spacer(minLength: 4)
                            Text(verbatim: AgentRolesSharePresentation.size(file.bytes))
                                .herdrFont(.caption, monospacedDigit: true)
                                .foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }
                    if skill.files.count > Self.shownFiles {
                        Text("and \(skill.files.count - Self.shownFiles) more")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
                .padding(8)
                .background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 6))
            }
            if !skill.skillText.isEmpty {
                DisclosureGroup(isExpanded: $showsSkillText) {
                    Text(verbatim: skill.skillText)
                        .herdrFont(.caption, monospaced: true)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 6))
                } label: {
                    Text("SKILL.md").herdrFont(.caption, monospaced: true)
                }
            }
        }
        .padding(12)
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.outline))
    }
}
