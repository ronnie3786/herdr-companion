import Foundation

/// A role is private to the companion on which its sessions run.
struct AgentRole: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let builtin: Bool
    let locked: Bool
    var name: String
    var whenToUse: String
    var systemPrompt: String
    var modelProfile: String
    var allowDelegation: Bool
    /// nil preserves Pi discovery. An empty array explicitly allows no skills.
    var skillIds: [String]?
    var purpose: String
    var reviewPrompt: String
    var group: String
    var avatar: String

    var isPRReview: Bool { purpose == "pr_review" }

    /// Shown as a placeholder only. A blank saved prompt uses this on the companion.
    static let defaultReviewPrompt = """
        Perform an adversarial code review of this pull request. Focus on actionable correctness, regression, and missing-test issues. Verify each finding against the code and explain its impact.

        Pull request: {url}
        """

    init(id: String, builtin: Bool, locked: Bool, name: String, whenToUse: String,
         systemPrompt: String, modelProfile: String, allowDelegation: Bool, skillIds: [String]?,
         purpose: String = "worker", reviewPrompt: String = "", group: String = "", avatar: String = "review") {
        self.id = id
        self.builtin = builtin
        self.locked = locked
        self.name = name
        self.whenToUse = whenToUse
        self.systemPrompt = systemPrompt
        self.modelProfile = modelProfile
        self.allowDelegation = allowDelegation
        self.skillIds = skillIds
        self.purpose = purpose
        self.reviewPrompt = reviewPrompt
        self.group = group
        self.avatar = avatar
    }

    private enum CodingKeys: String, CodingKey {
        case id, builtin, locked, name, whenToUse, systemPrompt, modelProfile, allowDelegation, skillIds
        case purpose, reviewPrompt, group, avatar
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        builtin = try container.decode(Bool.self, forKey: .builtin)
        locked = try container.decode(Bool.self, forKey: .locked)
        name = try container.decode(String.self, forKey: .name)
        whenToUse = try container.decode(String.self, forKey: .whenToUse)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        modelProfile = try container.decode(String.self, forKey: .modelProfile)
        allowDelegation = try container.decode(Bool.self, forKey: .allowDelegation)
        skillIds = try container.decodeIfPresent([String].self, forKey: .skillIds)
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose) ?? "worker"
        reviewPrompt = try container.decodeIfPresent(String.self, forKey: .reviewPrompt) ?? ""
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar) ?? "review"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(builtin, forKey: .builtin)
        try container.encode(locked, forKey: .locked)
        try container.encode(name, forKey: .name)
        try container.encode(whenToUse, forKey: .whenToUse)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(modelProfile, forKey: .modelProfile)
        try container.encode(allowDelegation, forKey: .allowDelegation)
        // Keep the migration state explicit when saving unrelated profile edits.
        try container.encode(skillIds, forKey: .skillIds)
        // Legacy companions reject unknown role fields. Ordinary worker edits retain
        // their original wire shape; PR profiles always carry their purpose and fields.
        if purpose != "worker" || !reviewPrompt.isEmpty || !group.isEmpty || avatar != "review" {
            try container.encode(purpose, forKey: .purpose)
            try container.encode(reviewPrompt, forKey: .reviewPrompt)
            try container.encode(group, forKey: .group)
            try container.encode(avatar, forKey: .avatar)
        }
    }

    static func custom() -> Self {
        Self(id: UUID().uuidString.lowercased(), builtin: false, locked: false,
             name: "New role", whenToUse: "", systemPrompt: "", modelProfile: "execution",
             allowDelegation: false, skillIds: [])
    }

    static func customPRReview() -> Self {
        Self(id: UUID().uuidString.lowercased(), builtin: false, locked: false,
             name: "New review agent", whenToUse: "", systemPrompt: "", modelProfile: "default",
             allowDelegation: false, skillIds: [], purpose: "pr_review")
    }
}
