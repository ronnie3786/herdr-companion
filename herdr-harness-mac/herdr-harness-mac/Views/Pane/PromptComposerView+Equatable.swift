import SwiftUI

extension PromptComposerView: Equatable {
    static func == (lhs: PromptComposerView, rhs: PromptComposerView) -> Bool {
        lhs.model === rhs.model
            && optionalPanesEqual(lhs.pane, rhs.pane)
            && optionalWorkspacesEqual(lhs.workspace, rhs.workspace)
            && lhs.destination == rhs.destination
            && lhs.draft == rhs.draft
            && lhs.attachments == rhs.attachments
            && lhs.quotes == rhs.quotes
            && lhs.focusRequest == rhs.focusRequest
            && lhs.dismissFocusRequest == rhs.dismissFocusRequest
            && lhs.piConfiguration == rhs.piConfiguration
            && lhs.responseAudioPlayer === rhs.responseAudioPlayer
            && lhs.toolRowFit == rhs.toolRowFit
            && lhs.modelFavorites === rhs.modelFavorites
            && lhs.codePasteboard === rhs.codePasteboard
    }

    private static func optionalPanesEqual(_ lhs: HerdrPane?, _ rhs: HerdrPane?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): lhs.isEqualIgnoringRevision(to: rhs)
        case (nil, nil): true
        default: false
        }
    }

    private static func optionalWorkspacesEqual(_ lhs: HerdrWorkspace?, _ rhs: HerdrWorkspace?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): lhs.isEqualIgnoringPaneRevisions(to: rhs)
        case (nil, nil): true
        default: false
        }
    }
}
