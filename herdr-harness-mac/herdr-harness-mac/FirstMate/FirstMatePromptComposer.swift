import SwiftUI

/// The shared prompt composer bound to one First Mate conversation: a
/// feature's or the lead First Mate's.
///
/// It is the same `PromptComposerView` a Pi chat or terminal pane uses
/// (attachments, paste, code paste, quotes, and voice), with First Mate's
/// context line on top and its model pill in the tool row. The main window,
/// the chat window, and the First Mate HUD all use it, so every First Mate
/// chat has the same prompt input.
struct FirstMatePromptComposer: View {
    @Bindable var store: FirstMateStore
    @Bindable var model: HerdrAppModel
    let snapshot: FirstMateSnapshot
    let canControl: Bool
    let modelFavorites: ModelFavoritesStore
    /// Overrides the destination's placeholder.
    var placeholder: String? = nil
    /// Increment to focus the input.
    var focusRequest = 0
    /// Focuses the input once it appears (a composer that loads after its
    /// card opened, as in the HUD).
    var focusOnAppear = false
    /// An optional external source guard for a store retained after a
    /// connection changes. Presentation dismissal alone does not invalidate it.
    var validateOwner: (@MainActor () -> Bool)? = nil
    /// Runs after the companion accepts a message (the chat window refreshes
    /// the other window and the fleet).
    var didSubmit: (@MainActor () -> Void)? = nil

    @State private var appearFocus = 0

    var body: some View {
        productionView
            .equatable()
            // The editor already caps its visible lines and scrolls longer
            // drafts. Keep the surrounding controls at their intrinsic height
            // instead of repeatedly negotiating compressed/expanded toolbar
            // layouts with the transcript's flexible vertical stack.
            .fixedSize(horizontal: false, vertical: true)
            .id(destination.id)
            .task(id: destination.id) {
                if focusOnAppear { appearFocus &+= 1 }
            }
    }

    /// The exact view and bindings used by the mounted composer. Tests can
    /// drive its submit path while a deferred transport remains suspended.
    var productionView: PromptComposerView {
        PromptComposerView(
            model: model,
            destination: destination,
            draft: draftBinding,
            attachments: attachmentBinding,
            quotes: quoteBinding,
            containsDictation: dictationBinding,
            focusRequest: focusRequest &+ appearFocus,
            modelFavorites: modelFavorites,
            contextAccessory: contextAccessory,
            toolbarAccessory: modelAccessory
        )
    }

    private var destination: PromptComposerDestination {
        .firstMate(store: store, model: model, snapshot: snapshot, canControl: canControl,
                   placeholder: placeholder, validateOwner: validateOwner, didSubmit: didSubmit)
    }

    private struct ContextKey: Equatable {
        let presentation: FirstMateCoordinatorContextPresentation
        let attachmentsSupported: Bool
    }

    private struct ModelKey: Equatable {
        let feature: FirstMateFeature
        let context: FirstMateStore.OperationContext
        let canControl: Bool
        let hasQueuedWork: Bool
    }

    private var contextAccessory: ComposerAccessory {
        let feature = snapshot.feature
        let capability = store.contextSupported
        let attachmentsSupported = store.attachmentsSupported
        let key = ContextKey(
            presentation: .init(feature: feature, capabilityAvailable: capability),
            attachmentsSupported: attachmentsSupported
        )
        return ComposerAccessory(key: ComposerAccessoryKey(value: key)) {
            VStack(alignment: .leading, spacing: 4) {
                FirstMateCoordinatorContextView(feature: feature, capabilityAvailable: capability)
                if !attachmentsSupported {
                    Label("Update this machine's companion server to attach files.", systemImage: "arrow.down.circle")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
        }
    }

    private var modelAccessory: ComposerAccessory {
        let key = ModelKey(
            feature: featureWithCurrentSessionSelection,
            context: store.operationContext,
            canControl: canControl,
            hasQueuedWork: snapshot.hasQueuedWork == true || snapshot.messages.contains { $0.status == "queued" }
        )
        return ComposerAccessory(key: ComposerAccessoryKey(value: key)) { [store, modelFavorites] in
            FirstMateComposerModelControls(
                store: store,
                feature: key.feature,
                context: key.context,
                canControl: key.canControl,
                hasQueuedWork: key.hasQueuedWork,
                modelFavorites: modelFavorites
            )
        }
    }

    /// The feature with its current coordinator session's model selection,
    /// so the pill names what the running session uses.
    private var featureWithCurrentSessionSelection: FirstMateFeature {
        var feature = snapshot.feature
        if let nativeSessionID = feature.nativeSessionID,
           let session = snapshot.coordinatorSessions.last(where: { $0.nativeSessionID == nativeSessionID }),
           let selection = session.modelSelection {
            feature.modelSelection = selection
        }
        return feature
    }

    private var draftBinding: Binding<String> {
        let context = store.operationContext
        return Binding(
            get: { store.composerDraft(for: context) },
            set: {
                guard store.isDestinationAlive(context) else { return }
                store.setComposerDraft($0, for: context)
                store.composerDrafts.noteDraftEdit(for: snapshot.feature.id)
            }
        )
    }

    private var attachmentBinding: Binding<[TerminalAttachment]> {
        let featureID = snapshot.feature.id
        return Binding(
            get: { store.composerDrafts.attachments(for: featureID) },
            set: { store.composerDrafts.setAttachments($0, for: featureID) }
        )
    }

    private var quoteBinding: Binding<[ChatQuote]> {
        let featureID = snapshot.feature.id
        return Binding(
            get: { store.composerDrafts.quotes(for: featureID) },
            set: { store.composerDrafts.setQuotes($0, for: featureID) }
        )
    }

    private var dictationBinding: Binding<Bool> {
        let featureID = snapshot.feature.id
        return Binding(
            get: { store.composerDrafts.containsDictation(for: featureID) },
            set: { store.composerDrafts.setContainsDictation($0, for: featureID) }
        )
    }
}
