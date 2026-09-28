import SwiftUI

struct PRReviewGuideDock: View {
    @Bindable var session: PRReviewGuideSession
    var preferPrivateTranscription = true
    var compact = false
    @State private var recording = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isInitialPresentation {
                initialControls
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(HerdrTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(HerdrTheme.selection, in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.chapter?.title ?? "Your review buddy")
                            .herdrFont(.subheadline, weight: .semibold).lineLimit(1)
                        Text(session.status).herdrFont(.caption2).foregroundStyle(HerdrTheme.mist).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if session.isBusy { ProgressView().controlSize(.small) }
                    if session.isDetour && session.plan != nil {
                        Button("Back to walkthrough", systemImage: "arrow.uturn.backward") { session.returnToWalkthrough() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pr-review-guide-return")
                    } else if session.plan == nil || session.isStale {
                        Button(session.isStale ? "New walkthrough" : "Start walkthrough") { session.start() }
                            .herdrProminentButton()
                            .disabled(!session.isAvailable || session.isBusy)
                            .accessibilityIdentifier("pr-review-guide-start")
                    } else {
                        Button(session.chapterIndex + 1 < session.chapters.count ? "Next" : "Finish", systemImage: "arrow.right") { session.advance() }
                            .herdrProminentButton().disabled(!session.canAdvance)
                            .accessibilityIdentifier("pr-review-guide-next")
                    }
                }
                HStack(spacing: 12) {
                    if session.chapter != nil {
                        Button { session.togglePlayback() } label: {
                            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 22, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(session.isBusy || session.isStale || session.isLoadingAudio)
                        .help(session.isPlaying ? "Pause narration" : "Listen to this explanation")
                        .accessibilityLabel(session.isPlaying ? "Pause narration" : "Play narration")
                        Slider(value: Binding(get: { session.player.progressTime }, set: { session.seek(to: $0) }), in: 0...max(1, session.player.duration))
                            .disabled(session.player.duration <= 0)
                            .accessibilityLabel("Narration position")
                        Text(time(session.player.progressTime)).herdrFont(.caption2, monospacedDigit: true).foregroundStyle(HerdrTheme.mist)
                        Menu {
                            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                                Button("\(rate.formatted())×") { session.setRate(rate) }
                            }
                            Divider()
                            ForEach(session.voices, id: \.self) { voice in
                                Button(voiceLabel(voice)) { session.chooseVoice(voice) }
                            }
                            Divider()
                            Button("Replay explanation") { session.replay() }
                            Button(session.marksEnabled ? "Hide drawings" : "Show drawings") { session.toggleMarks() }
                        } label: { Text("\(session.player.rate.formatted())×").herdrFont(.caption) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Playback speed, voice, and drawings")
                    } else {
                        Text(session.isAvailable ? "At your pace. You decide when to move on." : "Update the companion to use guided review.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                        Spacer(minLength: 0)
                    }
                    Button("Ask", systemImage: "text.bubble") {
                        session.beginQuestion(); questionFocused = true
                    }.disabled(!session.canAsk)
                    Button(session.isExpanded ? "Collapse" : "Expand", systemImage: "sidebar.right") {
                        session.isExpanded.toggle()
                    }.disabled(session.chapter == nil && session.transcript.isEmpty)
                }
                .buttonStyle(.herdrPlain)
            }
            if session.isBreezing {
                HStack(spacing: 8) {
                    Text("Low-impact files · \(session.breezePath ?? "")")
                        .herdrFont(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button(session.breezePaused ? "Resume breeze" : "Pause breeze") {
                        if session.breezePaused { session.resumeBreeze() } else { session.pause() }
                    }.disabled((session.isBusy || session.isSavingBreeze) && session.breezePaused)
                    Button("Stop breeze") { session.pause(); session.stopBreeze() }
                }
                .accessibilityIdentifier("pr-review-breeze-progress")
            } else if session.canStartBreeze && !(compact && isInitialPresentation) {
                Button("Breeze through low-impact files", systemImage: "forward") { session.startBreeze() }
                    .buttonStyle(.link).herdrFont(.caption)
                    .help("Explain each unviewed low-impact file in the full PR, then mark it viewed when narration finishes. Pause any time to ask a question.")
                    .accessibilityIdentifier("pr-review-breeze-start")
            }
            if let error = session.error {
                Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.alert).textSelection(.enabled)
            }
            if let notice = session.audioNotice {
                Text(notice).herdrFont(.caption).foregroundStyle(HerdrTheme.mist).textSelection(.enabled)
            }
            if let warning = session.activeGuide?.warnings?.first {
                Text(warning).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
            }
            if case let .failed(message) = session.player.phase {
                Text(message).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
            }
            if session.isAsking { composer }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isInitialPresentation ? 2 : 12)
        .background(HerdrTheme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(HerdrTheme.separator).frame(height: 1) }
        .sheet(isPresented: $recording) {
            HerdrVoiceNoteRecorderSheet(save: { _ in }, transcribe: { try await session.transcribe($0, preferPrivate: preferPrivateTranscription) }, insertTranscript: { transcript in
                if !session.draft.isEmpty { session.draft += "\n" }
                session.draft += transcript.text
                questionFocused = true
            }, cancel: {}, allowsRawSave: false)
        }
    }

    /// Before a walkthrough exists, keep its invitation to one compact toolbar row.
    /// Playback and expansion controls appear when there is an explanation.
    private var isInitialPresentation: Bool {
        session.chapter == nil && session.plan == nil && session.transcript.isEmpty
    }

    private var initialControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 20, height: 20)
            Text(session.isAvailable ? "Review buddy" : "Update companion for walkthrough")
                .herdrFont(.caption, weight: .semibold)
                .lineLimit(1)
                .help(session.isAvailable ? session.status : "Update the companion to use guided review.")
            Spacer(minLength: 4)
            if session.isBusy { ProgressView().controlSize(.small) }
            Button("Ask", systemImage: "text.bubble") {
                session.beginQuestion(); questionFocused = true
            }
            .buttonStyle(HerdrButtonStyle(kind: .ghost, height: HerdrTheme.ControlHeight.small))
            .disabled(!session.canAsk)
            Button(session.isBusy ? "Preparing…" : "Start walkthrough") { session.start() }
                .buttonStyle(HerdrButtonStyle(kind: .primary, height: HerdrTheme.ControlHeight.small))
                .disabled(!session.isAvailable || session.isBusy)
                .accessibilityIdentifier("pr-review-guide-start")
            if compact && session.canStartBreeze {
                Menu("Review options", systemImage: "ellipsis") {
                    Button("Breeze through low-impact files", systemImage: "forward") { session.startBreeze() }
                        .help("Explain each file, then mark it viewed after narration finishes")
                        .accessibilityIdentifier("pr-review-breeze-start")
                }
                .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                .help("Review options, including Breeze through low-impact files")
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = session.selection {
                HStack {
                    Label("\(selection.path) · \(selection.spans.map { "\($0.start)–\($0.end)" }.joined(separator: ", "))", systemImage: "curlybraces")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Clear selection") { session.selection = nil }.buttonStyle(.link)
                }.herdrFont(.caption2).foregroundStyle(HerdrTheme.mist)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this code, or anything in the PR…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).focused($questionFocused)
                    .padding(9).background(HerdrTheme.ink, in: .rect(cornerRadius: 8))
                    .onSubmit { session.submitQuestion() }
                    .accessibilityIdentifier("pr-review-guide-question")
                Button { session.pause(); recording = true } label: { Image(systemName: "mic") }
                    .buttonStyle(.bordered).help("Record a question, then review its transcript before sending")
                    .accessibilityLabel("Record a question")
                Button("Send", systemImage: "arrow.up") { session.submitQuestion() }
                    .herdrProminentButton()
                    .disabled(!session.canAsk || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text("Your place stays saved. Voice transcription goes into this draft before you send.")
                    .herdrFont(.caption2).foregroundStyle(HerdrTheme.muted)
                Spacer()
                Button("Close") { session.isAsking = false }.buttonStyle(.link).herdrFont(.caption)
            }
        }
    }
    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value)); return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func voiceLabel(_ value: String) -> String {
        ["af_jessica": "Jessica", "am_echo": "Echo", "bm_daniel": "Daniel"][value] ?? value
    }
}

struct PRReviewGuideDetails: View {
    @Bindable var session: PRReviewGuideSession
    var showSource: (PRReviewGuideSource) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let chapter = session.chapter {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(session.isDetour ? "Your question" : "This chapter", systemImage: "sparkles")
                            .herdrFont(.caption, weight: .medium).foregroundStyle(HerdrTheme.accent)
                        Text(chapter.title).herdrFont(.headline)
                        Text(chapter.objective).herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                    }
                    Text(.init(chapter.displayText)).herdrFont(.body).textSelection(.enabled)
                    if !session.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Review context").herdrFont(.caption, weight: .semibold)
                            ForEach(session.sources) { source in
                                Button { session.pause(); session.selectedSource = source } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(source.attribution, systemImage: "doc.text.magnifyingglass")
                                            .herdrFont(.caption, weight: .medium)
                                        Text("\(source.freshness.capitalized) revision · \(source.disposition ?? "Reported concern")")
                                            .herdrFont(.caption2).foregroundStyle(HerdrTheme.mist)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 8))
                                }.buttonStyle(.herdrPlain)
                            }
                        }
                    }
                    DisclosureGroup("Narration transcript") {
                        Text(chapter.spokenText).herdrFont(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.herdrFont(.caption)
                    if !chapter.suggestedQuestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keep exploring").herdrFont(.caption, weight: .semibold)
                            ForEach(chapter.suggestedQuestions, id: \.self) { question in
                                Button(question) { session.beginQuestion(); session.draft = question }
                                    .buttonStyle(.link).multilineTextAlignment(.leading).herdrFont(.caption)
                            }
                        }
                    }
                }
                if let limitations = session.activeGuide?.coverage?.limitations, !limitations.isEmpty {
                    DisclosureGroup("Available context") {
                        ForEach(limitations, id: \.self) { Text($0).herdrFont(.caption).foregroundStyle(HerdrTheme.mist) }
                    }.herdrFont(.caption)
                }
                if !session.chapters.isEmpty {
                    Divider()
                    Text("Your walkthrough").herdrFont(.caption, weight: .semibold)
                    ForEach(Array(session.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button { session.chooseChapter(index) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").herdrFont(.caption2, monospacedDigit: true)
                                    .frame(width: 20, height: 20)
                                    .background(index == session.chapterIndex ? HerdrTheme.accent : HerdrTheme.elevated, in: .circle)
                                    .foregroundStyle(index == session.chapterIndex ? HerdrTheme.ink : HerdrTheme.mist)
                                Text(chapter.title).herdrFont(.caption).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }.buttonStyle(.herdrPlain).disabled(session.isBusy || session.isStale)
                    }
                }
                if !session.transcript.isEmpty {
                    DisclosureGroup("Questions (\(session.transcript.count))") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(session.transcript) { turn in
                                let earlierRevision = turn.answer.baseSHA != session.scope?.baseSHA || turn.answer.headSHA != session.scope?.headSHA
                                Button(turn.question + (earlierRevision ? " (earlier revision)" : "")) { session.showAnswer(turn) }
                                    .buttonStyle(.link).herdrFont(.caption).multilineTextAlignment(.leading)
                            }
                        }.padding(.top, 6)
                    }.herdrFont(.caption)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HerdrTheme.ink)
        .overlay(alignment: .leading) { Rectangle().fill(HerdrTheme.separator).frame(width: 1) }
        .popover(item: $session.selectedSource) { source in
            VStack(alignment: .leading, spacing: 12) {
                Text(source.attribution).herdrFont(.headline)
                Text("\(source.freshness.capitalized) revision · \(source.provenance ?? "Source attribution unknown")")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                ScrollView { Text(source.excerpt).herdrFont(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 250)
                if let assessment = session.activeGuide?.assessments?.first(where: { $0.sourceID == source.id }) {
                    Text("Buddy assessment · " + assessment.status.replacingOccurrences(of: "_", with: " "))
                        .herdrFont(.caption, weight: .semibold).foregroundStyle(HerdrTheme.accent)
                    Text(assessment.explanation).herdrFont(.caption).textSelection(.enabled)
                }
                Text("This is the reviewer's original report. The buddy's assessment is separate in the explanation.")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.mist)
                Button("Open original report", systemImage: "doc.text") { session.selectedSource = nil; showSource(source) }
                    .buttonStyle(.link)
            }.padding(18).frame(width: 380).background(HerdrTheme.graphite)
        }
        .accessibilityIdentifier("pr-review-guide-details")
    }
}
