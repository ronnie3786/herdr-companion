import Foundation
import Observation

/// A window owns its tour and interruption checkpoint. Server responses and
/// narration may only publish into the exact connection and code revision.
@MainActor @Observable
final class PRReviewGuideSession {
    struct Checkpoint: Codable, Equatable {
        var chapter: Int
        var segment: Int
        var time: Double
        var voice: String
    }
    struct Saved: Codable {
        var scope: PRReviewGuideScope
        var plan: PRReviewGuide?
        var checkpoint: Checkpoint
        var transcript: [PRReviewGuideTranscript]
    }

    private(set) var scope: PRReviewGuideScope?
    private(set) var plan: PRReviewGuide?
    private(set) var answer: PRReviewGuide?
    private(set) var transcript: [PRReviewGuideTranscript] = []
    private(set) var chapterIndex = 0
    private(set) var segmentIndex = 0
    private(set) var isBusy = false
    private(set) var isLoadingAudio = false
    private(set) var isFinished = false
    private(set) var isAvailable = false
    private(set) var error: String?
    private(set) var audioNotice: String?
    private(set) var voices: [String] = []
    private(set) var selectedVoice = ""
    var draft = ""
    var isExpanded = false
    var isAsking = false
    var marksEnabled = true
    var selectedSource: PRReviewGuideSource?
    var selection: PRReviewSelection?
    let player = PRReviewNarrationPlayer()
    let annotations = PRReviewGuideAnnotationChannel()

    @ObservationIgnored private var client: (any PRReviewGuideClient)?
    @ObservationIgnored private var connectionGeneration: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var audioGeneration = 0
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var loadedVoiceCapabilities = false
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var checkpoint: Checkpoint?
    @ObservationIgnored private var resumeTime = 0.0
    @ObservationIgnored private var audioCache: [String: PRReviewNarrationManifest] = [:]
    @ObservationIgnored private var navigate: ((PRReviewGuideTarget) -> Void)?
    @ObservationIgnored private var currentPath: (() -> String?)?
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private let persistenceURL: URL?

    init(persistenceURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Herdr/Assistant/pr-review-guides.json")) {
        self.persistenceURL = persistenceURL
        player.onFrame = { [weak self] frame in
            guard let self, !self.isStale else { return }
            self.annotations.update(frame)
        }
        player.onCompletion = { [weak self] in self?.narrationCompleted() }
    }

    var activeGuide: PRReviewGuide? { answer ?? plan }
    /// Saved answers keep their original code binding, including after a new
    /// walkthrough starts. Reading history must never remap old targets onto
    /// the currently displayed patch.
    var isStale: Bool {
        guard let scope, let guide = activeGuide else { return false }
        return guide.reviewID != scope.reviewID || guide.baseSHA != scope.baseSHA || guide.headSHA != scope.headSHA
    }
    var chapters: [PRReviewGuideChapter] { plan?.chapters ?? [] }
    var chapter: PRReviewGuideChapter? {
        if let answer { return answer.chapters?.first }
        return chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil
    }
    var segment: PRReviewGuideSegment? {
        guard let segments = chapter?.segments, segments.indices.contains(segmentIndex) else { return nil }
        return segments[segmentIndex]
    }
    var sources: [PRReviewGuideSource] {
        let ids = Set(chapter?.segments.flatMap(\.sourceRefs) ?? [])
        return (activeGuide?.sources ?? []).filter { ids.contains($0.id) }
    }
    var isDetour: Bool { checkpoint != nil || answer != nil }
    var canAdvance: Bool { plan != nil && !isDetour && !isBusy && !isStale && !isFinished }
    var canAsk: Bool { isAvailable && !isBusy && !isStale }
    var isPlaying: Bool { player.phase == .playing }
    var status: String {
        if isStale { return "Earlier revision · restart to update" }
        if isBusy { return answer == nil && plan == nil ? "Preparing your walkthrough…" : "Examining code and review context…" }
        if isLoadingAudio { return "Preparing narration…" }
        if isDetour { return "Question · your walkthrough place is saved" }
        if isFinished { return "Walkthrough complete · you decide what to review" }
        if plan != nil { return "Chapter \(chapterIndex + 1) of \(chapters.count) · at your pace" }
        return "Short chapters. Questions welcome."
    }

    func configure(store: PRReviewStore) {
        guard let machineID = store.currentMachineID, let review = store.snapshot?.review else {
            if scope != nil { suspend() }
            return
        }
        let newScope = PRReviewGuideScope(machineID: machineID, reviewID: review.id, baseSHA: review.baseSHA, headSHA: review.headSHA)
        let connectionChanged = connectionGeneration != store.guideConnectionGeneration
        let scopeChanged = scope != newScope
        guard scopeChanged || connectionChanged else {
            isAvailable = store.isDemo || store.capabilities?.capabilities.contains("pr-review-guide-v1") == true
            return
        }
        persist()
        resumeTime = player.currentTime
        cancelPending()
        let sameReview = scope?.machineID == machineID && scope?.reviewID == review.id
        let changedRevision = sameReview && scope != newScope
        if connectionChanged {
            loadedVoiceCapabilities = false
            voices = []
        }
        connectionGeneration = store.guideConnectionGeneration
        client = store.guideClient
        isDemo = store.isDemo
        scope = newScope
        isAvailable = store.isDemo || store.capabilities?.capabilities.contains("pr-review-guide-v1") == true
        navigate = { [weak store] target in
            guard let store else { return }
            store.tab = .files
            store.scroll(to: target.path, line: target.startLine, side: target.side)
            store.highlight = (target.path, target.startLine, target.endLine, target.side)
        }
        currentPath = { [weak store] in store?.selectedPath }
        if changedRevision {
            error = "The PR changed. This explanation belongs to the earlier revision. Start a new walkthrough to inspect the current code."
        } else if !sameReview {
            reset()
            restore()
        }
    }

    func suspend() {
        persist()
        cancelPending()
        client = nil
        connectionGeneration = nil
        isAvailable = false
    }

    func start() {
        guard isAvailable, !isBusy else { return }
        let savedTranscript = transcript
        reset()
        transcript = savedTranscript
        request(kind: "walkthrough", question: nil)
    }

    func observedFileNavigation(_ path: String?) {
        guard plan != nil, !isBusy, !isStale, !isDetour,
              let targetPath = segment?.path, let path, path != targetPath else { return }
        pause()
        saveCheckpoint()
    }

    func beginQuestion(selection: PRReviewSelection? = nil) {
        pause()
        saveCheckpoint()
        self.selection = selection
        if let question = selection?.question, !question.isEmpty { draft = question }
        isAsking = true
    }

    func submitQuestion() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, canAsk else { return }
        saveCheckpoint()
        pause()
        request(kind: "answer", question: question)
    }

    func returnToWalkthrough() {
        cancelPending()
        answer = nil
        isAsking = false
        selection = nil
        if let checkpoint {
            chapterIndex = checkpoint.chapter
            segmentIndex = checkpoint.segment
            selectedVoice = checkpoint.voice
            resumeTime = checkpoint.time
        }
        checkpoint = nil
        error = nil
        navigateToSegment()
        // Restore the exact segment paused. Cached audio avoids a second request.
        if resumeTime > 0 { loadAudio(autoplay: false) }
        persist()
    }

    func advance() {
        guard canAdvance else { return }
        cancelAudio()
        if chapterIndex + 1 < chapters.count {
            chapterIndex += 1
            segmentIndex = 0
            resumeTime = 0
            navigateToSegment()
        } else { isFinished = true }
        persist()
    }

    func chooseChapter(_ index: Int) {
        guard chapters.indices.contains(index), !isBusy, !isStale else { return }
        cancelAudio()
        answer = nil
        checkpoint = nil
        chapterIndex = index
        segmentIndex = 0
        resumeTime = 0
        isFinished = false
        navigateToSegment()
        persist()
    }

    func chooseVoice(_ voice: String) {
        guard voice != selectedVoice, voices.contains(voice) else { return }
        cancelAudio()
        selectedVoice = voice
        resumeTime = 0
        audioNotice = "Voice changed. Play restarts this passage with its own timing."
        persist()
    }

    func pause() { wantsPlayback = false; player.pause(); persist() }
    func seek(to time: Double) { player.seek(to: time); persist() }
    func setRate(_ rate: Float) { player.setRate(Double(rate)) }
    func toggleMarks() {
        marksEnabled.toggle()
        annotations.setEnabled(marksEnabled)
    }
    func togglePlayback() {
        if isPlaying { pause(); return }
        guard !isBusy, !isStale, chapter != nil else { return }
        wantsPlayback = true
        if player.phase == .paused || player.phase == .ready { player.play() }
        else if player.phase == .finished { player.seek(to: 0); player.play() }
        else { loadAudio(autoplay: true) }
    }
    func replay() {
        guard chapter != nil, !isStale else { return }
        cancelAudio(); segmentIndex = 0; resumeTime = 0
        loadAudio(autoplay: true)
    }

    func showAnswer(_ turn: PRReviewGuideTranscript) {
        pause(); saveCheckpoint(); cancelAudio()
        answer = turn.answer; segmentIndex = 0; resumeTime = 0
        isExpanded = true
        navigateToSegment()
    }

    func transcribe(_ url: URL, preferPrivate: Bool = true) async throws -> VoiceTranscription {
        let client = preferPrivate ? client : nil
        let generation = generation
        let result = try await VoiceTranscriptionPipeline.run(preferPrivate: client != nil, privateTranscription: {
            guard let client else { throw APIError.invalidResponse }
            let response = try await client.transcribeVoice(fileURL: url)
            guard response.ok, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
            return .init(text: response.text, provider: .server, language: response.language, usedFallback: false)
        }, appleTranscription: {
            let text = try await AppleVoiceTranscriber.transcribe(fileURL: url)
            return .init(text: text, provider: .apple, language: Locale.current.language.languageCode?.identifier, usedFallback: false)
        })
        guard generation == self.generation else { throw CancellationError() }
        return result
    }

    private func request(kind: String, question: String?) {
        guard let scope else { return }
        cancelPending()
        error = nil; isBusy = true
        let generation = generation
        let request = PRReviewGuideRequest(
            requestID: UUID().uuidString, baseSHA: scope.baseSHA, headSHA: scope.headSHA,
            kind: kind, question: question, path: selection?.path ?? currentPath?(), chapterID: chapter?.id,
            continueFromGuideID: answer?.id ?? plan?.id,
            selection: selection.map { .init(text: $0.text, spans: $0.spans.map { .init(side: $0.side.wireSide, startLine: $0.start, endLine: $0.end) }) }
        )
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                var result: PRReviewGuide
                if self.isDemo { result = PRReviewGuideDemo.make(scope: scope, question: question) }
                else {
                    guard let client = self.client else { throw APIError.invalidResponse }
                    result = try await client.startPRReviewGuide(reviewID: scope.reviewID, request: request)
                    while result.state == "running" || result.state == "queued" {
                        try await Task.sleep(for: .seconds(1))
                        try Task.checkCancellation()
                        result = try await client.fetchPRReviewGuide(reviewID: scope.reviewID, guideID: result.id)
                    }
                }
                guard generation == self.generation, scope == self.scope, !Task.isCancelled else { return }
                guard result.baseSHA == scope.baseSHA, result.headSHA == scope.headSHA, result.reviewID == scope.reviewID else {
                    throw APIError.server(status: 409, message: "This explanation belongs to a different PR revision. Refresh the review and start again.")
                }
                guard result.state == "finished", !(result.chapters ?? []).isEmpty else {
                    throw APIError.server(status: 422, message: result.error ?? "The buddy could not prepare an explanation. Try again.")
                }
                if let question {
                    self.answer = result
                    self.transcript.append(.init(id: result.id, question: question, answer: result))
                    self.draft = ""; self.selection = nil; self.isAsking = false; self.isExpanded = true
                } else { self.plan = result; self.chapterIndex = 0 }
                self.segmentIndex = 0; self.resumeTime = 0; self.isBusy = false
                self.navigateToSegment(); self.persist()
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                self.isBusy = false
                self.error = error.localizedDescription
            }
        }
    }

    private func loadAudio(autoplay: Bool) {
        guard !isLoadingAudio, !isStale, let chapter else { return }
        let text = segment?.spokenText ?? chapter.spokenText
        let drawings = segment?.drawings ?? []
        guard !text.isEmpty else { return }
        cancelAudio()
        isLoadingAudio = true; audioNotice = nil; wantsPlayback = autoplay
        let generation = generation, audioGeneration = audioGeneration
        let segmentID = segment?.id ?? chapter.id
        let speechClaimGeneration = HerdrSpeechOwnership.shared.claimGeneration
        navigateToSegment()
        audioTask = Task { [weak self] in
            guard let self else { return }
            do {
                let usingFixture = self.isDemo && PRReviewGuideDemo.narrationFixtureDirectory != nil
                guard self.client != nil || usingFixture else {
                    throw APIError.server(status: 503, message: "Narration is available when connected to a companion with Kokoro configured. The full explanation is available in Expand.")
                }
                if !self.loadedVoiceCapabilities {
                    let capabilities: PRReviewNarrationCapabilities
                    if usingFixture {
                        capabilities = .init(available: true, voices: ["af_jessica", "am_echo", "bm_daniel"], defaultVoice: "af_jessica", reason: nil)
                    } else if let client = self.client {
                        capabilities = try await client.prReviewNarrationCapabilities()
                    } else { throw APIError.invalidResponse }
                    guard generation == self.generation, audioGeneration == self.audioGeneration else { return }
                    self.voices = capabilities.voices
                    if !capabilities.voices.contains(self.selectedVoice) {
                        self.selectedVoice = capabilities.defaultVoice
                        self.resumeTime = 0
                    }
                    self.loadedVoiceCapabilities = true
                }
                let voice = self.selectedVoice
                let cacheKey = "\(self.activeGuide?.id ?? "")/\(segmentID)/\(voice)"
                let manifest: PRReviewNarrationManifest
                if let cached = self.audioCache[cacheKey] { manifest = cached }
                else if usingFixture { manifest = try PRReviewGuideDemo.narrationFixture(text: text, voice: voice) }
                else if let client = self.client { manifest = try await client.captionedPRReviewSpeech(text: text, voice: voice, drawings: drawings) }
                else { throw APIError.invalidResponse }
                guard generation == self.generation, audioGeneration == self.audioGeneration, !Task.isCancelled else { return }
                if self.audioCache.count >= 12 { self.audioCache.removeAll() }
                self.audioCache[cacheKey] = manifest
                try self.player.load(manifest, expectedScript: text, expectedVoice: voice)
                self.isLoadingAudio = false
                self.player.seek(to: self.resumeTime)
                self.resumeTime = 0
                if manifest.rejectedCues?.isEmpty == false {
                    self.audioNotice = "Some drawing phrases could not be aligned to this voice. The narration remains available."
                }
                let drawingTargets = drawings.flatMap(\.targets)
                let targets = drawingTargets.isEmpty ? self.segment?.target.map { [$0] } ?? [] : drawingTargets
                if targets.isEmpty { if autoplay && self.wantsPlayback && speechClaimGeneration == HerdrSpeechOwnership.shared.claimGeneration { self.player.play() }; return }
                self.annotations.prepare(targets: targets, generation: self.player.generationID) { [weak self] ready in
                    guard let self, generation == self.generation, audioGeneration == self.audioGeneration else { return }
                    self.player.refreshFrame()
                    if !ready { self.audioNotice = "Some drawing targets are outside the available diff. The explanation remains available." }
                    if autoplay && self.wantsPlayback && speechClaimGeneration == HerdrSpeechOwnership.shared.claimGeneration { self.player.play() }
                }
            } catch {
                guard generation == self.generation, audioGeneration == self.audioGeneration, !Task.isCancelled else { return }
                self.isLoadingAudio = false; self.audioNotice = error.localizedDescription
            }
        }
    }

    private func narrationCompleted() {
        guard let segments = chapter?.segments, segmentIndex + 1 < segments.count else { persist(); return }
        segmentIndex += 1; resumeTime = 0
        loadAudio(autoplay: true)
    }
    private func navigateToSegment() {
        guard !isStale else { return }
        if let target = segment?.target ?? segment?.drawings.first?.targets.first { navigate?(target) }
    }
    private func saveCheckpoint() {
        guard checkpoint == nil, plan != nil else { return }
        checkpoint = .init(chapter: chapterIndex, segment: segmentIndex, time: player.currentTime, voice: selectedVoice)
    }
    private func cancelAudio() {
        wantsPlayback = false
        audioGeneration &+= 1; audioTask?.cancel(); audioTask = nil
        player.stop(); annotations.clear(); isLoadingAudio = false
    }
    private func cancelPending() {
        generation &+= 1; requestTask?.cancel(); requestTask = nil; isBusy = false
        cancelAudio()
    }
    private func reset() {
        plan = nil; answer = nil; checkpoint = nil; transcript = []; selection = nil
        chapterIndex = 0; segmentIndex = 0; resumeTime = 0; isFinished = false
        draft = ""; error = nil; audioNotice = nil; isAsking = false; isExpanded = false
        audioCache = [:]
    }
    private func persist() {
        guard let persistenceURL, let scope, !isStale, plan != nil || !transcript.isEmpty else { return }
        var saved: [Saved] = []
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            do { saved = try JSONDecoder().decode([Saved].self, from: Data(contentsOf: persistenceURL)) }
            catch {
                self.error = "Saved walkthrough progress could not be read. The original file has been preserved; this walkthrough can continue in memory."
                return
            }
        }
        saved.removeAll { $0.scope == scope }
        let position = checkpoint ?? .init(chapter: chapterIndex, segment: segmentIndex, time: max(resumeTime, player.currentTime), voice: selectedVoice)
        saved.append(.init(scope: scope, plan: plan, checkpoint: position, transcript: Array(transcript.suffix(20))))
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Array(saved.suffix(12))).write(to: persistenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
        } catch { self.error = "Progress could not be saved on this Mac. You can continue this walkthrough." }
    }
    private func restore() {
        guard let persistenceURL, let scope,
              let saved = try? JSONDecoder().decode([Saved].self, from: Data(contentsOf: persistenceURL)),
              let value = saved.last(where: { $0.scope == scope }) else { return }
        plan = value.plan; transcript = value.transcript
        chapterIndex = min(max(0, value.checkpoint.chapter), max(0, chapters.count - 1))
        segmentIndex = min(max(0, value.checkpoint.segment), max(0, (chapter?.segments.count ?? 1) - 1))
        selectedVoice = value.checkpoint.voice; resumeTime = value.checkpoint.time
    }
}
