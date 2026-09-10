import SwiftUI

/// Server-backed history, deliberately outside the terminal workspace sidebar.
struct HerdrHudHistoryView: View {
    let model: HerdrAppModel
    let session: HerdrHudSession
    let machineID: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chats: [HudChatSummary] = []
    @State private var nextOffset: Int?
    @State private var isLoading = false
    @State private var loadID = UUID()
    @State private var isOpening = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HUD chat history").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            }
            Text("Saved indefinitely on this machine. Chats stay outside terminal workspaces until you choose Continue in agent.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search prompts and replies", text: $query)
                .textFieldStyle(.roundedBorder)
                .disabled(isOpening)
                .accessibilityIdentifier("hud-history-search")
            if let error {
                Text(error).font(.caption).foregroundStyle(HerdrTheme.alert).textSelection(.enabled)
                Button("Retry") { Task { await load() } }.disabled(isLoading || isOpening)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chats) { chat in
                        Button { Task { await open(chat) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(chat.turnCount) replies · \(chat.status.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(HerdrTheme.elevated, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpening || session.isRunning)
                        .contextMenu {
                            if let id = chat.sessionId {
                                Button("Copy Pi session ID", systemImage: "doc.on.doc") { model.copyToPasteboard(id) }
                            }
                        }
                    }
                    if chats.isEmpty && !isLoading && error == nil {
                        Text(query.isEmpty ? "No saved HUD chats yet." : "No matching chats.")
                            .foregroundStyle(.secondary).padding()
                    }
                    if let nextOffset {
                        Button("Load more") { Task { await load(offset: nextOffset) } }
                            .disabled(isLoading || isOpening)
                    }
                }
            }
            if isLoading || isOpening { ProgressView().controlSize(.small) }
        }
        .padding(16)
        .frame(width: 420, height: 460)
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await load()
        }
    }

    private func load(offset: Int = 0) async {
        guard !isOpening, offset == 0 || !isLoading else { return }
        let requestedQuery = query
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        error = nil
        if offset == 0 { chats = []; nextOffset = nil }
        defer { if loadID == requestID { isLoading = false } }
        do {
            try await model.requireDurableHUD(machineID: machineID)
            if offset == 0 { try await session.saveHistory(model: model) }
            if model.isDemoMode { return }
            let page = try await model.hudChatClient(machineID: machineID).hudChats(query: requestedQuery, offset: offset)
            try Task.checkCancellation()
            guard query == requestedQuery, loadID == requestID else { return }
            chats = offset == 0 ? page.chats : chats + page.chats
            nextOffset = page.nextOffset
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, loadID == requestID else { return }
            self.error = error.localizedDescription
        }
    }

    private func open(_ chat: HudChatSummary) async {
        isOpening = true
        defer { isOpening = false }
        do {
            try await session.openHistory(chat, machineID: machineID, model: model)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
