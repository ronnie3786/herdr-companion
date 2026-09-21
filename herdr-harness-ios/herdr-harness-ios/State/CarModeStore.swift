import Foundation
import Observation

/// Drives Car mode: which agents are shown, what each one's one-line status is,
/// the shared summary audio, and the voice-reply state machine.
///
/// Fleet state comes from the app model; transcript detail comes from one-shot
/// Pi snapshots polled on a slow cadence. That is deliberately cheaper than
/// opening four live event streams in a car, and it keeps working when a bridge
/// only supports snapshot polling.
@MainActor
@Observable
final class CarModeStore {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum Screen: Equatable {
        case grid
        case detail(String)
    }

    /// Tap once to record, tap again to finish — press-and-hold is unreliable on
    /// a mount, so the capture is always started in its locked form.
    enum VoicePhase: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case review(String)
        case sending(String)
        case sent(String, PiPromptDisposition)
        case failed(String)

        var isActive: Bool { self != .idle }

        var text: String? {
            switch self {
            case let .review(text), let .sending(text), let .sent(text, _): text
            case .idle, .recording, .transcribing, .failed: nil
            }
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    struct Entry: Identifiable {
        let session: AgentSession
        var summary: CarAgentSummary
        var connectionState: ConnectionState
        var loadedAt: Date?
        var didLoadAudioCapabilities: Bool
        let audioPlayer: ResponseAudioPlayer

        var id: String { session.id }
        var pane: HerdrPane { session.pane }

        @MainActor
        var isPlayingAudio: Bool {
            audioPlayer.phase.activeAction != nil
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var loadPhase: LoadPhase = .idle
    private(set) var voice: VoicePhase = .idle
    private(set) var voiceAgentID: String?
    private(set) var lastError: String?
    private(set) var lastRefreshedAt: Date?
    var screen: Screen = .grid

    /// Refresh cadence while Car mode is on screen and the app is active.
    @ObservationIgnored var pollInterval: Duration = .seconds(5)
    /// How long the "sent" confirmation stays up before returning to the grid.
    @ObservationIgnored var sentDisplayDuration: Duration = .milliseconds(2_600)
    /// Test seams. Snapshot fetches run concurrently, so this one is Sendable.
    @ObservationIgnored var snapshotProvider: (@MainActor @Sendable (HerdrPane) async throws -> PiConversationSnapshot)?
    @ObservationIgnored var transcriber: (@MainActor (URL) async throws -> VoiceTranscription)?
    /// Test seam for the reply flow. When set, `beginVoice` deliberately does not
    /// start the real microphone: there is no recording behind an injected
    /// outcome, and a unit test should never ask for the microphone.
    @ObservationIgnored var captureOutcomeProvider: (@MainActor () async -> HerdrQuickVoiceCapture.Outcome)?
    @ObservationIgnored var demoSummaryProvider: (@MainActor (AgentSession) -> CarAgentSummary)?
    @ObservationIgnored var now: @MainActor () -> Date = { .now }

    @ObservationIgnored private let capture = HerdrQuickVoiceCapture()
    @ObservationIgnored private var sentClearTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false

    var isShowingVoiceLayer: Bool { voice.isActive }

    var voiceSamples: [CGFloat] { capture.samples }

    var voiceEntry: Entry? {
        voiceAgentID.flatMap(entry(id:))
    }

    var playingAgentID: String? {
        entries.first(where: { $0.audioPlayer.phase.activeAction != nil })?.id
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func summary(for entryID: String) -> CarAgentSummary {
        entry(id: entryID)?.summary ?? .empty
    }

    // MARK: - Loading

    /// Polls until the surrounding task is cancelled. The view ties this to the
    /// scene phase so a backgrounded phone stops spending radio time.
    func run(model: HerdrAppModel) async {
        while !Task.isCancelled {
            await refresh(model: model)
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    func stop() {
        sentClearTask?.cancel()
        sentClearTask = nil
        capture.cancel()
        stopAllAudio()
        resetVoice()
    }

    func refresh(model: HerdrAppModel) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sessions = CarModeSelection.entries(
            workspaces: model.workspaces,
            machines: model.machines,
            limit: model.carModePreferences.agentLimit
        )
        reconcile(with: sessions, model: model)

        if entries.isEmpty {
            loadPhase = .ready
            lastRefreshedAt = now()
            return
        }

        if loadPhase == .idle { loadPhase = .loading }

        if model.isDemoMode {
            let provider = demoSummaryProvider ?? { CarModeDemoData.summary(for: $0) }
            for index in entries.indices {
                entries[index].summary = provider(entries[index].session)
                entries[index].connectionState = .demo
                entries[index].loadedAt = now()
            }
            loadPhase = .ready
            lastRefreshedAt = now()
            return
        }

        let snapshots = await fetchSnapshots(for: entries.map(\.session), model: model)

        for index in entries.indices {
            let entry = entries[index]
            let pane = entry.pane
            guard let snapshot = snapshots[entry.id] else {
                if loadPhase != .ready {
                    loadPhase = .failed("Couldn't read these agents yet.")
                }
                entries[index].connectionState = model.connectionState(forMachine: pane.machineID)
                continue
            }
            var reducer = PiConversationReducer()
            reducer.replace(with: snapshot)
            let summary = CarAgentSummary.derive(
                pane: pane,
                turns: reducer.turns,
                phase: reducer.phase,
                pendingInteractions: reducer.pendingInteractions,
                compactionActivity: reducer.compactionActivity,
                bridgeConnected: reducer.bridgeConnected
            )
            // A different answer invalidates whatever is playing, exactly as the
            // chat view treats a new reply.
            if entry.summary.response != summary.response {
                entry.audioPlayer.responseDidChange(hasResponse: summary.hasPlayableResponse)
            }
            entries[index].summary = summary
            entries[index].connectionState = model.connectionState(forMachine: pane.machineID)
            entries[index].loadedAt = now()
        }

        loadPhase = .ready
        lastRefreshedAt = now()

        await loadAudioCapabilities(model: model)
    }

    /// Keeps the agents the fleet still reports, in ranked order, and reuses
    /// their players so audio does not restart when the list reorders.
    private func reconcile(with sessions: [AgentSession], model: HerdrAppModel) {
        var existing = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var next: [Entry] = []
        for session in sessions {
            let machineState = model.connectionState(forMachine: session.pane.machineID)
            if var kept = existing.removeValue(forKey: session.id) {
                kept = Entry(
                    session: session,
                    summary: kept.summary,
                    connectionState: machineState,
                    loadedAt: kept.loadedAt,
                    didLoadAudioCapabilities: kept.didLoadAudioCapabilities,
                    audioPlayer: kept.audioPlayer
                )
                if kept.summary.hasPlayableResponse == false { kept.audioPlayer.stop() }
                next.append(kept)
            } else {
                next.append(Entry(
                    session: session,
                    summary: .empty,
                    connectionState: machineState,
                    loadedAt: nil,
                    didLoadAudioCapabilities: false,
                    audioPlayer: ResponseAudioPlayer()
                ))
            }
        }
        for orphan in existing.values {
            orphan.audioPlayer.stop()
        }
        entries = next

        if case let .detail(id) = screen, !entries.contains(where: { $0.id == id }) {
            screen = .grid
        }
        if let voiceAgentID, !entries.contains(where: { $0.id == voiceAgentID }) {
            cancelVoice()
        }
    }

    /// Fetches all four transcripts at once. The HTTP client is an actor, so the
    /// requests overlap even though these tasks are main-actor isolated; each
    /// one only suspends while waiting on the network.
    private func fetchSnapshots(
        for sessions: [AgentSession],
        model: HerdrAppModel
    ) async -> [String: PiConversationSnapshot] {
        let provider = snapshotProvider
        var tasks: [Task<(String, PiConversationSnapshot?), Never>] = []
        for session in sessions {
            let id = session.id
            let pane = session.pane
            tasks.append(Task { @MainActor in
                if let provider {
                    return (id, try? await provider(pane))
                }
                return (id, try? await model.fetchPiConversationSnapshot(for: pane))
            })
        }
        var results: [String: PiConversationSnapshot] = [:]
        for task in tasks {
            let (id, snapshot) = await task.value
            if let snapshot { results[id] = snapshot }
        }
        return results
    }

    private func loadAudioCapabilities(model: HerdrAppModel) async {
        for index in entries.indices {
            let entry = entries[index]
            guard entry.summary.hasPlayableResponse,
                  !entry.didLoadAudioCapabilities,
                  !entry.audioPlayer.capabilities.available
            else { continue }
            entries[index].didLoadAudioCapabilities = true
            let pane = entry.pane
            await entry.audioPlayer.loadCapabilities {
                try await model.fetchResponseAudioCapabilities(for: pane)
            }
        }
    }

    // MARK: - Summary audio

    func toggleAudio(
        for entryID: String,
        action: ResponseAudioAction,
        model: HerdrAppModel
    ) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = entries[index]
        let isActive = entry.audioPlayer.phase.activeAction == action
        if !isActive {
            stopAudio(except: entryID)
        }
        guard let response = entry.summary.response else { return }
        let pane = entry.pane
        entry.audioPlayer.activate(
            action,
            text: response,
            prepare: { action, text in
                try await model.prepareResponseAudio(action: action, text: text, for: pane)
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, for: pane)
            },
            failure: { [weak self] message in
                self?.lastError = message
            }
        )
    }

    func stopAudio(except entryID: String? = nil) {
        for entry in entries where entry.id != entryID {
            if entry.audioPlayer.phase.activeAction != nil {
                entry.audioPlayer.stop()
            }
        }
    }

    func stopAllAudio() {
        for entry in entries {
            entry.audioPlayer.stop()
        }
    }

    /// Called when the Car mode surface goes away: playback must not outlive it.
    func stopAudioForDisappear() {
        stopAllAudio()
    }

    // MARK: - Voice replies

    func toggleVoice(for entryID: String, model: HerdrAppModel) {
        switch voice {
        case .idle:
            beginVoice(for: entryID)
        case .recording:
            Task { await finishVoice(model: model) }
        case .transcribing, .sending:
            break
        case .review, .sent, .failed:
            // A tap on a second agent's mic starts over with that agent.
            beginVoice(for: entryID)
        }
    }

    func beginVoice(for entryID: String) {
        sentClearTask?.cancel()
        sentClearTask = nil
        stopAllAudio()
        capture.cancel()
        voiceAgentID = entryID
        voice = .recording(startedAt: now())
        if captureOutcomeProvider == nil {
            capture.beginLocked()
        }
    }

    func finishVoice(model: HerdrAppModel) async {
        guard voice.isRecording else { return }
        voice = .transcribing
        let transcriber = self.transcriber ?? { url in
            try await model.transcribeVoiceNote(at: url)
        }
        let outcome: HerdrQuickVoiceCapture.Outcome
        if let captureOutcomeProvider {
            outcome = await captureOutcomeProvider()
        } else {
            outcome = await capture.endHold(transcribe: transcriber)
        }
        guard voice == .transcribing else { return }

        switch outcome {
        case let .transcript(transcription):
            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                voice = .failed("Nothing was recognized. Try again.")
                return
            }
            if model.carModePreferences.confirmsVoiceTranscripts {
                voice = .review(text)
            } else {
                await sendVoice(text: text, model: model)
            }
        case .tooShort:
            voice = .failed("That was too short to transcribe. Hold a moment and speak again.")
        case .cancelled:
            resetVoice()
        case let .failure(message):
            voice = .failed(message)
        }
    }

    func cancelVoice() {
        sentClearTask?.cancel()
        sentClearTask = nil
        capture.cancel()
        resetVoice()
    }

    func retryVoice(model: HerdrAppModel) {
        guard let voiceAgentID else { return }
        beginVoice(for: voiceAgentID)
    }

    func sendVoice(model: HerdrAppModel) async {
        guard case let .review(text) = voice else { return }
        await sendVoice(text: text, model: model)
    }

    private func sendVoice(text: String, model: HerdrAppModel) async {
        guard let entryID = voiceAgentID, let entry = entry(id: entryID) else {
            voice = .failed("That agent is no longer in Car mode.")
            return
        }
        voice = .sending(text)
        let pane = entry.pane
        let disposition = CarModeSendPolicy.disposition(
            phase: entry.summary.phase,
            capabilities: pane.piSemantic?.capabilities
        )
        let succeeded: Bool
        if CarModeSendPolicy.usesSemanticPrompt(for: pane, phase: entry.summary.phase) {
            do {
                try await model.sendPiConversationPrompt(text, disposition: disposition, to: pane)
                succeeded = true
            } catch {
                succeeded = false
                voice = .failed(error.localizedDescription)
            }
        } else {
            succeeded = await model.sendPrompt(text, to: pane)
            if !succeeded, case .sending = voice {
                voice = .failed("The reply could not be sent to that agent.")
            }
        }
        guard succeeded else { return }

        voice = .sent(text, disposition)
        await refresh(model: model)
        sentClearTask?.cancel()
        let duration = sentDisplayDuration
        sentClearTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self, case .sent = self.voice else { return }
            self.resetVoice()
        }
    }

    private func resetVoice() {
        voice = .idle
        voiceAgentID = nil
    }

    // MARK: - Presentation helpers

    func dismissSentConfirmation() {
        sentClearTask?.cancel()
        sentClearTask = nil
        if case .sent = voice { resetVoice() }
    }

    func clearError() {
        lastError = nil
    }

    func openDetail(for entryID: String) {
        screen = .detail(entryID)
    }

    func showGrid() {
        screen = .grid
    }

    /// Status snapshot for the haptic tracker, keyed the same way the Agents tab
    /// keys it so the two surfaces announce the same transitions.
    var statusSnapshot: [String: AgentStatus] {
        Dictionary(entries.map { ($0.id, $0.pane.agentStatus) }, uniquingKeysWith: { first, _ in first })
    }

    #if DEBUG
    /// Preview and test fixture without a server.
    static func preview(
        entries: [Entry],
        voice: VoicePhase = .idle,
        loadPhase: LoadPhase = .ready
    ) -> CarModeStore {
        let store = CarModeStore()
        store.entries = entries
        store.voice = voice
        store.loadPhase = loadPhase
        if voice.isActive { store.voiceAgentID = entries.first?.id }
        return store
    }
    #endif
}
