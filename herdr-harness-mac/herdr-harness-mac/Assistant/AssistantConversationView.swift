import SwiftUI

struct AssistantConversationView: View {
    @Bindable var session: AssistantSession
    @State private var showsHandoff = false
    @State private var addedContext = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ask Herdr", systemImage: "sparkles").herdrFont(.headline, weight: .semibold)
                Spacer()
                Button("New question", systemImage: "square.and.pencil", action: session.newQuestion)
                    .disabled(session.isRunning || session.pending != nil || session.latest?.status.isTerminal == false)
            }
            Text(session.title).herdrFont(.subheadline).foregroundStyle(HerdrTheme.mist)
            DisclosureGroup("Context · \(session.context.items.count) items") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.context.items) { item in
                            HStack {
                                Text(item.label).herdrFont(.caption, weight: .semibold)
                                Spacer()
                                Button("Remove", systemImage: "xmark", action: { session.removeContext(item.id) })
                                    .labelStyle(.iconOnly).disabled(!session.canSend)
                            }
                            Text(item.text).herdrFont(.caption, monospaced: true).textSelection(.enabled)
                        }
                    }
                }.frame(maxHeight: 150)
                if !session.turns.isEmpty {
                    Text("Earlier messages retain their original context. Start a new question for a clean conversation.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                }
            }
            DisclosureGroup("Add or refresh context") {
                TextField("Paste additional context…", text: $addedContext, axis: .vertical).lineLimit(2...4)
                HStack {
                    Button("Add context") { session.addContext(addedContext); addedContext = "" }
                        .disabled(!session.canSend || addedContext.isEmpty)
                    Button("Use latest source snapshot", action: session.refreshContext).disabled(!session.canSend)
                }
                Text("Reopen Ask from its source to capture a fresh snapshot.").herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
            }
            Text("Answers use the supplied context. Actions continue in an agent.")
                .herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.turns) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.prompt)
                                .herdrFont(.body, weight: .medium)
                                .foregroundStyle(HerdrTheme.text)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                            if let response = turn.response {
                                PiMarkdownMessageView(source: response, isStreaming: !turn.status.isTerminal, id: turn.id)
                            }
                            if let error = turn.error { Text(error).foregroundStyle(HerdrTheme.alert).textSelection(.enabled) }
                            Text(turn.status.label).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: HerdrTheme.readingWidth, alignment: .leading)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if let error = session.error {
                Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.alert).textSelection(.enabled)
            }
            if !session.isReady {
                Button("Retry connection") { Task { await session.prepare() } }
            }
            if session.pending != nil && !session.isRunning {
                Button("Reconcile submission", action: session.retrySubmission)
            }
            if !session.isRunning, session.latest?.status.isTerminal == false {
                Button("Reconnect", action: session.reconnect)
            }
            TextField("Ask about this context…", text: $session.draft, axis: .vertical)
                .disabled(!session.isReady)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .herdrFont(.body)
                .padding(12)
                .background(HerdrTheme.input, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(composerFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
                }
                .focused($composerFocused)
                .onSubmit(session.submit)
                .onChange(of: session.draft) { session.saveDraft() }
            HStack {
                Picker("Model", selection: $session.selectedModel) {
                    Text("Machine default").tag("")
                    ForEach(session.models) { model in Text(model.id).tag(model.id) }
                }.frame(maxWidth: 270).disabled(!session.canSend)
                Spacer()
                if session.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: session.stop)
                } else {
                    Button("Ask", action: session.submit)
                        .disabled(!session.canSend || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            if session.latest?.status == .completed {
                Button("Continue in agent…") { showsHandoff = true }
                    .disabled(session.isRunning || session.isPromoting)
            } else if session.latest?.status == .promoted {
                Button("Open agent", action: session.openAgent)
            }
        }
        .herdrFont(.body)
        .foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.accent)
        .padding(HerdrTheme.pagePadding)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 440, idealHeight: 650)
        .background(HerdrTheme.graphite)
        .preferredColorScheme(.dark)
        .task { await session.prepare(); composerFocused = true }
        .confirmationDialog("Continue in an agent on the original machine?", isPresented: $showsHandoff) {
            Button("Open agent with this conversation", action: session.promote)
        } message: {
            Text("The agent will retain these questions and their context. Enter your action request in the agent after it opens.")
        }
    }
}
