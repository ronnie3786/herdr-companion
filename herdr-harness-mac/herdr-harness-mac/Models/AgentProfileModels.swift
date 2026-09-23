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

struct AgentProfileDraft: Equatable, Sendable {
    var name = ""
    var soul = ""
    var user = ""
    var reason = ""

    init() {}

    init(profile: AgentProfile) {
        name = profile.name
        soul = profile.soul
        user = profile.user
    }

    var documentsAreValid: Bool {
        soul.utf8.count <= AgentProfileLimits.maximumDocumentBytes
            && user.utf8.count <= AgentProfileLimits.maximumDocumentBytes
    }

    var nameIsValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= AgentProfileLimits.maximumNameBytes
    }

    var reasonIsValid: Bool {
        AgentProfileLimits.reasonIsValid(reason)
    }
}

enum AgentProfileLimits {
    static let maximumDocumentBytes = 16 * 1_024
    static let maximumNameBytes = 120
    static let maximumReasonBytes = 1_000

    static func reasonIsValid(_ reason: String) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maximumReasonBytes
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
