import SwiftUI

struct HerdrHudEndChatButton: View {
    let chat: HerdrHudChats.Chat
    let controller: HerdrHudController
    let model: HerdrAppModel
    @State private var confirmsEnd = false
    @State private var showsError = false
    @State private var errorMessage = ""

    var body: some View {
        Button(role: .destructive) { confirmsEnd = true } label: {
            Label(chat.session.isEnding ? "Ending…" : "End Chat", systemImage: "xmark.circle")
                .herdrFont(.caption, weight: .semibold)
        }
        .buttonStyle(.bordered)
        .tint(HerdrTheme.alert)
        .disabled(chat.session.isEnding || chat.session.isLoadingHistory || !chat.session.promotingExchangeIDs.isEmpty)
        .accessibilityIdentifier("hud-end-chat")
        .help("Stop this HUD task and close its bubble. Saved history is kept.")
        .confirmationDialog("End this HUD chat?", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("End Chat", role: .destructive) {
                Task {
                    do { try await controller.endChat(chat.id, model: model) }
                    catch {
                        errorMessage = error.localizedDescription
                        showsError = true
                    }
                }
            }
            Button("Keep Chat", role: .cancel) { }
        } message: {
            Text("Any running HUD task will be stopped and this bubble closed. Saved conversation history is kept; unsent drafts are discarded. A promoted workspace session is not closed.")
        }
        .alert("Couldn’t end chat", isPresented: $showsError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}
