import SwiftUI

struct PRReviewDiscussionView: View {
    @Bindable var session: PRReviewDiscussionSession
    @Bindable var store: PRReviewStore
    var canControl: Bool
    var previousCommentCount: Int
    var showPreviousComments: () -> Void
    @State private var confirmingDiscard = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !session.isAvailable {
                Label("Update the review host companion to use shared local discussions and the agent CLI.", systemImage: "arrow.down.circle")
                    .foregroundStyle(HerdrTheme.mist)
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(HerdrTheme.alert)
                    .textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.isLoading && session.threads.isEmpty { ProgressView("Loading comments…") }
                        else if session.visibleThreads.isEmpty {
                            ContentUnavailableView("No \(session.filter == "all" ? "" : session.filter + " ")comments", systemImage: "text.bubble",
                                description: Text("Add a PR comment here or select code in the diff. Human and agent replies are saved on the review host."))
                        }
                        ForEach(session.visibleThreads) { thread in
                            threadCard(thread).id(thread.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { if let id = session.selectedThreadID { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: session.selectedThreadID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
            if session.hasDraft { composer }
            footer
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 760, minHeight: 540, idealHeight: 760)
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
        .interactiveDismissDisabled(session.hasDraft || session.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-discussions")
        .confirmationDialog("Discard this draft?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) { session.discardDraft() }
            Button("Keep writing", role: .cancel) { }
        }
        .onChange(of: session.hasDraft) { _, editing in composerFocused = editing }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review comments").font(.title2.bold())
                    Text("\(session.openCount) open · \(session.threads.count - session.openCount) resolved")
                        .font(.caption).foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
                Button("Add PR comment", systemImage: "plus.bubble") { session.beginComment(store: store) }
                    .disabled(!canControl || !session.isAvailable || session.hasDraft || session.isSaving)
                    .accessibilityIdentifier("pr-review-add-pr-comment")
            }
            Picker("Comment status", selection: $session.filter) {
                Text("Open").tag("open")
                Text("Resolved").tag("resolved")
                Text("All").tag("all")
            }.pickerStyle(.segmented)
                .tint(HerdrTheme.controlAccent)
        }
    }

    private func threadCard(_ thread: PRReviewDiscussion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.anchor?.path ?? "Pull request").font(.headline).textSelection(.enabled)
                    if let anchor = thread.anchor {
                        Text("\(anchor.location) · revision \(anchor.headSHA.prefix(8))")
                            .font(.caption).foregroundStyle(HerdrTheme.mist)
                    }
                }
                Spacer()
                if thread.outdated { badge("Earlier revision", symbol: "clock.arrow.circlepath") }
                badge(thread.isResolved ? "Resolved" : "Open", symbol: thread.isResolved ? "checkmark.circle" : "circle")
            }
            if let code = thread.anchor?.codeExcerpt, !code.isEmpty {
                DisclosureGroup("Original code") {
                    Text(code).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(HerdrTheme.ink, in: .rect(cornerRadius: 6))
                }.font(.caption)
            }
            ForEach(thread.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label(message.authorLabel, systemImage: message.author == "agent" ? "sparkles" : "person.crop.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(dateLabel(message.createdAt)).font(.caption).foregroundStyle(HerdrTheme.mist)
                    }
                    // Keep Markdown source and whitespace lossless, including agent code snippets.
                    Text(message.body).font(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.ink, in: .rect(cornerRadius: 8))
            }
            HStack {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { session.beginReply(to: thread) }
                    .disabled(!canControl || !session.isAvailable || session.hasDraft || session.isSaving)
                    .accessibilityIdentifier("pr-review-thread-reply-\(thread.id)")
                Button(thread.isResolved ? "Reopen" : "Resolve", systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark") {
                    Task { await session.toggleState(thread) }
                }
                .disabled(!canControl || !session.isAvailable || session.isSaving)
                .accessibilityIdentifier("pr-review-thread-state-\(thread.id)")
                if thread.anchor != nil {
                    Button("Show in diff") { Task { await session.showInDiff(thread, store: store) } }
                        .disabled(thread.outdated || session.hasDraft || session.isSaving)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    PRReviewCommentsSession.writeToPasteboard(thread.messages.map { "\($0.authorLabel):\n\($0.body)" }.joined(separator: "\n\n"))
                }
            }.font(.caption)
            DisclosureGroup("Activity (\(thread.history.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(thread.history) { event in
                        Text("\(event.author == "agent" ? "Agent" : "Human") \(event.action) · \(dateLabel(event.createdAt)) · \((event.headSHA ?? "").prefix(8))")
                            .font(.caption).foregroundStyle(HerdrTheme.mist)
                        if let previous = event.previousBody {
                            Text(previous).font(.caption).textSelection(.enabled)
                                .padding(6).background(HerdrTheme.ink, in: .rect(cornerRadius: 4))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.caption)
        }
        .padding(14)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-thread-\(thread.id)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(session.draft?.threadID == nil ? "New comment · Human" : "Reply · Human").font(.headline)
            if let anchor = session.draft?.anchor {
                Text("\(anchor.path) · revision \(anchor.headSHA.prefix(8))").font(.caption).textSelection(.enabled)
                Text(session.draft?.excerpt ?? "").font(.system(.caption, design: .monospaced)).lineLimit(3)
            }
            if session.draft?.scope != session.scope {
                Text("This draft belongs to the previous review or connection. Copy it into a new comment or discard it.")
                    .font(.caption).foregroundStyle(HerdrTheme.alert)
            }
            TextEditor(text: $session.draftBody)
                .font(.body).scrollContentBackground(.hidden)
                .padding(6).frame(minHeight: 90, maxHeight: 160)
                .background(HerdrTheme.ink, in: .rect(cornerRadius: 8))
                .focused($composerFocused).disabled(session.isSaving)
                .accessibilityLabel("Comment text")
                .accessibilityIdentifier("pr-review-discussion-body")
            HStack {
                Text("Markdown is saved exactly as typed.").font(.caption).foregroundStyle(HerdrTheme.mist)
                Spacer()
                Button("Cancel") {
                    if session.draftBody.isEmpty { session.discardDraft() } else { confirmingDiscard = true }
                }.disabled(session.isSaving)
                Button(session.isSaving ? "Saving…" : "Save comment") { Task { await session.save() } }
                    .disabled(!canControl || !session.canSave)
                    .accessibilityIdentifier("pr-review-discussion-save")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved on this review host. Never posted to GitHub.")
                .font(.caption).foregroundStyle(HerdrTheme.mist)
            HStack {
                if previousCommentCount > 0 {
                    Button("Previous Mac comments (\(previousCommentCount))", action: showPreviousComments).font(.caption)
                }
                Spacer()
                Button("Done") { session.isPresented = false }
                    .disabled(session.hasDraft || session.isSaving)
            }
        }
    }

    private func badge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
            .background(HerdrTheme.selection, in: .capsule)
    }

    private func dateLabel(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
