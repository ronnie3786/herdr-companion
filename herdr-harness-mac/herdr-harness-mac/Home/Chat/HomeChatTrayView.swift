import SwiftUI

/// The native tray panel. Its host supplies the reference's 574-point width,
/// 78-percent/700-point height cap, bottom inset, scrim, and entrance motion.
struct HomeChatTrayView: View {
    @Bindable var controller: HomeChatController
    let model: HerdrAppModel
    let modelFavorites: ModelFavoritesStore
    let homeSnapshot: HomeSnapshot
    let openWindow: () -> Void
    let close: () -> Void
    var isActive = true
    var focusRequest = 0
    @State private var suggestionFocusRequest = 0

    private struct RunIdentity: Hashable {
        let generation: Int
        let isActive: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.20)).frame(width: 38, height: 4).padding(.top, 7)
                .accessibilityHidden(true)
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).accessibilityHidden(true)
            ForEach(controller.contexts) { context in
                HomeChatContextCard(context: context) { controller.removeContext(context.id) }
                    .padding(.horizontal, 18).padding(.top, 12)
            }
            conversation
        }
        .background(HomePalette.color(0x1B1A22), in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15), lineWidth: 1).allowsHitTesting(false) }
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 30)
        .environment(\.chatProsePalette, .firstMate(FirstMatePalette(scheme: .dark)))
        .environment(\.openURL, OpenURLAction { url in openMention(url) })
        .task(id: RunIdentity(generation: model.connectionGeneration, isActive: isActive)) {
            guard isActive else { return }
            await controller.run()
        }
        .accessibilityIdentifier("home-chat-tray")
    }

    private var header: some View {
        HStack(spacing: 10) {
            HomeAvatar(mood: isTyping ? .thinking : homeSnapshot.mood, size: 30, animated: isActive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("My First Mate").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomePalette.ink)
                Text(isTyping ? "Thinking…" : "Runs on " + controller.machineName)
                    .font(.system(size: 11.5)).foregroundStyle(HomePalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                if controller.requestTransfer() { openWindow() }
            } label: {
                Label("Open in First Mate", systemImage: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HomePalette.color(0xCFCCFA))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(HomePalette.accentWash, in: .rect(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(HomePalette.accentLine, lineWidth: 1) }
            }
            .buttonStyle(.herdrPlain)
            .help(controller.transferBlockReason ?? "Move this draft to the same lead conversation in First Mate")
            .accessibilityIdentifier("home-chat-popout")
            Button {
                controller.dismiss()
                close()
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomePalette.secondary).frame(width: 30, height: 30)
            }
            .buttonStyle(.herdrPlain)
            .accessibilityLabel("Close Home chat")
        }
        .padding(.leading, 20).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 12)
    }

    @ViewBuilder
    private var conversation: some View {
        if let snapshot = controller.snapshot, let owner = controller.owner {
            VStack(spacing: 0) {
                FirstMateChatTranscript(session: controller.transcriptSession, store: controller.store,
                    snapshot: snapshot, conversationID: owner.conversationID, isTyping: isTyping,
                    openDocuments: {
                        if controller.requestTransfer(inspector: .documents) { openWindow() }
                    }, validateOwner: { controller.owner == owner && controller.isOwnerControllable })
                    .id(owner.conversationID)
                    .disabled(!controller.isOwnerCurrent)
                FirstMateExecutionStateNotice(snapshot: snapshot, health: controller.store.runtimeHealth)
                FirstMateSendErrorView(store: controller.store, featureID: owner.featureID,
                                      validateOwner: { controller.owner == owner && controller.isOwnerControllable })
                    .disabled(!controller.isOwnerCurrent)
                notice
                if !homeSnapshot.suggestions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(homeSnapshot.suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    controller.appendDraft(suggestion)
                                    suggestionFocusRequest &+= 1
                                }
                                    .font(.system(size: 12.5)).foregroundStyle(HomePalette.secondary)
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .background(.white.opacity(0.04), in: .capsule)
                                    .overlay { Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1) }
                                    .buttonStyle(.herdrPlain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, 18).padding(.bottom, 8)
                    .disabled(!controller.canControl)
                }
                FirstMatePromptComposer(store: controller.store, model: model, snapshot: snapshot,
                    canControl: controller.canControl, modelFavorites: modelFavorites,
                    placeholder: "Ask First Mate…", focusRequest: focusRequest &+ suggestionFocusRequest, focusOnAppear: true,
                    validateOwner: { controller.owner == owner && controller.isOwnerControllable }) {
                        controller.transcriptSession.didMutate(machineID: owner.target.machineID)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
        } else {
            VStack(spacing: 14) {
                Spacer(minLength: 12)
                if controller.isOpening { ProgressView().controlSize(.small) }
                Text(controller.availabilityMessage ?? "Opening your lead conversation…")
                    .font(.system(size: 14)).foregroundStyle(HomePalette.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                if !controller.draft.isEmpty {
                    Text(controller.draft).font(.system(size: 13)).foregroundStyle(HomePalette.prose)
                        .textSelection(.enabled).padding(12)
                        .background(.white.opacity(0.04), in: .rect(cornerRadius: 10))
                }
                if !controller.isOpening {
                    Button("Try again") { Task { await controller.prepare() } }
                        .buttonStyle(.herdrPlain).foregroundStyle(HomePalette.accent)
                }
                Spacer(minLength: 12)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let message = controller.availabilityMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(HomePalette.attention)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 8)
        } else if controller.pendingTransfer != nil {
            Text("Opening the same conversation in First Mate…")
                .font(.system(size: 12)).foregroundStyle(HomePalette.secondary).padding(.bottom, 8)
        }
    }

    private var isTyping: Bool {
        guard let snapshot = controller.snapshot else { return false }
        return FirstMateTranscriptLayout.isTyping(
            messages: FirstMateTranscriptLayout.orderedMessages(store: controller.store, snapshot: snapshot),
            isSending: FirstMateTranscriptLayout.isAwaitingReply(store: controller.store, snapshot: snapshot),
            isWorkingOnReply: snapshot.feature.coordinatorOwner != nil)
    }

    private func openMention(_ url: URL) -> OpenURLAction.Result {
        guard let target = FirstMateMention.parse(url) else { return .systemAction }
        guard let owner = controller.owner, controller.isOwnerCurrent else { return .handled }
        // Mentions are companion-local. Never infer a different machine from
        // a matching feature name or a colliding feature ID.
        let id = FirstMateFleetFeatureID(machineID: owner.target.machineID, featureID: target.featureID)
        guard controller.transcriptSession.conversations.contains(where: { $0.id == id }) else { return .handled }
        controller.shell.firstMateChatExactOpenRequest = .init(target: id, model: controller.model)
        openWindow()
        return .handled
    }
}
