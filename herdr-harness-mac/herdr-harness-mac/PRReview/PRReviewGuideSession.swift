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
    private(set) var isBreezing = false
    private(set) var breezePaused = false
    private(set) var isSavingBreeze = false
    private(set) var breezePath: String?
    @ObservationIgnored private var breezePaths: [String] = []
    @ObservationIgnored private var breezeGuide: PRReviewGuide?
    @ObservationIgnored private var breezeSegment = 0
    @ObservationIgnored private var breezeTime = 0.0
    @ObservationIgnored private var breezeEpoch = 0
    @ObservationIgnored private var breezeCompletionTask: Task<Void, Never>?
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
    @ObservationIgnored private weak var store: PRReviewStore?
    @ObservationIgnored private var currentPath: (() -> String?)?
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let allowsDemoPersistence: Bool

    /// Demo runs and hosted tests must not restore or overwrite operator progress.
    /// Persistence tests opt into their own temporary URL through the designated initializer.
    convenience init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herdr/Assistant/pr-review-guides.json")
        self.init(persistenceURL: isTesting ? nil : url, allowsDemoPersistence: false)
    }

    init(persistenceURL: URL?, allowsDemoPersistence: Bool = true) {
        self.persistenceURL = persistenceURL
        self.allowsDemoPersistence = allowsDemoPersistence
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
        return guide.reviewID != scope.reviewID || guide.baseSHA != scope.baseSHA || guide.headSHA != scope.headSHA || guide.comparison != scope.comparison
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
        if isBreezing {
            if breezePaused { return "Low-impact review paused. Resume when you are ready." }
            if isSavingBreeze { return "Saving Viewed before the next file…" }
            if isBusy { return "Preparing a low-impact file explanation…" }
            return "Low-impact files · marked viewed after narration finishes"
        }
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
        let newScope = PRReviewGuideScope(machineID: machineID, reviewID: review.id, baseSHA: review.baseSHA, headSHA: review.headSHA, comparison: store.currentComparison, comparisonSelection: store.supportsComparisons ? store.comparisonSelection : nil)
        let connectionChanged = connectionGeneration != store.guideConnectionGeneration
        let scopeChanged = scope != newScope
        guard scopeChanged || connectionChanged else {
            isAvailable = (store.isDemo || store.capabilities?.capabilities.contains("pr-review-guide-v1") == true) && (!store.supportsComparisons || store.currentComparison != nil)
            return
        }
        stopBreeze()
        persist()
        resumeTime = player.currentTime
        cancelPending()
        let sameReview = scope?.machineID == machineID && scope?.reviewID == review.id
        let changedRevision = sameReview && (scope?.baseSHA != newScope.baseSHA || scope?.headSHA != newScope.headSHA)
        let changedComparison = sameReview && (scope?.comparison != newScope.comparison || scope?.comparisonSelection != newScope.comparisonSelection)
        self.store = store
        if connectionChanged {
            loadedVoiceCapabilities = false
            voices = []
        }
        connectionGeneration = store.guideConnectionGeneration
        client = store.guideClient
        isDemo = store.isDemo
        scope = newScope
        isAvailable = (store.isDemo || store.capabilities?.capabilities.contains("pr-review-guide-v1") == true) && (!store.supportsComparisons || store.currentComparison != nil)
        navigate = { [weak store] target in
            guard let store else { return }
            guard store.comparisonFiles.contains(where: { $0.path == target.path }) else { return }
            store.tab = .files
            store.scroll(to: target.path, line: target.startLine, side: target.side)
            store.highlight = (target.path, target.startLine, target.endLine, target.side)
        }
        currentPath = { [weak store] in store?.selectedPath }
        if changedRevision {
            error = "The PR changed. This explanation belongs to the earlier revision. Start a new walkthrough to inspect the current code."
        } else if !sameReview || changedComparison {
            reset()
            restore()
        }
    }

    func suspend() {
        stopBreeze()
        persist()
        cancelPending()
        client = nil
        connectionGeneration = nil
        isAvailable = false
    }

    func start() {
        guard isAvailable, !isBusy else { return }
        stopBreeze()
        let savedTranscript = transcript
        reset()
        transcript = savedTranscript
        request(kind: "walkthrough", question: nil)
    }

    func observedFileNavigation(_ path: String?) {
        if isBreezing, let path, path != breezePath { pause() }
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
        stopBreeze()
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

    func pause() {
        if isBreezing {
            breezePaused = true
            breezeEpoch &+= 1
            if answer?.id == breezeGuide?.id {
                breezeSegment = segmentIndex
                breezeTime = player.currentTime
            }
        }
        wantsPlayback = false; player.pause(); persist()
    }
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

    private func request(kind: String, question: String?, forBreeze: Bool = false) {
        guard let scope else { return }
        cancelPending()
        error = nil; isBusy = true
        let generation = generation
        let request = PRReviewGuideRequest(
            requestID: UUID().uuidString, baseSHA: scope.baseSHA, headSHA: scope.headSHA,
            kind: kind, question: question, path: selection?.path ?? currentPath?(), chapterID: chapter?.id,
            continueFromGuideID: answer?.id ?? plan?.id,
            selection: selection.map { .init(text: $0.text, spans: $0.spans.map { .init(side: $0.side.wireSide, startLine: $0.start, endLine: $0.end) }) },
            comparison: scope.comparisonSelection,
            viewerState: scope.comparisonSelection == nil ? nil : .init(
                path: currentPath?(),
                visibleLines: store?.visibleLines.map { .init(path: $0.path, side: $0.side.wireSide, startLine: $0.start, endLine: $0.end) },
                diffStyle: store?.diffStyle ?? "unified", overflow: store?.diffOverflow ?? "scroll")
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
                guard result.baseSHA == scope.baseSHA, result.headSHA == scope.headSHA, result.reviewID == scope.reviewID, result.comparison == scope.comparison else {
                    throw APIError.server(status: 409, message: "This explanation belongs to a different PR revision. Refresh the review and start again.")
                }
                guard result.state == "finished", !(result.chapters ?? []).isEmpty else {
                    throw APIError.server(status: 422, message: result.error ?? "The buddy could not prepare an explanation. Try again.")
                }
                if forBreeze, let path = self.breezePath {
                    let targets = (result.chapters ?? []).flatMap(\.segments).compactMap(\.path)
                    guard !targets.isEmpty, targets.allSatisfy({ $0 == path }) else {
                        throw APIError.server(status: 422, message: "The explanation did not stay with this file. Nothing was marked viewed; ask a question or resume to try again.")
                    }
                }
                if let question {
                    self.answer = result
                    if !forBreeze { self.transcript.append(.init(id: result.id, question: question, answer: result)) }
                    self.draft = ""; self.selection = nil; self.isAsking = false; self.isExpanded = true
                } else { self.plan = result; self.chapterIndex = 0 }
                self.segmentIndex = 0; self.resumeTime = 0; self.isBusy = false
                self.navigateToSegment(); self.persist()
                if forBreeze, self.isBreezing {
                    self.breezeGuide = result
                    self.breezeSegment = 0; self.breezeTime = 0
                    if !self.breezePaused { self.loadAudio(autoplay: true) }
                }
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                self.isBusy = false
                self.error = error.localizedDescription
                if forBreeze { self.breezePaused = true }
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
                if self.isBreezing { self.breezePaused = true }
            }
        }
    }

    private func narrationCompleted() {
        guard !isStale else { return }
        guard let segments = chapter?.segments, segmentIndex + 1 < segments.count else {
            if isBreezing, !breezePaused, answer?.id == breezeGuide?.id, player.phase == .finished {
                completeBreezeExplanation()
            }
            persist(); return
        }
        if isBreezing && breezePaused { return }
        segmentIndex += 1; resumeTime = 0
        loadAudio(autoplay: true)
    }
    var canStartBreeze: Bool {
        guard canAsk, let store, store.comparisonSelection == .all else { return false }
        return store.comparisonFiles.contains { $0.impact == .low && !$0.viewed }
    }

    /// Explicit opt-in applies only to the current full PR. Historical views
    /// keep independent local Viewed flags and never mark today's PR reviewed.
    func startBreeze() {
        guard canStartBreeze, let store else { return }
        pause(); saveCheckpoint()
        breezePaths = store.comparisonFiles.filter { $0.impact == .low && !$0.viewed }.map(\.path)
        isBreezing = true; breezePaused = false
        nextBreezeFile()
    }

    func resumeBreeze() {
        guard isBreezing, breezePaused, !isBusy, !isSavingBreeze, !isStale else { return }
        breezePaused = false
        if let path = breezePath, store?.comparisonFiles.first(where: { $0.path == path })?.viewed == true {
            breezePaths.removeFirst(); nextBreezeFile(); return
        }
        guard let breezeGuide else { nextBreezeFile(); return }
        answer = breezeGuide; segmentIndex = breezeSegment; resumeTime = breezeTime
        isAsking = false; selection = nil
        navigateToSegment()
        loadAudio(autoplay: true)
    }

    func stopBreeze() {
        breezeEpoch &+= 1
        breezeCompletionTask?.cancel(); breezeCompletionTask = nil
        isBreezing = false; breezePaused = false; isSavingBreeze = false; breezePath = nil
        breezePaths = []; breezeGuide = nil
    }

    private func nextBreezeFile() {
        guard isBreezing, !breezePaused, let path = breezePaths.first else {
            if breezePaths.isEmpty {
                stopBreeze()
                audioNotice = "Low-impact files complete. Each finished explanation was marked viewed."
            }
            return
        }
        breezePath = path
        breezeGuide = nil
        answer = nil; selection = nil; isAsking = false
        store?.selectedPath = path
        request(kind: "answer", question: "Briefly explain only the low-impact changes in \(path), one file at a time. State any uncertainty and demonstrate relevant changed lines. Do not navigate to other files. The user explicitly chose to breeze through low-impact files; Herdr will mark this file viewed only after this explanation finishes playing.", forBreeze: true)
    }

    private func completeBreezeExplanation() {
        guard !isSavingBreeze, let store, let scope, let path = breezePath, breezePaths.first == path else { return }
        isSavingBreeze = true
        let epoch = breezeEpoch
        breezeCompletionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.breezePath == path { self.isSavingBreeze = false } }
            do {
                let marked = try await store.markBreezeViewed(path: path, scope: scope)
                guard marked else {
                    if self.breezeEpoch == epoch {
                        self.breezePaused = true
                        self.error = "Viewed was not confirmed. Refresh the review before continuing."
                    }
                    return
                }
                guard self.isBreezing, !self.breezePaused, self.breezeEpoch == epoch,
                      self.scope == scope, !Task.isCancelled else { return }
                self.isSavingBreeze = false
                self.breezePaths.removeFirst()
                self.nextBreezeFile()
            } catch {
                guard self.breezeEpoch == epoch, !Task.isCancelled else { return }
                self.breezePaused = true
                self.error = "The explanation finished, but Viewed could not be saved: \(error.localizedDescription)"
            }
        }
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
        guard !isDemo || allowsDemoPersistence,
              let persistenceURL, let scope, !isStale, plan != nil || !transcript.isEmpty else { return }
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
        guard !isDemo || allowsDemoPersistence,
              let persistenceURL, let scope,
              let saved = try? JSONDecoder().decode([Saved].self, from: Data(contentsOf: persistenceURL)),
              let value = saved.last(where: { $0.scope == scope }) else { return }
        plan = value.plan; transcript = value.transcript
        chapterIndex = min(max(0, value.checkpoint.chapter), max(0, chapters.count - 1))
        segmentIndex = min(max(0, value.checkpoint.segment), max(0, (chapter?.segments.count ?? 1) - 1))
        selectedVoice = value.checkpoint.voice; resumeTime = value.checkpoint.time
    }
}
