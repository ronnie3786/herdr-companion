import Foundation

/// The HUD status the fleet summary reports for a feature
/// (`first-mate-fleet-v1`). It separates "your turn" from "ready for review",
/// which the raw feature status cannot.
enum FirstMateHudStatus: String, Codable, Sendable, CaseIterable {
    case blocked, turn, ready, working, idle, done, unknown

    /// A status a newer companion invents reads as unknown, never as an error.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = FirstMateHudStatus(rawValue: value) ?? .unknown
    }

    /// Blocked, your turn, and ready for review wait on a person.
    var needsYou: Bool {
        switch self {
        case .blocked, .turn, .ready: true
        case .working, .idle, .done, .unknown: false
        }
    }

    /// The client-side mapping for companions without `first-mate-fleet-v1`.
    ///
    /// It never produces `.ready` and ignores `awaiting_turn`, so the features
    /// that need you are exactly the ones `FirstMateAttention` counts.
    static func fallback(featureStatus: String) -> FirstMateHudStatus {
        switch featureStatus {
        case "blocked": .blocked
        case "awaiting_direction": .turn
        case "running", "coordinating", "recovering", "unverified": .working
        case "ready", "paused": .idle
        case "completed": .done
        default: .idle
        }
    }
}

/// The newest conversation message of a fleet entry, cut to a preview.
struct FirstMateFleetLatestMessage: Codable, Equatable, Sendable {
    var id: String
    var role: String
    var text: String
    var createdAt: String?
    /// A plain sentence from the message's ready skim, when it has one.
    var skimSay: String?

    enum CodingKeys: String, CodingKey {
        case id, role, text
        case createdAt = "created_at", skimSay = "skim_say"
    }

    init(id: String, role: String, text: String, createdAt: String? = nil, skimSay: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.skimSay = skimSay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        skimSay = try? c.decodeIfPresent(String.self, forKey: .skimSay)
    }

    var isFromUser: Bool { role == "user" || role == "human" }
}

/// One feature's row in `GET /api/v1/first-mate/fleet`.
///
/// Decoding is tolerant: only `feature_id` is required. A missing label falls
/// back to the title, a missing emoji to ``FirstMateDefaultEmoji``, and a
/// missing `hud_status` to ``FirstMateHudStatus/fallback(featureStatus:)``.
struct FirstMateFleetEntry: Codable, Equatable, Sendable, Identifiable {
    var featureID: String
    var title: String
    var label: String
    var emoji: String
    var emojiSource: String?
    var status: String
    var hudStatus: FirstMateHudStatus
    var stepIndex: Int?
    var stepFraction: Double?
    var percent: Int?
    var now: String?
    var latestMessage: FirstMateFleetLatestMessage?
    var latestFirstMateMessageID: String?
    var readThroughMessageID: String?
    var unread: Bool
    var workingOnReply: Bool
    var activityAt: String?
    var updatedAt: String?
    var archivedAt: String?

    var id: String { featureID }

    enum CodingKeys: String, CodingKey {
        case title, label, emoji, status, percent, now, unread
        case featureID = "feature_id", emojiSource = "emoji_source", hudStatus = "hud_status"
        case stepIndex = "step_index", stepFraction = "step_fraction"
        case latestMessage = "latest_message", latestFirstMateMessageID = "latest_first_mate_message_id"
        case readThroughMessageID = "read_through_message_id", workingOnReply = "working_on_reply"
        case activityAt = "activity_at", updatedAt = "updated_at", archivedAt = "archived_at"
    }

    init(featureID: String, title: String, label: String? = nil, emoji: String? = nil, emojiSource: String? = nil,
         status: String, hudStatus: FirstMateHudStatus? = nil, stepIndex: Int? = nil, stepFraction: Double? = nil,
         percent: Int? = nil, now: String? = nil, latestMessage: FirstMateFleetLatestMessage? = nil,
         latestFirstMateMessageID: String? = nil, readThroughMessageID: String? = nil, unread: Bool = false,
         workingOnReply: Bool = false, activityAt: String? = nil, updatedAt: String? = nil, archivedAt: String? = nil) {
        self.featureID = featureID
        self.title = title
        self.label = label ?? Self.defaultLabel(title: title)
        self.emoji = emoji ?? FirstMateDefaultEmoji.emoji(for: featureID)
        self.emojiSource = emojiSource
        self.status = status
        self.hudStatus = hudStatus ?? .fallback(featureStatus: status)
        self.stepIndex = Self.validStep(stepIndex)
        self.stepFraction = stepFraction
        self.percent = percent
        self.now = now
        self.latestMessage = latestMessage
        self.latestFirstMateMessageID = latestFirstMateMessageID
        self.readThroughMessageID = readThroughMessageID
        self.unread = unread
        self.workingOnReply = workingOnReply
        self.activityAt = activityAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        featureID = try c.decode(String.self, forKey: .featureID)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        let label = (try? c.decodeIfPresent(String.self, forKey: .label))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultLabel(title: title)
        let emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.emoji = emoji.flatMap { $0.isEmpty ? nil : $0 } ?? FirstMateDefaultEmoji.emoji(for: featureID)
        emojiSource = try? c.decodeIfPresent(String.self, forKey: .emojiSource)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        hudStatus = (try? c.decodeIfPresent(FirstMateHudStatus.self, forKey: .hudStatus)) ?? .fallback(featureStatus: status)
        stepIndex = Self.validStep(try? c.decodeIfPresent(Int.self, forKey: .stepIndex))
        stepFraction = try? c.decodeIfPresent(Double.self, forKey: .stepFraction)
        percent = try? c.decodeIfPresent(Int.self, forKey: .percent)
        now = try? c.decodeIfPresent(String.self, forKey: .now)
        latestMessage = try? c.decodeIfPresent(FirstMateFleetLatestMessage.self, forKey: .latestMessage)
        latestFirstMateMessageID = try? c.decodeIfPresent(String.self, forKey: .latestFirstMateMessageID)
        readThroughMessageID = try? c.decodeIfPresent(String.self, forKey: .readThroughMessageID)
        unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) ?? false
        workingOnReply = (try? c.decodeIfPresent(Bool.self, forKey: .workingOnReply)) ?? false
        activityAt = try? c.decodeIfPresent(String.self, forKey: .activityAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        archivedAt = try? c.decodeIfPresent(String.self, forKey: .archivedAt)
    }

    var isArchived: Bool { archivedAt != nil }

    /// The companion's default label: the title, trimmed to 24 characters.
    static func defaultLabel(title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
    }

    private static func validStep(_ value: Int?) -> Int? {
        guard let value, FirstMateChatSteps.names.indices.contains(value) else { return nil }
        return value
    }
}

struct FirstMateFleetResponse: Decodable, Sendable {
    var ok: Bool
    var features: [FirstMateFleetEntry]
    var generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case ok, features
        case generatedAt = "generated_at"
    }

    init(ok: Bool = true, features: [FirstMateFleetEntry], generatedAt: String? = nil) {
        self.ok = ok
        self.features = features
        self.generatedAt = generatedAt
    }

    /// One malformed entry drops only that entry.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        features = (try c.decodeIfPresent([LossyEntry].self, forKey: .features) ?? []).compactMap(\.entry)
        generatedAt = try? c.decodeIfPresent(String.self, forKey: .generatedAt)
    }

    private struct LossyEntry: Decodable {
        let entry: FirstMateFleetEntry?
        init(from decoder: Decoder) throws { entry = try? FirstMateFleetEntry(from: decoder) }
    }
}

/// `POST /api/v1/first-mate/features/{id}/read`.
struct FirstMateReadResponse: Decodable, Sendable {
    var featureID: String
    var readThroughMessageID: String?
    var unread: Bool

    enum CodingKeys: String, CodingKey {
        case unread
        case featureID = "feature_id", readThroughMessageID = "read_through_message_id"
    }

    init(featureID: String, readThroughMessageID: String?, unread: Bool) {
        self.featureID = featureID
        self.readThroughMessageID = readThroughMessageID
        self.unread = unread
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        featureID = try c.decode(String.self, forKey: .featureID)
        readThroughMessageID = try c.decodeIfPresent(String.self, forKey: .readThroughMessageID)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }
}

/// `POST /api/v1/first-mate/features/{id}/hud`.
struct FirstMateHudUpdateResponse: Decodable, Sendable {
    var ok: Bool
    var feature: FirstMateFleetEntry
}

/// The client-side emoji for a feature the companion has not given one.
///
/// The companion uses the same palette and hash, so a feature keeps its emoji
/// whether or not the server reports it.
enum FirstMateDefaultEmoji {
    /// Sixteen single scalars with default emoji presentation. The order is
    /// part of the cross-platform contract.
    static let palette = ["🧭", "📦", "🧪", "🔍", "🧾", "📋", "🧩", "🚀", "🔔", "🎨", "📚", "🌱", "💡", "🔧", "🧰", "🪁"]

    static func emoji(for featureID: String) -> String {
        palette[index(for: featureID)]
    }

    /// FNV-1a (32-bit) over the UTF-8 bytes, folded to 16 bits.
    static func index(for featureID: String) -> Int {
        let hash = fnv1a(featureID)
        return Int(((hash >> 16) ^ (hash & 0xffff)) % UInt32(palette.count))
    }

    static func fnv1a(_ value: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }
}

/// The six workflow steps the HUD and chat window show.
enum FirstMateChatSteps {
    static let names = ["Plan", "Build", "Review", "QA", "PR", "Merge"]
    /// The row word while a feature works on that step.
    static let doing = ["Planning", "Building", "In review", "In QA", "PR open", "Merging"]
}
