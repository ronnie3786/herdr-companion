import SwiftUI

/// Reuses the feature archive action from conversations and saved sessions.
struct FirstMateArchiveContextMenu: ViewModifier {
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    let canControl: Bool
    @State private var archiveCandidate: FirstMateFeature?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Archive feature…", systemImage: "archivebox") { archiveCandidate = feature }
                    .disabled(!canControl || !store.archiveSupported || store.isSending || feature.isArchived)
            }
            .sheet(item: $archiveCandidate) { feature in
                FirstMateArchiveSheet(store: store, feature: feature)
            }
    }
}

struct FirstMateArchiveSheet: View {
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    @State private var lifecycle: FirstMateStore.LifecycleIdentity?

    var body: some View {
        FirstMateArchiveConfirmation(feature: feature,
                                     canArchive: store.archiveSupported && !store.isSending && lifecycle == store.lifecycle) { reason in
            guard lifecycle == store.lifecycle else { return "The connection changed. Reopen Archive on this feature." }
            return await store.setArchived(featureID: feature.id, archived: true, reason: reason)
                ? nil : store.error ?? "Could not archive this feature. Try again."
        }
        .onAppear { lifecycle = store.lifecycle }
    }
}

struct FirstMateArchiveConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let feature: FirstMateFeature
    var canArchive = true
    let archive: (FirstMateArchiveReason?) async -> String?
    @State private var reason: FirstMateArchiveReason?
    @State private var isArchiving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Archive \(feature.title)?").herdrFont(size: 15, weight: .semibold)
            Text("This feature will leave your active list. Its conversation and session history are kept, and any running work continues. To restore it, select its machine and turn on Show archived.")
                .herdrFont(size: HerdrTheme.TextSize.body)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Optional reason", selection: $reason) {
                Text("No reason").tag(nil as FirstMateArchiveReason?)
                ForEach(FirstMateArchiveReason.allCases) { value in
                    Text(value.title).tag(value as FirstMateArchiveReason?)
                }
            }
            if let error {
                Text(error).foregroundStyle(HerdrTheme.warning).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(isArchiving)
                Button("Archive", systemImage: "archivebox") {
                    isArchiving = true
                    Task {
                        error = await archive(reason)
                        isArchiving = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(!canArchive || isArchiving)
                .accessibilityIdentifier("first-mate-confirm-archive")
            }
        }
        .interactiveDismissDisabled(isArchiving)
        .controlSize(.large)
        .padding(20)
        .frame(width: 480)
    }
}

struct FirstMateSessionArchiveMenu: ViewModifier {
    @Bindable var store: FirstMateStore
    let session: FirstMateSession

    @ViewBuilder
    func body(content: Content) -> some View {
        if let feature = store.features.first(where: { $0.id == session.featureID }) {
            content.modifier(FirstMateArchiveContextMenu(store: store, feature: feature,
                                                       canControl: store.controlAvailable || store.isDemo))
        } else {
            content
        }
    }
}
