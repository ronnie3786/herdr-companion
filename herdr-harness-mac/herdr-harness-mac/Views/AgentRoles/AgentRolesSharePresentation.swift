import Foundation
import SwiftUI

/// Wording shared by the export and import sheets.
enum AgentRolesSharePresentation {
    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    static func exportTitle(_ count: Int) -> String {
        "Export \(count) \(count == 1 ? "Role" : "Roles")…"
    }

    static func importTitle(_ count: Int) -> String {
        "Import \(count) \(count == 1 ? "Role" : "Roles")"
    }

    /// "3 skills · 120 KB", "Automatic skills (not included)" or "1 skill isn't stored here".
    static func exportSubtitle(_ role: AgentRolesSharePreview.Role) -> String {
        if !role.shareable { return role.note.isEmpty ? "Default — nothing to share" : role.note }
        var parts: [String] = []
        if role.automaticSkills {
            parts.append("Automatic skills (not included)")
        } else {
            let included = role.skills.filter(\.included)
            let missing = role.skills.count - included.count
            if !included.isEmpty {
                parts.append("\(plural(included.count, "skill", "skills")) · \(size(included.reduce(0) { $0 + $1.bytes }))")
            } else if missing == 0 {
                parts.append("No skills")
            }
            if missing > 0 { parts.append("\(missing) \(missing == 1 ? "skill isn't" : "skills aren't") stored here") }
        }
        if !role.note.isEmpty { parts.append(role.note) }
        return parts.joined(separator: " · ")
    }

    static func actionTitle(_ role: AgentRolesImportPlan.Role) -> String {
        switch role.kind {
        case .create: "New"
        case .update: "Replaces your \(role.current?.name ?? role.name)"
        case .unchanged: "Unchanged"
        case .skip, .invalid, nil: "Can't import"
        }
    }

    static func actionTint(_ role: AgentRolesImportPlan.Role) -> Color {
        switch role.kind {
        case .create: HerdrTheme.success
        case .update: HerdrTheme.warning
        case .unchanged: HerdrTheme.secondaryText
        case .skip, .invalid, nil: HerdrTheme.alert
        }
    }

    /// Workers that may hand work to other agents.
    static func delegates(_ role: AgentRolesImportPlan.Role) -> Bool {
        !role.isPRReview && role.role?.allowDelegation == true
    }

    /// "3 skills: 1 new, 1 already here, 1 not available".
    static func importSkillsLine(_ role: AgentRolesImportPlan.Role) -> String {
        if role.skills.isEmpty {
            return role.role != nil && role.role?.skillIds == nil ? "Automatic skills" : "No skills"
        }
        let outcomes = role.skills.map(\.skillOutcome)
        let details = [
            (outcomes.count { $0 == .included }, "new"),
            (outcomes.count { $0 == .present || $0 == .available }, "already here"),
            (outcomes.count { $0 == .separate }, "kept separate"),
            (outcomes.count { $0 == .missing || $0 == nil }, "not available"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return "\(plural(role.skills.count, "skill", "skills")): \(details.joined(separator: ", "))"
    }

    static func outcomeTitle(_ outcome: AgentRolesImportPlan.SkillOutcome?, machine: String) -> String {
        switch outcome {
        case .included: "New copy"
        case .present: "Already on \(machine)"
        case .separate: "Kept separate"
        case .available: "Uses \(machine)'s copy"
        case .missing, nil: "Not available"
        }
    }

    static func outcomeDetail(_ outcome: AgentRolesImportPlan.SkillOutcome?, machine: String) -> String {
        switch outcome {
        case .included: "A copy is installed on \(machine)."
        case .present: "An identical copy is already there."
        case .separate: "\(machine) uses this skill's ID for different content, so this copy is added as its own skill."
        case .available: "Shared by name only. \(machine) has a skill with this name and uses it as is."
        case .missing, nil: "Shared by name only and \(machine) doesn't have it, so roles import without it."
        }
    }

    static func outcomeTint(_ outcome: AgentRolesImportPlan.SkillOutcome?) -> Color {
        switch outcome {
        case .included: HerdrTheme.success
        case .present, .available: HerdrTheme.secondaryText
        case .separate: HerdrTheme.accent
        case .missing, nil: HerdrTheme.warning
        }
    }

    static func outcomeSymbol(_ outcome: AgentRolesImportPlan.SkillOutcome?) -> String {
        switch outcome {
        case .included: "plus.circle"
        case .present, .available: "checkmark.circle"
        case .separate: "square.on.square"
        case .missing, nil: "exclamationmark.triangle"
        }
    }
}

/// A small capsule label for row states.
struct AgentRolesShareBadge: View {
    let title: String
    var tint: Color = HerdrTheme.secondaryText

    var body: some View {
        Text(verbatim: title)
            .herdrFont(.caption2, weight: .semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// The icon a role shows in the rail: an avatar for review agents, a person otherwise.
struct AgentRolesShareRoleIcon: View {
    let isPRReview: Bool
    let avatar: String

    var body: some View {
        if isPRReview {
            AgentRoleAvatarView(avatar: avatar, size: 26)
        } else {
            Image(systemName: "person.fill")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.secondaryText)
                .frame(width: 26, height: 26)
                .background(HerdrTheme.firstMateAvatarFill.opacity(0.4), in: Circle())
                .accessibilityHidden(true)
        }
    }
}
