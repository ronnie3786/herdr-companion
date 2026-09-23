import SwiftUI

struct FirstMateResourceSheet: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if resource.nativeSessionID != nil {
                        Label("Agent Session", systemImage: "bubble.left.and.bubble.right")
                            .herdrFont(.caption, weight: .semibold)
                            .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                        Text(resource.title).herdrFont(.title2, weight: .semibold)
                        Label("Read-only saved conversation", systemImage: "lock")
                            .herdrFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(resource.title).herdrFont(.title2, weight: .semibold)
                    }
                    switch resource {
                    case .session(let agent):
                        Text("Saved Pi session · \(agent.role) · generation \(agent.generation)")
                            .herdrFont(.caption).foregroundStyle(.secondary)
                        Text(agent.nativeSessionID ?? "Session pending").herdrFont(.caption2, monospaced: true).textSelection(.enabled)
                        FirstMateSessionHistoryView(store: store, resource: resource)
                    case .history(let session):
                        Text("Saved Pi session · \(session.kindDisplayName) · \(session.role) · generation \(session.generation) · \(session.ownershipStatus)")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if resource.nativeSessionID != nil {
                        DisclosureGroup("Session details") {
                            VStack(alignment: .leading, spacing: 12) {
                                if let selection = store.resourceModelSelection ?? resource.modelSelection(in: store.snapshot) {
                                    FirstMateModelSelectionSummaryView(selection: selection)
                                }
                                FirstMateUsageSummaryView(
                                    usage: store.resourceUsage ?? resource.usage(in: store.snapshot),
                                    title: "Whole-session usage"
                                )
                            }.padding(.top, 10)
                        }
                        .herdrFont(.caption)
                        .accessibilityIdentifier("first-mate-session-details")
                    }
                    if resource.nativeSessionID != nil, let total = store.sessionTotalMessages {
                        Divider()
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
                        }
                        if let error = store.sessionPageError {
                            Text(error).herdrFont(.caption).foregroundStyle(.orange)
                        }
                    }
                    Divider()
                    if store.resourceLoading {
                        ProgressView("Loading saved resource…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if let error = store.resourceError {
                        ContentUnavailableView("Resource unavailable", systemImage: "exclamationmark.circle", description: Text(error))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if rendersMarkdownDocument {
                        FirstMateMarkdownContentView(source: store.resourceText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if resource.nativeSessionID != nil {
                        FirstMateSessionTranscriptView(
                            messages: store.sessionMessages,
                            fallbackText: store.resourceText,
                            sessionID: resource.nativeSessionID ?? ""
                        )
                    } else {
                        Text(store.resourceText)
                            .herdrFont(.body)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .defaultScrollAnchor(resource.nativeSessionID == nil ? .top : .bottom, for: .initialOffset)
            Divider()
            Text(store.isDemo ? "Synthetic recording fixture" : "Read-only saved history. Closing this view does not end the session.")
                .herdrFont(.caption).foregroundStyle(.secondary).padding(16)
        }
        .frame(minWidth: 580, idealWidth: 720, minHeight: 480, idealHeight: 650)
        .background(FirstMatePalette(scheme: scheme).background).foregroundStyle(.primary)
        .accessibilityIdentifier("first-mate-resource-sheet")
    }

    private var rendersMarkdownDocument: Bool {
        guard case .document(let document) = resource else { return false }
        return String(document.mediaType.split(separator: ";", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "text/markdown"
    }
}
