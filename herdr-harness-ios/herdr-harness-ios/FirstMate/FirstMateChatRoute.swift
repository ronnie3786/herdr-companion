import Foundation

/// Machine-qualified navigation ready for the conversation screens. The old
/// detail adapter consumes the same targets during the Phase 1 transition.
enum FirstMateChatRoute: Hashable {
    case lead
    case chat(FirstMateFeatureTarget)
    case info(FirstMateFeatureTarget, assignmentID: String?)
}
