import SwiftUI

/// The chat column under the header: the transcript (or My First Mate's
/// briefing) and the composer.
struct FirstMateChatConversationView: View {
    let session: FirstMateChatWindowSession
    let model: HerdrAppModel
    let modelFavorites: ModelFavoritesStore

    init(session: FirstMateChatWindowSession, model: HerdrAppModel, modelFavorites: ModelFavoritesStore) {
        self.session = session
        self.model = model
        self.modelFavorites = modelFavorites
    }

    var body: some View {
        Color.clear
    }
}
