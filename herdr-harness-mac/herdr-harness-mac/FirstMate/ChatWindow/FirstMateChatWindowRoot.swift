import SwiftUI

/// The First Mate chat window: conversation list, chat, and inspector.
struct FirstMateChatWindowRoot: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    let modelFavorites: ModelFavoritesStore
    @State private var session: FirstMateChatWindowSession

    init(model: HerdrAppModel, shell: HerdrShellState, modelFavorites: ModelFavoritesStore) {
        self.model = model
        self.shell = shell
        self.modelFavorites = modelFavorites
        _session = State(initialValue: FirstMateChatWindowSession(model: model, shell: shell))
    }

    var body: some View {
        FirstMateChatConversationView(session: session, model: model, modelFavorites: modelFavorites)
            .task { await session.run() }
    }
}
