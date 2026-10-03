import Foundation

extension AgentRolesOverview {
    /// Export, dry-run import and committed import of a roles file.
    var supportsSharing: Bool { capabilities?.contains("agent-roles-share-v1") == true }
}

/// Export candidates from `GET /api/v1/agent-roles/export?preview=1`. Carries no
/// prompt or file contents.
struct AgentRolesSharePreview: Decodable, Equatable, Sendable {
    struct Skill: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        /// False for a selected skill with no stored copy; it is shared by name only.
        let included: Bool
        let files: Int
        let bytes: Int
        /// The number of executable files in the stored copy.
        let executable: Int
    }

    struct Role: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let purpose: String
        let builtin: Bool
        let group: String
        let avatar: String
        let allowDelegation: Bool
        /// False for built-ins that still match their defaults.
        let shareable: Bool
        let note: String
        /// The role uses Pi discovery, so there are no skills to include.
        let automaticSkills: Bool
        let skills: [Skill]

        var isPRReview: Bool { purpose == "pr_review" }
        var team: String { group.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    let ok: Bool
    let machineId: String
    let revision: Int
    let roles: [Role]
    let warnings: [String]
}

/// The file as the companion produced it, kept as raw bytes so fields this
/// version doesn't know survive the trip to disk.
struct AgentRolesExport: Equatable, Sendable {
    struct Summary: Decodable, Equatable, Sendable {
        let roles: Int
        let skills: Int
        let files: Int
        let bytes: Int
    }

    let document: Data
    let summary: Summary
    let warnings: [String]
}

/// The dry-run plan, and after a commit the same plan with `imported` and `overview`.
struct AgentRolesImportPlan: Decodable, Equatable, Sendable {
    enum Action: String, Sendable {
        case create, update, unchanged, skip, invalid
    }

    enum SkillOutcome: String, Sendable {
        case included, present, separate, available, missing
    }

    struct Team: Decodable, Equatable, Sendable {
        let name: String
        /// "joins" an existing team with the same name, or "creates" it.
        let status: String
        var createsTeam: Bool { status == "creates" }
    }

    struct RoleSkill: Decodable, Equatable, Sendable {
        let id: String
        let sourceId: String
        let name: String
        let outcome: String
        var skillOutcome: SkillOutcome? { SkillOutcome(rawValue: outcome) }
    }

    struct Role: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let purpose: String
        let builtin: Bool
        let action: String
        let reason: String
        let selectedByDefault: Bool
        /// The role exactly as it would be saved.
        let role: AgentRole?
        /// The role it replaces on this computer.
        let current: AgentRole?
        let changes: [String]
        let team: Team?
        let skills: [RoleSkill]
        let notes: [String]

        var kind: Action? { Action(rawValue: action) }
        var isPRReview: Bool { purpose == "pr_review" }
        var isSelectable: Bool { kind == .create || kind == .update }
    }

    struct SkillFile: Decodable, Equatable, Sendable {
        let path: String
        let bytes: Int
        let executable: Bool
    }

    struct Skill: Decodable, Equatable, Sendable {
        let id: String
        let sourceId: String
        let name: String
        let description: String
        let outcome: String
        let files: [SkillFile]
        let bytes: Int
        let executableFiles: Int
        /// SKILL.md as UTF-8, or empty when too large to preview.
        let skillText: String
        let usedBy: [String]
        var skillOutcome: SkillOutcome? { SkillOutcome(rawValue: outcome) }
    }

    struct Imported: Decodable, Equatable, Sendable {
        let created: Int
        let updated: Int
        let unchanged: Int
    }

    let ok: Bool
    let dryRun: Bool
    let machineId: String
    let revision: Int
    let planDigest: String
    let exportedAt: String?
    let roles: [Role]
    let skills: [Skill]
    let teams: [Team]
    let warnings: [String]
    /// Commit only.
    let imported: Imported?
    /// Commit only: the Agent Roles overview after the import.
    let overview: AgentRolesOverview?
}

/// The checks this Mac makes before sending a file anywhere.
struct AgentRolesShareFileHeader: Equatable, Sendable {
    static let format = "herdr-agent-roles"
    static let supportedVersion = 1

    let version: Int
    let roleCount: Int
    let skillCount: Int
    let exportedAt: String?
    /// Every skill ID the file includes or a role selects, sorted.
    let skillIDs: [String]

    init(validating data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data), let file = object as? [String: Any],
              file["format"] as? String == Self.format else {
            throw AgentRolesShareFileError("This isn't a Herdr roles file. Choose a file exported from Settings › Agent Roles.")
        }
        // Strictly an integer: not a Boolean, a fraction or a string.
        guard let number = file["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number), let version = Int(exactly: number.doubleValue), version >= 1 else {
            throw AgentRolesShareFileError("This roles file is damaged. Ask for a new export.")
        }
        guard version <= Self.supportedVersion else {
            throw AgentRolesShareFileError("This file needs a newer Herdr. Update Herdr, then import it again.")
        }
        guard let roles = file["roles"] as? [Any] else {
            throw AgentRolesShareFileError("This roles file is damaged. Ask for a new export.")
        }
        guard !roles.isEmpty else { throw AgentRolesShareFileError("This roles file has no roles to import.") }
        self.version = version
        roleCount = roles.count
        let skills = file["skills"] as? [Any] ?? []
        skillCount = skills.count
        exportedAt = file["exportedAt"] as? String
        let included = skills.compactMap { ($0 as? [String: Any])?["id"] as? String }
        let selected = roles.flatMap { ($0 as? [String: Any])?["skillIds"] as? [String] ?? [] }
        skillIDs = Set(included + selected).sorted()
    }
}

struct AgentRolesShareFileError: LocalizedError, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: Decoding

// Display fields default when absent, so a companion that adds or omits one
// still produces a reviewable plan. Identity, action and revision are required.

extension AgentRolesSharePreview {
    private enum CodingKeys: String, CodingKey { case ok, machineId, revision, roles, warnings }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        roles = try container.decode([Role].self, forKey: .roles)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

extension AgentRolesExport.Summary {
    private enum CodingKeys: String, CodingKey { case roles, skills, files, bytes }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roles = try container.decodeIfPresent(Int.self, forKey: .roles) ?? 0
        skills = try container.decodeIfPresent(Int.self, forKey: .skills) ?? 0
        files = try container.decodeIfPresent(Int.self, forKey: .files) ?? 0
        bytes = try container.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
    }
}

extension AgentRolesSharePreview.Skill {
    private enum CodingKeys: String, CodingKey { case id, name, included, files, bytes, executable }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        included = try container.decodeIfPresent(Bool.self, forKey: .included) ?? true
        files = try container.decodeIfPresent(Int.self, forKey: .files) ?? 0
        bytes = try container.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        executable = try container.decodeIfPresent(Int.self, forKey: .executable) ?? 0
    }
}

extension AgentRolesSharePreview.Role {
    private enum CodingKeys: String, CodingKey {
        case id, name, purpose, builtin, group, avatar, allowDelegation, shareable, note, automaticSkills, skills
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose) ?? "worker"
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar) ?? "review"
        allowDelegation = try container.decodeIfPresent(Bool.self, forKey: .allowDelegation) ?? false
        shareable = try container.decodeIfPresent(Bool.self, forKey: .shareable) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        automaticSkills = try container.decodeIfPresent(Bool.self, forKey: .automaticSkills) ?? false
        skills = try container.decodeIfPresent([AgentRolesSharePreview.Skill].self, forKey: .skills) ?? []
    }
}

extension AgentRolesImportPlan {
    private enum CodingKeys: String, CodingKey {
        case ok, dryRun, machineId, revision, planDigest, exportedAt, roles, skills, teams, warnings, imported, overview
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        machineId = try container.decodeIfPresent(String.self, forKey: .machineId) ?? ""
        revision = try container.decode(Int.self, forKey: .revision)
        planDigest = try container.decode(String.self, forKey: .planDigest)
        exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt)
        roles = try container.decode([Role].self, forKey: .roles)
        skills = try container.decodeIfPresent([Skill].self, forKey: .skills) ?? []
        teams = try container.decodeIfPresent([Team].self, forKey: .teams) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        imported = try container.decodeIfPresent(Imported.self, forKey: .imported)
        overview = try container.decodeIfPresent(AgentRolesOverview.self, forKey: .overview)
    }
}

extension AgentRolesImportPlan.RoleSkill {
    private enum CodingKeys: String, CodingKey { case id, sourceId, name, outcome }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome) ?? ""
    }
}

extension AgentRolesImportPlan.Role {
    private enum CodingKeys: String, CodingKey {
        case id, name, purpose, builtin, action, reason, selectedByDefault, role, current, changes, team, skills, notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose) ?? "worker"
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        action = try container.decode(String.self, forKey: .action)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        selectedByDefault = try container.decodeIfPresent(Bool.self, forKey: .selectedByDefault) ?? false
        // Shown for review only; a role this version can't read still imports as planned.
        role = (try? container.decodeIfPresent(AgentRole.self, forKey: .role)) ?? nil
        current = (try? container.decodeIfPresent(AgentRole.self, forKey: .current)) ?? nil
        changes = try container.decodeIfPresent([String].self, forKey: .changes) ?? []
        team = try container.decodeIfPresent(AgentRolesImportPlan.Team.self, forKey: .team)
        skills = try container.decodeIfPresent([AgentRolesImportPlan.RoleSkill].self, forKey: .skills) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

extension AgentRolesImportPlan.SkillFile {
    private enum CodingKeys: String, CodingKey { case path, bytes, executable }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        bytes = try container.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        executable = try container.decodeIfPresent(Bool.self, forKey: .executable) ?? false
    }
}

extension AgentRolesImportPlan.Skill {
    private enum CodingKeys: String, CodingKey {
        case id, sourceId, name, description, outcome, files, bytes, executableFiles, skillText, usedBy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        files = try container.decodeIfPresent([AgentRolesImportPlan.SkillFile].self, forKey: .files) ?? []
        bytes = try container.decodeIfPresent(Int.self, forKey: .bytes) ?? files.reduce(0) { $0 + $1.bytes }
        executableFiles = try container.decodeIfPresent(Int.self, forKey: .executableFiles) ?? files.count(where: \.executable)
        skillText = try container.decodeIfPresent(String.self, forKey: .skillText) ?? ""
        usedBy = try container.decodeIfPresent([String].self, forKey: .usedBy) ?? []
    }
}
