import SwiftUI

struct FirstMateResourceSheet: View {
    @Bindable var store: FirstMateStore
    let resource: FirstMateResource
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                    Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
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
                            FirstMateSessionTranscriptView(messages: store.sessionMessages, fallbackText: store.resourceText)
                        }
                        Label(store.isDemo ? "Synthetic demo recording" : "Saved history. Your First Mate conversation stays in the feature.", systemImage: "clock.arrow.circlepath")
                            .herdrFont(.footnote)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .padding(.top, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .herdrEdgeFade(.top)
            .herdrSheetSurface()
            .foregroundStyle(HerdrTheme.primaryText, HerdrTheme.secondaryText, HerdrTheme.tertiaryText)
            .navigationTitle(resource.nativeSessionID == nil ? "Document" : "Saved session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HerdrSheetCloseButton(action: store.closeResource)
                        .accessibilityIdentifier("first-mate-resource-close")
                }
            }
        }
        .herdrAppChrome(separateSurface: true)
        .presentationDragIndicator(.visible)
    }

    private func retry() {
        Task { await store.open(resource) }
    }
}
