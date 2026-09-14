import SwiftUI

struct FirstMateResourceSheet: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(resource.title).herdrFont(.title2, weight: .semibold)
                    switch resource {
                    case .session(let agent):
                        Text("Saved Pi session · \(agent.role) · generation \(agent.generation)")
                            .herdrFont(.caption).foregroundStyle(.secondary)
                        Text(agent.nativeSessionID ?? "Session pending").herdrFont(.caption2, monospaced: true).textSelection(.enabled)
                        FirstMateSessionHistoryView(store: store, resource: resource)
                    case .history(let session):
                        Text("Saved Pi session · \(session.role) · generation \(session.generation) · \(session.ownershipStatus)")
                            .herdrFont(.caption).foregroundStyle(.secondary)
                        Text(session.nativeSessionID).herdrFont(.caption, monospaced: true).textSelection(.enabled)
                        FirstMateSessionHistoryView(store: store, resource: resource)
                    case .document(let document):
                        Text(document.mediaType).herdrFont(.caption).foregroundStyle(.secondary)
                        if let author = store.snapshot?.author(of: document), author.nativeSessionID == document.nativeSessionID {
                            Button("Produced by \(author.title)", systemImage: "person.crop.circle") {
                                Task { await store.open(.session(author)) }
                            }.buttonStyle(.plain).herdrFont(.caption).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                            .accessibilityIdentifier("first-mate-document-author")
                        }
                    }
                }
                Spacer()
                Button("Close", systemImage: "xmark", action: store.closeResource)
                    .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("first-mate-resource-close")
            }.padding(24)
            Divider()
            if resource.nativeSessionID != nil, let total = store.sessionTotalMessages {
                HStack {
                    Text("\(store.sessionLoadedMessages) of \(total) saved messages").herdrFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.sessionNextBefore != nil {
                        Button(store.isLoadingEarlier ? "Loading earlier…" : "Load earlier messages") {
                            Task { await store.loadEarlierSessionMessages() }
                        }
                        .disabled(store.isLoadingEarlier)
                        .accessibilityIdentifier("first-mate-load-earlier")
                    }
                }.padding(16)
                if let error = store.sessionPageError {
                    Text(error).herdrFont(.caption).foregroundStyle(.orange).padding(.horizontal, 16)
                }
                Divider()
            }
            if store.resourceLoading {
                ProgressView("Loading saved resource…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.resourceError {
                ContentUnavailableView("Resource unavailable", systemImage: "exclamationmark.circle", description: Text(error))
            } else {
                ScrollView {
                    Text(store.resourceText).herdrFont(.body).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            }
            Divider()
            Text(store.isDemo ? "Synthetic recording fixture" : "Read-only saved history. Closing this view does not end the session.")
                .herdrFont(.caption).foregroundStyle(.secondary).padding(16)
        }
        .frame(minWidth: 580, idealWidth: 720, minHeight: 480, idealHeight: 650)
        .background(FirstMatePalette(scheme: scheme).background).foregroundStyle(.primary)
        .accessibilityIdentifier("first-mate-resource-sheet")
    }
}
