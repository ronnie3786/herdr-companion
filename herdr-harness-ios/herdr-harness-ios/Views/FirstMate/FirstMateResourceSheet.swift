import SwiftUI

struct FirstMateResourceSheet: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    FirstMateResourceHeader(store: store, resource: resource)
                    if resource.nativeSessionID != nil {
                        if let selection = store.resourceModelSelection ?? resource.modelSelection(in: store.snapshot) {
                            FirstMateModelSelectionSummaryView(selection: selection)
                        }
                        FirstMateUsageSummaryView(
                            usage: store.resourceUsage ?? resource.usage(in: store.snapshot),
                            title: "Whole-session usage"
                        )
                    }
                    Divider()
                    if store.resourceLoading {
                        ProgressView("Loading saved resource…")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else if let error = store.resourceError {
                        ContentUnavailableView {
                            Label("Resource unavailable", systemImage: "exclamationmark.circle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again", action: retry)
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                        }
                    } else {
                        if resource.nativeSessionID != nil {
                            FirstMateSessionPaginationView(store: store)
                        }
                        switch resource {
                        case .document:
                            FirstMateDocumentContentView(source: store.resourceText)
                        case .session, .history:
                            Text(store.resourceText)
                                .font(.body)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Label(store.isDemo ? "Synthetic demo recording" : "Saved history. Your First Mate conversation stays in the feature.", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(FirstMatePalette(scheme: scheme).background)
            .foregroundStyle(FirstMatePalette(scheme: scheme).text)
            .navigationTitle(resource.nativeSessionID == nil ? "Document" : "Saved session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(scheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: store.closeResource)
                        .buttonStyle(.plain)
                        .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("first-mate-resource-close")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .tint(FirstMatePalette(scheme: scheme).accent)
        .presentationDragIndicator(.visible)
    }

    private func retry() {
        Task { await store.open(resource) }
    }
}
