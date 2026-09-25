import Foundation

/// Routes HUD submissions. Only image attachments require a vision-capable model,
/// and `hasImageAttachments` means at least one attachment is an image.
enum HerdrHudModelRouting {
    /// Retained as the built-in fallback. Settings can now override it via
    /// `AgentModelSettings.visionModel`; this value is what ships in the app.
    static let visionModel = AgentModelSettings.builtInVisionModel
    static let thinkingLevel = AgentModelSettings.builtInThinkingLevel.rawValue

    static func model(
        selection: String?,
        selectionSupportsImages: Bool,
        hasImageAttachments: Bool,
        visionModel: String = Self.visionModel
    ) -> String? {
        if let selection {
            if !hasImageAttachments { return selection }
            return selectionSupportsImages ? selection : visionModel
        }
        return hasImageAttachments ? visionModel : nil
    }

    /// Parses a `provider/model` identifier back into the exact identity a
    /// picker selection represents. An incomplete pair is rejected rather
    /// than becoming a half-specified override.
    static func identity(fullID: String) -> PiModelIdentity? {
        let trimmed = fullID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<separator])
        let id = String(trimmed[trimmed.index(after: separator)...])
        guard !provider.isEmpty, !id.isEmpty else { return nil }
        return PiModelIdentity(provider: provider, id: id, name: nil)
    }
}

/// A new chat's model cannot accept the attached images. The composer keeps
/// the selection and asks for an explicit compatible one instead of silently
/// substituting the global vision model.
enum HerdrHudFreshChatError: LocalizedError, Equatable, Sendable {
    case incompatibleImageModel(PiModelIdentity)

    var errorDescription: String? {
        switch self {
        case let .incompatibleImageModel(identity):
            "\(identity.displayName) can't read images. Choose a model that supports images for this chat, then send again."
        }
    }
}
