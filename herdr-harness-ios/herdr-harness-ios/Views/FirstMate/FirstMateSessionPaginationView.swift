import SwiftUI

struct FirstMateSessionPaginationView: View {
    @Bindable var store: FirstMateStore

    var body: some View {
        if let total = store.sessionTotalMessages {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(store.sessionLoadedMessages) of \(total) saved \(total == 1 ? "message" : "messages")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if store.sessionNextBefore != nil {
                    Button(action: loadEarlier) {
                        HStack(spacing: 8) {
                            if store.isLoadingEarlier { ProgressView() }
                            Text(store.isLoadingEarlier ? "Loading earlier…" : "Load earlier messages")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoadingEarlier)
                    .accessibilityIdentifier("first-mate-load-earlier")
                }
                if let error = store.sessionPageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadEarlier() {
        Task { await store.loadEarlierSessionMessages() }
    }
}
