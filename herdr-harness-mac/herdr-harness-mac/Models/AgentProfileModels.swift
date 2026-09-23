import Foundation

struct AgentProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let revision: Int
    let soul: String
    let user: String
    let updatedAt: String
    let actor: String
    let reason: String
}

struct AgentProfileBinding: Codable, Equatable, Sendable {
    let revision: Int
    let ownerMachineId: String?
    let profileId: String?
    let soul: String
    let user: String
    let updatedAt: String
}

struct AgentProfileEffective: Codable, Equatable, Sendable {
    let profile: AgentProfile?
    let binding: AgentProfileBinding
    let prompt: String
    let syncStatus: String
    let lastSyncedAt: String?
    let error: String?
}

struct AgentProfileProposal: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let profileId: String
    let baseRevision: Int
    let soul: String
    let user: String
    let reason: String
    let actor: String
    let status: String
    let createdAt: String
}

struct AgentProfilesOverview: Codable, Equatable, Sendable {
    let ok: Bool
    let capability: String
    let machineId: String
    let profiles: [AgentProfile]
    let binding: AgentProfileBinding
    let effective: AgentProfileEffective
    let proposals: [AgentProfileProposal]
}

struct AgentProfileHistoryResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let profile: AgentProfile
    let history: [AgentProfile]
}

struct AgentProfileMutationResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let profile: AgentProfile?
    let binding: AgentProfileBinding?
    let effective: AgentProfileEffective?
    let proposal: AgentProfileProposal?
}

enum AgentProfileLimits {
    static let maximumDocumentBytes = 16 * 1_024
    static let maximumNameBytes = 120
    static let maximumReasonBytes = 1_000

    static func nameIsValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maximumNameBytes
    }

    static func documentIsValid(_ document: String) -> Bool {
        document.utf8.count <= maximumDocumentBytes
    }

    static func reasonIsValid(_ reason: String) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maximumReasonBytes
    }
}

/// The two documents every profile carries.
enum AgentProfileDocument: String, CaseIterable, Identifiable, Sendable {
    case soul
    case user

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soul: "Soul"
        case .user: "User"
        }
    }

    var summary: String {
        switch self {
        case .soul: "Personality, tone, and working style."
        case .user: "Who you are, what you work on, and how you like things done."
        }
    }

    var placeholder: String {
        switch self {
        case .soul:
            "- Calm, direct, and a little funny.\n- Lead with the answer; expand when asked.\n- Ask before anything public or irreversible."
        case .user:
            "- Name, role, and time zone.\n- The projects you care about most.\n- How you like updates and reviews delivered."
        }
    }
}

/// A profile identified across machines. Profile IDs are only unique on the
/// server that owns them, so the owner's server machine ID is part of the key.
struct AgentProfileReference: Hashable, Sendable {
    let ownerServerID: String
    let profileID: String
}

/// A readable, line-level comparison for reviewing suggested edits.
enum AgentProfileLineDiff {
    enum Kind: Equatable, Sendable {
        case unchanged
        case added
        case removed
    }

    struct Line: Equatable, Identifiable, Sendable {
        let id: Int
        let kind: Kind
        let text: String
    }

    static func lines(from old: String, to new: String) -> [Line] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            let kind: Kind
            let text: String
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                (kind, text) = (.removed, oldLines[oldIndex])
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                (kind, text) = (.added, newLines[newIndex])
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                (kind, text) = (.unchanged, newLines[newIndex])
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                (kind, text) = (.removed, oldLines[oldIndex])
                oldIndex += 1
            } else {
                (kind, text) = (.added, newLines[newIndex])
                newIndex += 1
            }
            result.append(Line(id: result.count, kind: kind, text: text))
        }
        return result
    }
}

enum AgentProfileDates {
    /// Server timestamps are ISO 8601, with or without fractional seconds.
    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func relative(_ value: String?, now: Date = .now) -> String? {
        guard let date = date(from: value) else { return nil }
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

enum AgentProfileMutation: Encodable, Equatable, Sendable {
    case create(name: String, soul: String, user: String, reason: String, requestId: UUID)
    case update(profileId: String, expectedRevision: Int, name: String, soul: String, user: String, reason: String, requestId: UUID)
    case restore(profileId: String, expectedRevision: Int, sourceRevision: Int, reason: String, requestId: UUID)
    case assign(expectedRevision: Int, ownerMachineId: String?, profileId: String?, soul: String, user: String, requestId: UUID)
    case sync(expectedRevision: Int, requestId: UUID)
    case propose(profileId: String, expectedRevision: Int, soul: String, user: String, reason: String, requestId: UUID)
    case approve(proposalId: String, expectedRevision: Int, reason: String, requestId: UUID)
    case reject(proposalId: String, reason: String, requestId: UUID)

    private enum CodingKeys: String, CodingKey {
        case action, requestId, name, soul, user, reason
        case profileId, expectedRevision, sourceRevision, ownerMachineId, proposalId
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .create(name, soul, user, reason, requestId):
            try container.encode("create", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(name, forKey: .name)
            try container.encode(soul, forKey: .soul)
            try container.encode(user, forKey: .user)
            try container.encode(reason, forKey: .reason)
        case let .update(profileId, expectedRevision, name, soul, user, reason, requestId):
            try container.encode("update", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(profileId, forKey: .profileId)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(name, forKey: .name)
            try container.encode(soul, forKey: .soul)
            try container.encode(user, forKey: .user)
            try container.encode(reason, forKey: .reason)
        case let .restore(profileId, expectedRevision, sourceRevision, reason, requestId):
            try container.encode("restore", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(profileId, forKey: .profileId)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(sourceRevision, forKey: .sourceRevision)
            try container.encode(reason, forKey: .reason)
        case let .assign(expectedRevision, ownerMachineId, profileId, soul, user, requestId):
            try container.encode("assign", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            if let ownerMachineId { try container.encode(ownerMachineId, forKey: .ownerMachineId) }
            else { try container.encodeNil(forKey: .ownerMachineId) }
            if let profileId { try container.encode(profileId, forKey: .profileId) }
            else { try container.encodeNil(forKey: .profileId) }
            try container.encode(soul, forKey: .soul)
            try container.encode(user, forKey: .user)
        case let .sync(expectedRevision, requestId):
            try container.encode("sync", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(expectedRevision, forKey: .expectedRevision)
        case let .propose(profileId, expectedRevision, soul, user, reason, requestId):
            try container.encode("propose", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(profileId, forKey: .profileId)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(soul, forKey: .soul)
            try container.encode(user, forKey: .user)
            try container.encode(reason, forKey: .reason)
        case let .approve(proposalId, expectedRevision, reason, requestId):
            try container.encode("approve", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(proposalId, forKey: .proposalId)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(reason, forKey: .reason)
        case let .reject(proposalId, reason, requestId):
            try container.encode("reject", forKey: .action)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(proposalId, forKey: .proposalId)
            try container.encode(reason, forKey: .reason)
        }
    }
}
