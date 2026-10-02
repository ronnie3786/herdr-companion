import SwiftUI

/// Owned by a live composer. Read-only transcripts never install a context.
@MainActor
struct SkimReplyContext {
    let messageID: String
    var disabledReason: String?
    let send: (String) async -> Bool
}

extension EnvironmentValues {
    @Entry var skimReplyContext: SkimReplyContext? = nil
}
